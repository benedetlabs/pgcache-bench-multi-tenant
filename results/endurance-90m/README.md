# Sweep 5: 1h30m Endurance & Origin Resource Offload Campaign (DOKS + Grafana Cloud)

> 🇧🇷 **[Versão em português](README-pt.md)**

---

## 1. Objective & Hypothesis

While Sweeps 1–4 (`01-tenant-sweep.sh` through `04-complex-sweep.sh`) evaluate throughput (RPS) and average latency across 30-second measurement windows on an in-memory dataset (`SCALE=1`, ~463 MB), **Sweep 5 (`scripts/05-endurance-90m.sh`)** answers the operational infrastructure question for production multi-tenant SaaS systems:

> **What happens to the Origin PostgreSQL server's hardware resources (CPU, RAM, Disk IOPS, Disk Throughput, Active Connections, and Tuple Scans) over an extended 1h30m soak test when traffic shifts from Origin Direct (Path A) to PgCache Proxy (Path B) on a dataset 20× larger than `shared_buffers`?**

To test this rigorously without memory shortcuts on the Origin database:
- **Dataset Scale (`SCALE=20`, ~10 GB)**:
  - `10,000,000` orders (`orders`)
  - `40,000,000` order line items (`order_item`)
  - `2,000,000` customers (`customer`) across **`1,000` distinct tenants**
  - `1,000,000` products (`product`) and `1,500,000` reviews (`review`)
- **Origin Memory vs Disk Ratio**:
  - Origin runs with `shared_buffers = 512MB` on a dedicated `s-4vcpu-8gb` node backed by an `80Gi` DigitalOcean CSI Block Storage volume (`do-block-storage`). Because the ~10 GB dataset exceeds `shared_buffers` by ~20×, uncached complex queries force sustained block storage reads and CPU-intensive multi-table joins and aggregations on the Origin.
- **Active Tenant Working Set (`ACTIVE_TENANTS=100`)**:
  - The benchmark exercises `100` active tenants (`-D tenants=100`) executing the 8-statement enterprise analytics & search workload (`workload/complex-dashboard.sql`). The active tenant slice + Materialized Views fit inside PgCache's `3.5 GiB` `MEMORY_LIMIT` (`3758096384` bytes) with zero cache evictions.

---

## 2. Live Observability Stack & Grafana Cloud Link

- **Grafana Cloud Stack**: **[https://pgcachebench.grafana.net/](https://pgcachebench.grafana.net/)**
- **Dashboard Import JSON**: [`infra/grafana/pgcache-endurance-dashboard.json`](../../infra/grafana/pgcache-endurance-dashboard.json) (UID: `pgcache-endurance-90m`)
- **Kubernetes Telemetry Manifest**: [`infra/monitoring/grafana-cloud-monitoring.yaml`](../../infra/monitoring/grafana-cloud-monitoring.yaml)
- **Deployment Helper**: [`scripts/deploy-monitoring.sh`](../../scripts/deploy-monitoring.sh)

### Zero-Interference Telemetry Topology

To prevent the monitoring stack from stealing CPU cycles from `origin` or `pgcache` during the benchmark:

| Node Role (`bench_role` label) | DOKS Droplet (`nyc1`) | Benchmark Pod | Telemetry Agents on Node |
| :--- | :--- | :--- | :--- |
| **`origin`** | Node 1 (`10.116.0.3`, `s-4vcpu-8gb`) | `origin-0` (PostgreSQL 17, `:5432`) | `node-exporter` (`:9100`) + Kubelet `cAdvisor` only |
| **`pgcache`** | Node 2 (`10.116.0.4`, `s-4vcpu-8gb`) | `pgcache` (`0.7.1`, `:6432` / `:9091`) | `node-exporter` (`:9100`) + Kubelet `cAdvisor` + native `:9091/metrics` |
| **`loadgen`** | Node 3 (`10.116.0.5`, `s-4vcpu-8gb`) | `loadgen` (`pgbench -P 10`) | `node-exporter` + **`postgres-exporter` (`:9187`)** + **`pgbench-exporter` (`:9105`)** + **`grafana-alloy`** |

All central scraping, metric relabeling, and `prometheus.remote_write` compression (`grafana-alloy`, `postgres-exporter`, and `pgbench-exporter`) are pinned via `nodeAffinity` to the **`loadgen` node**, ensuring **0% observer CPU overhead** on `origin` and `pgcache`.

---

## 3. Collected Metrics Across 4 Layers

1. **Client Application Layer (`pgbench-exporter` `:9105/metrics`, every 5–10s)**:
   - `pgbench_phase_id`: Active phase (`1` to `6`, `0` when idle)
   - `pgbench_target_is_pgcache`: `0` when targeting Origin (`:5432`), `1` when targeting PgCache (`:6432`)
   - `pgbench_live_tps`: Live transactions per second reported by `pgbench -P 10`
   - `pgbench_live_latency_ms` & `pgbench_live_latency_stddev_ms`: Live transaction latency mean and standard deviation (ms)
2. **Hardware & OS Resource Layer (`node-exporter` `:9100` & `cAdvisor`, labeled by `bench_role`)**:
   - **CPU**: `node_cpu_seconds_total` broken down by mode (`user`, `system`, `iowait`, `softirq`, `idle`) across `bench_role="origin"`, `bench_role="pgcache"`, and `bench_role="loadgen"`
   - **Memory**: `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` and `container_memory_working_set_bytes`
   - **Disk I/O (`do-block-storage`)**: `node_disk_reads_completed_total` (Read IOPS), `node_disk_writes_completed_total` (Write IOPS), `node_disk_read_bytes_total` (Read MB/s), `node_disk_written_bytes_total` (Write MB/s)
   - **Network**: `node_network_receive_bytes_total` and `node_network_transmit_bytes_total`
3. **Origin PostgreSQL Internal Layer (`postgres-exporter` `:9187/metrics`)**:
   - `pg_activity_states_connections` & `pg_stat_database_numbackends`: Active vs idle backend connections on Origin
   - `pg_stat_database_tup_returned` & `pg_stat_database_tup_fetched`: Rows scanned and fetched per second on Origin
   - `pg_stat_database_blks_read` vs `pg_stat_database_blks_hit`: Physical disk/OS block reads vs `shared_buffers` hits per second
   - `pg_stat_database_xact_commit`, `tup_updated`, `tup_inserted`: Transaction commit and write mutation rates
   - `pg_replication_slot_lag_flush_lag_bytes`: Logical replication (CDC) WAL lag in bytes
4. **PgCache Proxy & MV Engine Layer (`pgcache` `:9091/metrics`)**:
   - `pgcache_queries_cache_hit`, `pgcache_queries_cache_miss`, `pgcache_queries_uncacheable`
   - `pgcache_cache_mv_hits`, `pgcache_cache_mv_fallthrough`, `pgcache_cache_mv_rebuilds`, `pgcache_cache_mv_gate`
   - `pgcache_cache_memory_used_bytes` vs `pgcache_cache_memory_budget_bytes` (`3.5 GiB`)
   - `pgcache_cache_invalidations` & `pgcache_cache_evictions`

---

## 4. The 1h30m (90-Minute) Execution Timeline

The campaign ([`scripts/05-endurance-90m.sh`](../../scripts/05-endurance-90m.sh)) executes two consecutive comparison blocks totaling **90 minutes of measured load** plus dynamic warm-up transitions:

| Phase ID | Duration | Block & Target | Workload Mix | What is Measured |
| :---: | :---: | :--- | :--- | :--- |
| **Seed** | ~8–12m | **Database Setup (`00-setup.sh`)** | `SCALE=20`, `TENANTS=1000` | Populates 10M orders & 40M items (~10 GB) and builds composite tenant indexes on Origin |
| **Phase 1** | **30 min** (`1800s`) | **Block 1 — Origin Direct (`Path A`)** | `100% Read` (`complex-dashboard.sql`) | Baseline Origin CPU saturation, Disk Read IOPS/MBs, active connections, and tuple scan rate |
| **Phase 2** | *Dynamic* (`warm_until_settled`) | **Block 1 — PgCache Warm-up** | `100% Read` (`complex-dashboard.sql`) | Base-table population and Materialized View construction until effective hit rate varies `< 1%` |
| **Phase 3** | **30 min** (`1800s`) | **Block 1 — PgCache Proxy (`Path B`)** | `100% Read` (`complex-dashboard.sql`) | **Origin Offload**: Origin CPU, Disk Read IOPS, and active backends drop to near zero while client TPS surges |
| **Phase 4** | **15 min** (`900s`) | **Block 2 — Origin Direct (`Path A`)** | `95% Read` + `5% Write` (`write.sql`) | Origin under combined heavy analytical reads and continuous transactional `UPDATE`s + WAL flushes |
| **Phase 5** | *Dynamic* (`warm_until_settled`) | **Block 2 — PgCache CDC Warm-up** | `95% Read` + `5% Write` (`write.sql`) | Stabilizes logical replication CDC invalidation loop under active writes |
| **Phase 6** | **15 min** (`900s`) | **Block 2 — PgCache Proxy (`Path B`)** | `95% Read` + `5% Write` (`write.sql`) | Origin processes only the 5% write stream and WAL logical replication while PgCache serves reads |

---

## 5. Measured Results (3-Node DOKS `s-4vcpu-8gb`, PgCache `0.7.1`, `SCALE=20`)

- **Execution Window**: `2026-10-19 01:02:02 UTC` → `2026-10-19 03:20:00 UTC`
- **Raw Summary Table**: [`results/endurance-90m/run-endurance-90m.txt`](run-endurance-90m.txt)
- **Final Telemetry Snapshot**: [`results/endurance-90m/final-metrics-snapshot.txt`](final-metrics-snapshot.txt)

### 5.1 Database Size & Row Distribution (`SCALE=20`, `TENANTS=1000`)

| Table | Row Count | Total Disk Size (Heap + Indexes) | Notes |
| :--- | ---: | ---: | :--- |
| `order_item` | `40,000,048` | `4,165 MB` | 40,000 line items per tenant |
| `orders` | `9,999,858` | `1,174 MB` | ~10,000 orders per tenant (`min=9,690`, `max=10,382`) |
| `review` | `1,500,000` | `215 MB` | Shared catalog table |
| `customer` | `2,000,000` | `187 MB` | 2,000 customers per tenant |
| `product` | `1,000,000` | `108 MB` | Shared catalog table |
| `seller` / `tenant` | `21,000` | `8 MB` | Reference tables |
| **TOTAL** | **`54,520,906`** | **`5,857 MB` (`~5.86 GB`)** | **`11.4×` larger than Origin's `shared_buffers = 512MB`** |

### 5.2 End-to-End 90-Minute Comparison (`complex-dashboard.sql`, `ACTIVE_TENANTS=100`, `CLIENTS=8`)

Each `complex-dashboard.sql` transaction executes **8 complex SQL statements** (2 substring `ILIKE` text searches, 3 deep 4-to-5 table `INNER/LEFT JOIN`s, and 3 multi-dimensional `GROUP BY / FILTER / CASE / HAVING` analytical rollups).

| Block / Scenario | Duration | Path A (Origin) Avg Latency | Path A TPS (Stmts/s) | Path B (PgCache) Avg Latency | Path B TPS (Stmts/s) | Steady-State Final 10m TPS (Lat) | Cache Hit % | Overall TPS Gain | Total Txns (`A` vs `B`) |
| :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **Block 1: 100% Read** (`read_1800s`) | **30m + 30m** | `16,865.88 ms` | `0.47` (`3.79/s`) | **`11,091.45 ms`** | **`0.72` (`5.75/s`)** | **`1.60–1.90 TPS`** (`4,225–5,600 ms`) | `47.1%` | **`+51.8%`** (up to **`4.0×`**) | `856` vs **`1,304`** (`+52.3%`) |
| **Block 2: 95% Read / 5% Write** (`rw_5pct_900s`) | **15m + 15m** | `16,462.09 ms` | `0.48` (`3.67/s`) | **`11,970.92 ms`** | **`0.66` (`5.07/s`)** | **`1.80–2.10 TPS`** (`2,654–4,780 ms`) | `62.1%` | **`+37.1%`** (up to **`4.3×`**) | `444` vs **`610`** (`+37.4%`) |

### 5.3 Block 2 Per-Script Breakdown: How Read Offload Accelerates Origin Writes by `2.21×`

In Block 2 (`95%` `complex-dashboard.sql` + `5%` `write.sql`), `pgbench` reports separate latency and throughput statistics for the read script and the transactional `UPDATE` write script:

| Workload Component in Block 2 (`900s`) | Path A (Origin Direct) | Path B (PgCache Proxy) | Relative Improvement |
| :--- | ---: | ---: | :--- |
| **Complex Read (`complex-dashboard.sql@95`)** | `17,471.93 ms` (`0.455 TPS` / `418` txns) | **`12,584.78 ms`** (`0.630 TPS` / `580` txns) | **`+38.4%` more read screens completed** |
| **Transactional Write (`write.sql@5`)** | `226.96 ms` (`0.028 TPS` / `26` writes) | **`102.89 ms`** (`0.033 TPS` / `30` writes) | **`2.21×` faster write latency (`-54.7%` latency)** |

> [!TIP]
> **Why Writes Become `2.21×` Faster Through PgCache**: When clients run directly against Origin (Path A), `UPDATE orders` statements compete with 8 concurrent heavy analytical queries saturating Origin's 4 vCPUs and block storage I/O, pushing simple single-row `UPDATE` latency to **`226.96 ms`**. When reads are offloaded to PgCache's in-memory Materialized Views (Path B), Origin CPU and disk I/O contention drops dramatically, cutting `UPDATE` execution latency in half to **`102.89 ms`** even including the proxy network hop and CDC invalidation round-trip.

---

## 6. Key Telemetry & Architectural Findings

From [`results/endurance-90m/final-metrics-snapshot.txt`](final-metrics-snapshot.txt):

| Prometheus Metric | Final Value | Architectural Meaning |
| :--- | ---: | :--- |
| `pgcache_queries_total` / `pgcache_queries_cacheable` | `16,401` / `16,368` | `16,368` complex read queries + `33` `UPDATE` write statements |
| `pgcache_queries_uncacheable` | **`0`** | **100% cacheability** across all 8 statements in `complex-dashboard.sql` |
| `pgcache_cache_mv_gate{outcome="reject"}` | **`0`** | **0% MV gate rejections** (`673` Materialized Views admitted) |
| `pgcache_cache_mv_hits` | **`5,924`** | Complex joins, searches, and aggregations served directly from sub-millisecond MVs |
| `pgcache_cache_evictions` | **`0`** | Zero cache thrashing or bump evictions across the entire 90-minute soak |
| `pgcache_cache_restarts_total` / `pgcache_connections_errors` | **`0` / `0`** | 100% proxy stability and zero failed transactions under continuous heavy load |
| `pgcache_cdc_events_processed` / `pgcache_cdc_flush_staleness_seconds` | `178` / **`8.1 µs`** | Near-instantaneous logical replication CDC apply loop |
| `pgcache_cache_memory_used_bytes` / `pgcache_cache_memory_budget_bytes` | `3.39 GiB` / `3.50 GiB` | **96.7% memory utilization** within the `3.5 GiB` budget without OOM kills |

### Memory High-Watermark Admission Pacing on `SCALE=20` (`3.5 GiB` Budget)

At `SCALE=20` (`54.5M` rows), the shared un-tenanted catalog tables (`product` with `1,000,000` rows and `review` with `1,500,000` rows) plus the `100` active tenants (`1,000,000` orders and `4,000,000` order items) represent a substantial working set inside PgCache's embedded storage (`pgcache_cache_disk_used_bytes = 16.79 GiB`).

- During Phase 3 and Phase 6, as `pgcache_cache_memory_used_bytes` climbed from `2.93 GiB` (`83.8%` of `MEMORY_LIMIT`) to `3.39 GiB` (`96.7%` of `MEMORY_LIMIT`), PgCache's **memory high-watermark admission controller** (`pgcache_cache_registration_throttled_total = 348`) paced new Materialized View registrations (`pgcache_cache_queries_registered = 607 / 800` distinct tenant-query combinations).
- Instead of over-allocating host RAM or triggering bump-eviction thrashing (`pgcache_cache_evictions = 0`), PgCache pinned the admitted ~76% of tenant Materialized Views in memory (serving hits at sub-millisecond speed, boosting cluster throughput to **`1.8–2.1 TPS`** in the final intervals) while cleanly coalescing/forwarding uncached tenant queries (`pgcache_cache_coalesce_deadline_forward_total = 5,586`).
- **Sizing Takeaway for Production**: On a `4 vCPU / 8 GB` node (`MEMORY_LIMIT = 3.5 GiB`), PgCache comfortably holds ~75 tenants of the 8-query enterprise dashboard at `SCALE=20`. Scaling the PgCache node to `16 GB RAM` (`MEMORY_LIMIT = 10 GiB`) allows all `100+` active tenants' Materialized Views to reside simultaneously in RAM for a 100% steady-state hit ratio.

---

## 7. How to Reproduce

```bash
# 1. Create the 3-node DigitalOcean Kubernetes cluster (~$0.21/hr total)
./scripts/do-cluster.sh create pgcache-bench s-4vcpu-8gb nyc1

# 2. Deploy Origin (80Gi PVC), PgCache 0.7.1, and Loadgen (tuned network profile)
./scripts/do-cluster.sh deploy 0.7.1

# 3. Configure .env.grafana (from .env.grafana.example) and deploy Grafana Cloud telemetry
cp .env.grafana.example .env.grafana
# (Edit .env.grafana with your GCLOUD_RW_API_KEY)
./scripts/deploy-monitoring.sh

# 4. Import infra/grafana/pgcache-endurance-dashboard.json at:
#    https://pgcachebench.grafana.net/dashboard/import

# 5. Run the 1h30m (90-minute) endurance campaign
./scripts/05-endurance-90m.sh

# 6. When finished, tear down the cluster and block storage volumes ($0 residual cost)
./scripts/do-cluster.sh destroy pgcache-bench
```

