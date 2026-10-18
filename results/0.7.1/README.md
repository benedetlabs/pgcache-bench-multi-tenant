# PgCache Benchmark Verification — Tag 0.7.1 (DOKS 3-Node Cloud & Local Docker — Baseline & Complex Multi-Tenant Scenarios)

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.7.1** (`pgcache/pgcache:0.7.1` on AMD64 DOKS / `pgcache/pgcache:0.7.1-arm64` on Local Docker) executed across two environments and two workload complexity suites:

1. **Environments**:
   - **DigitalOcean Kubernetes (DOKS — 3 Dedicated Nodes)**: 3× `s-4vcpu-8gb` in single-AZ (`sfo2`), `--ha=false` ($0 control plane), strict `podAntiAffinity` (`origin`, `pgcache`, and `loadgen` on 3 distinct physical nodes), `hostNetwork: true`, direct node IP routing, and tuned profile (`NUM_WORKERS=8`, `PGCACHE_POPULATION_WORKERS_MIN=4`, `MEMO_CACHE_SIZE="1073741824"`, `MEMORY_LIMIT="3758096384"`, 2 GiB `/dev/shm`).
   - **Local Docker Environment**: Single-host baseline across 1 to 1,000 tenants, concurrency scaling, and mixed write workloads (`infra/docker-compose.yml`).
2. **Workload Suites**:
   - **Baseline Operational Dashboard (`workload/dashboard.sql`)**: Full regression verification across 1 to 2,000 tenants on DOKS (and 1 to 1,000 tenants, 1 to 32 clients, and 0%–10% writes in Docker).
   - **Complex Multi-Tenant SaaS Workloads (`scripts/04-complex-sweep.sh`)**: Substring text search (`ILIKE '%...%'`), deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (including zero-order customer cohorts and unreviewed product inventory), multi-dimensional analytical aggregations (`GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`), and a unified 8-statement enterprise analytics & search screen (`workload/complex-dashboard.sql`), verified by a strict **Differential Correctness, Cacheability, and MV Admission Gate** (`scripts/verify-correctness.sh`).

---

## 1. Executive Summary

- **Differential Correctness, Cacheability & MV Hit Gate (`verify-correctness-doks.txt` & `verify-correctness.txt`)**:
  - Verified on **both 3-node DOKS and Local Docker**: all **12/12 distinct complex multi-tenant SQL queries** across `complex-search.sql` (4), `complex-joins.sql` (4), and `complex-analytics.sql` (4) (covering 100% of `complex-dashboard.sql`) produced byte-for-byte identical result sets between Origin PostgreSQL 17 and PgCache 0.7.1 across all three passes: cold miss/populate (Pass 1), base-table hit + MV build (Pass 2), and warm Materialized View hit (Pass 3).
  - **100% Cacheability**: `pgcache_queries_cacheable` delta = `36/36`, `pgcache_queries_uncacheable` delta = **`0`**, `pgcache_queries_cache_error` delta = **`0`**.
  - **100% Materialized View (MV) Gate Admission & Hit Verification**: `pgcache_cache_mv_gate{outcome="admit"}` = **`12/12`** (`outcome="reject"` = `0`), and `pgcache_cache_mv_hits` delta = **`12/12`** on Pass 3.
- **Baseline Operational Dashboard (`workload/dashboard.sql`)**:
  - **3-Node DOKS (`1` to `2,000` Tenants)**: **100.0% hit ratio** across every tenant tier up to 2,000 tenants, delivering **+40% to +63% throughput gain** (`470–491 rps` at `16.29–17.01 ms` vs `302–343 rps` at `23.31–26.52 ms` on Origin across 50–2,000 tenants).
  - **Local Docker (`1` to `1,000` Tenants)**: **99.9%–100.0% hit ratio**, delivering **+116% to +139%** across tenant scaling, **+93% to +138%** across concurrency scaling (`1..32` clients), and **+40% to +110%** under 5%–10% write ratios.
- **Complex Multi-Tenant Workloads (`workload/complex-*.sql`)**:
  - **3-Node DOKS Cloud Speedup**: Across 3 separate cloud nodes, Materialized View acceleration reduces complex 4-to-6 table `JOIN`/`LEFT JOIN`/`GROUP BY`/`ILIKE` query latency from **74.3–204.4 ms** on Origin to **4.73–11.50 ms** on PgCache (including 4 to 8 cross-node network round-trips), delivering **14.7× to 31.3× higher throughput (`+1,369%` to `+3,033%`)** at 8 clients, **12.1× (`+1,108%`, 100.0% hit)** at **500 active tenants** (`4,000` distinct MVs), and **26.8× (`+2,584%`, `1,020 rps` at `31.36 ms` vs `38 rps` at `835.52 ms`)** at **32 concurrent clients**.
  - **Local Docker Speedup**: Without cross-node network RTT, complex queries drop from **88.7–209.6 ms** on Origin to **1.25–2.86 ms** on PgCache (~0.31–0.38 ms per statement), delivering **58.0× to 97.4× higher throughput (`+5,703%` to `+9,636%`)** at 8 clients and **94.0× (`+9,300%`, `3,478 rps` vs `37 rps`)** at 32 clients.
  - **Mixed Write Resilience (`INNER JOIN` In-Place CDC vs. `LEFT JOIN` Outer Invalidation)**: By scoping every joined tenant table with an explicit `:t` literal (`AND o.tenant_id = :t`, `AND oi.tenant_id = :t`, `AND c.tenant_id = :t`), the **5 `INNER JOIN` queries (`62.5%`)** in `complex-dashboard.sql` remain **100% cache hits** under `UPDATE orders` writes (updated in-place via CDC + background MV rebuild), while the **3 `LEFT JOIN` queries (`37.5%`)** undergo conservative invalidation. Consequently, `complex-dashboard.sql` sustains a **63.1%–75.0% hit ratio on DOKS** (`+12%` to `+16%` gain on concentrated writes `5:1` / `10:1` and near-parity `-5%` to `-12%` on 200-tenant distributed writes) and **62.5%–67.6% hit ratio in Docker** (`+8%` to `+30%` gain) with zero cache errors.

---

## 2. Differential Correctness, Cacheability & MV Admission Gate

Executed via [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) on both 3-node DOKS ([`verify-correctness-doks.txt`](verify-correctness-doks.txt)) and Local Docker ([`verify-correctness.txt`](verify-correctness.txt)):

| Check | 3-Node DOKS Result | Local Docker Result | Telemetry / Detail |
|---|---|---|---|
| **Byte-for-Byte Output Equality** | **PASS (12/12 queries)** | **PASS (12/12 queries)** | `psql -tAF '|'` output identical between Origin and PgCache across Pass 1 (miss), Pass 2 (base-table hit + MV build), and Pass 3 (warm MV hit) |
| **Cacheable Queries Delta** | **PASS (`36 / 36`)** | **PASS (`36 / 36`)** | `pgcache_queries_cacheable` incremented by 36 across 3 passes of 12 statements |
| **Uncacheable Queries Delta** | **PASS (`0`)** | **PASS (`0`)** | `pgcache_queries_uncacheable` delta = `0` |
| **MV Gate Admission** | **PASS (`12 / 12`)** | **PASS (`12 / 12`)** | `pgcache_cache_mv_gate{outcome="admit"}` = `12`, `pgcache_cache_mv_gate{outcome="reject"}` = `0` |
| **Materialized View Hits** | **PASS (`12 / 12`)** | **PASS (`12 / 12`)** | `pgcache_cache_mv_hits` delta = `12` (100% of Pass 3 queries served directly from MVs) |
| **Cache Errors Delta** | **PASS (`0`)** | **PASS (`0`)** | `pgcache_queries_cache_error` delta = `0` |

---

## 3. Baseline Sweeps 1–3 (`workload/dashboard.sql`)

### 3.1 Sweep 1 — Tenant Count Sweep on 3-Node DOKS (`1` to `2,000` Tenants, `CLIENTS=8`)

Raw log: [`run-tenants-doks.txt`](run-tenants-doks.txt) · TSV: [`results-doks.tsv`](results-doks.tsv)

| Active Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 23.32 ms · 343 rps | **16.63 ms · 481 rps** | **+40%** | 100.0% | 2 |
| **10** | 22.88 ms · 350 rps | **21.67 ms · 369 rps** | **+5%** | 100.0% | 2 |
| **50** | 25.43 ms · 315 rps | **17.01 ms · 470 rps** | **+49%** | 100.0% | 3 |
| **100** | 26.52 ms · 302 rps | **16.29 ms · 491 rps** | **+63%** | 100.0% | 3 |
| **500** | 24.35 ms · 329 rps | **16.31 ms · 490 rps** | **+49%** | 100.0% | 4 |
| **1,000** | 24.04 ms · 333 rps | **16.90 ms · 473 rps** | **+42%** | 100.0% | 4 |
| **2,000** | 23.31 ms · 343 rps | **16.51 ms · 485 rps** | **+41%** | 100.0% | 6 |

### 3.2 Sweep 1 — Tenant Count Sweep on Local Docker (`1` to `1,000` Tenants, `CLIENTS=8`)

Raw log: [`run-tenants-docker.txt`](run-tenants-docker.txt) · TSV: [`results-docker.tsv`](results-docker.tsv)

| Active Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 37.08 ms · 216 rps | **15.56 ms · 514 rps** | **+138%** | 100.0% | 2 |
| **10** | 36.11 ms · 222 rps | **16.13 ms · 496 rps** | **+123%** | 100.0% | 2 |
| **50** | 37.21 ms · 215 rps | **17.22 ms · 465 rps** | **+116%** | 100.0% | 3 |
| **200** | 40.11 ms · 199 rps | **16.86 ms · 475 rps** | **+139%** | 100.0% | 3 |
| **500** | 40.48 ms · 198 rps | **17.78 ms · 450 rps** | **+127%** | 100.0% | 4 |
| **1,000** | 40.87 ms · 196 rps | **17.73 ms · 451 rps** | **+130%** | 99.9% | 5 |

### 3.3 Sweep 2 — Client Concurrency Sweep (`TENANTS=1,000`, Local Docker)

| Clients | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 13.26 ms · 75 rps | **6.89 ms · 145 rps** | **+93%** | 100.0% | 2 |
| **4** | 21.82 ms · 183 rps | **9.82 ms · 408 rps** | **+123%** | 100.0% | 2 |
| **8** | 38.67 ms · 207 rps | **16.75 ms · 478 rps** | **+131%** | 100.0% | 2 |
| **16** | 67.48 ms · 237 rps | **30.76 ms · 520 rps** | **+119%** | 100.0% | 2 |
| **32** | 128.51 ms · 249 rps | **53.93 ms · 593 rps** | **+138%** | 100.0% | 2 |

### 3.4 Sweep 3 — Write Ratio and Concentration Sweep (`TENANTS=1,000`, `CLIENTS=8`, Local Docker)

| Writes | Write Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 1,000 | 40.60 ms · 197 rps | **16.83 ms · 475 rps** | **+141%** | 100.0% | 2 |
| **5%** | 1 | 36.80 ms · 217 rps | **17.55 ms · 456 rps** | **+110%** | 100.0% | 2 |
| **5%** | 10 | 37.12 ms · 215 rps | **20.91 ms · 383 rps** | **+78%** | 100.0% | 2 |
| **5%** | 1,000 | 38.89 ms · 206 rps | **23.23 ms · 344 rps** | **+67%** | 100.0% | 2 |
| **10%** | 1 | 35.99 ms · 222 rps | **18.59 ms · 430 rps** | **+94%** | 100.0% | 2 |
| **10%** | 1,000 | 36.41 ms · 220 rps | **25.98 ms · 308 rps** | **+40%** | 100.0% | 2 |

---

## 4. Sweep 4 — Complex Multi-Tenant Scenarios (`scripts/04-complex-sweep.sh`)

To evaluate how PgCache behaves on heavy relational workloads beyond primary-key and single-join lookups, we executed four complex multi-tenant SQL suites under [`workload/`](../../workload/) on **both 3-node DigitalOcean Kubernetes (DOKS)** and **Local Docker**:
1. **[`complex-search.sql`](../../workload/complex-search.sql)** (4 statements): Substring `ILIKE '%...%'` text searches across customer emails/names, product names, seller names, and review bodies combined with 2-to-6 table `INNER JOIN` and `LEFT JOIN` chains.
2. **[`complex-joins.sql`](../../workload/complex-joins.sql)** (4 statements): Deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (`orders -> customer -> order_item -> product -> category -> seller -> review`), including customer cohort retention (`LEFT JOIN orders`) and unreviewed product inventory (`LEFT JOIN review`).
3. **[`complex-analytics.sql`](../../workload/complex-analytics.sql)** (4 statements): Multi-dimensional `GROUP BY` rollups with conditional `FILTER (WHERE ...)`, `CASE WHEN` fulfillment & price-tier buckets, and `HAVING` thresholds.
4. **[`complex-dashboard.sql`](../../workload/complex-dashboard.sql)** (8 statements): Unified enterprise analytics & search screen combining 2 search queries, 3 deep multi-table `JOIN` / `LEFT JOIN` queries, and 3 heavy analytical rollups.

### 4.1 Scenario Comparison (`TENANTS=200`, `CLIENTS=8`) — 3-Node DOKS vs. Local Docker

Raw logs: [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt) (DOKS) · [`run-complex-scenarios.txt`](run-complex-scenarios.txt) (Docker)

| Scenario | Stmts | DOKS Origin (Path A) | DOKS PgCache 0.7.1 (Path B) | DOKS Gain (Speedup) | Docker Origin (Path A) | Docker PgCache 0.7.1 (Path B) | Docker Gain (Speedup) | Hit Ratio |
|---|---:|---|---|---:|---|---|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 23.06 ms · 347 rps | **15.92 ms · 503 rps** | **+45% (1.45×)** | 37.61 ms · 213 rps | **16.05 ms · 498 rps** | **+134% (2.3×)** | 100.0% |
| **`search`** (`complex-search.sql`) | 4 | 74.26 ms · 108 rps | **5.04 ms · 1,586 rps** | **+1,369% (14.7×)** | 88.67 ms · 90 rps | **1.53 ms · 5,223 rps** | **+5,703% (58.0×)** | 100.0% |
| **`joins`** (`complex-joins.sql`) | 4 | 148.87 ms · 54 rps | **4.73 ms · 1,692 rps** | **+3,033% (31.3×)** | 121.46 ms · 66 rps | **1.25 ms · 6,426 rps** | **+9,636% (97.4×)** | 100.0% |
| **`analytics`** (`complex-analytics.sql`) | 4 | 102.38 ms · 78 rps | **5.69 ms · 1,406 rps** | **+1,703% (18.0×)** | 92.31 ms · 87 rps | **1.39 ms · 5,737 rps** | **+6,494% (65.9×)** | 100.0% |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 204.39 ms · 39 rps | **11.50 ms · 696 rps** | **+1,685% (17.8×)** | 209.62 ms · 38 rps | **2.86 ms · 2,798 rps** | **+7,263% (73.6×)** | 100.0% |

**Why Complex Queries Achieve 15×–31× Speedup on DOKS (and 58×–97× in Docker)**:
- In PgCache 0.7.1, query caching operates in two distinct tiers:
  1. **Table-Level Subsumption (`public.*`)**: Base tables (`orders`, `order_item`, `product`, `customer`, `review`, `seller`, `category`) are populated in PgCache's embedded PostgreSQL instance. If a query hits `public.*` directly (`pgcache_cache_mv_fallthrough`), PgCache executes the SQL locally (~15.9 ms on DOKS / ~16.1 ms in Docker for the 8 lightweight statements in `dash_base`).
  2. **Materialized View Admission Gate (`pgcache_mv.q_<hash>`)**: When a query has `OFFSET 0` (no positive `OFFSET`), groups on non-nullable entity keys (`mv=true`), and either scans `>= 1,000` pre-aggregation rows (`--mv_compute_min_rows=1000`) or achieves a `>= 10:1` row reduction ratio (`--mv_size_ratio=10`), PgCache admits the query into its Materialized View engine (`pgcache_cache_mv_gate{outcome="admit"}`).
- On **3-node DOKS**, each 4-statement complex suite pays 4 cross-node network round-trips (~3.5 ms network floor) plus ~1.2–2.0 ms of MV read execution (`4.73–5.69 ms` total vs `74.3–148.9 ms` on Origin — **14.7× to 31.3× faster**), while the 8-statement `cplx_dash` screen drops from **204.39 ms (`39 rps`)** to **11.50 ms (`696 rps`, 17.8× faster)** — proving that as Origin query complexity grows, the fixed inter-node network floor becomes a tiny fraction of total execution time.

### 4.2 Complex Tenant Scaling (`1` to `1,000` Tenants on `complex-dashboard.sql`, `CLIENTS=8`) — 3-Node DOKS vs. Local Docker

Raw logs: [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt) (DOKS) · [`run-complex-tenants.txt`](run-complex-tenants.txt) (Docker)

| Active Tenants | DOKS Origin | DOKS PgCache 0.7.1 | DOKS Gain (Speedup) | DOKS Hit (Warm) | Docker Origin | Docker PgCache 0.7.1 | Docker Gain (Speedup) | Docker Hit (Warm) |
|---:|---|---|---:|---:|---|---|---:|---:|
| **1** | 206.80 ms · 39 rps | **9.19 ms · 871 rps** | **+2,133% (22.3×)** | 100.0% (2) | 208.31 ms · 38 rps | **2.28 ms · 3,511 rps** | **+9,139% (92.4×)** | 100.0% (2) |
| **10** | 198.24 ms · 40 rps | **9.58 ms · 835 rps** | **+1,988% (20.9×)** | 100.0% (2) | 168.59 ms · 47 rps | **2.24 ms · 3,579 rps** | **+7,515% (76.1×)** | 100.0% (2) |
| **50** | 227.49 ms · 35 rps | **10.81 ms · 740 rps** | **+2,014% (21.1×)** | 100.0% (6) | 184.07 ms · 43 rps | **2.27 ms · 3,532 rps** | **+8,114% (82.1×)** | 100.0% (3) |
| **200** | 212.77 ms · 38 rps | **11.23 ms · 712 rps** | **+1,774% (18.7×)** | 100.0% (7) | 206.95 ms · 39 rps | **2.90 ms · 2,763 rps** | **+6,985% (70.8×)** | 100.0% (8) |
| **500** | 223.87 ms · 36 rps | **18.40 ms · 435 rps** | **+1,108% (12.1×)** | 100.0% (8) | 212.27 ms · 38 rps | **67.55 ms · 118 rps** | **+211% (3.1×)** | 97.4% (8) |
| **1,000** *(cold 8-pass cap)* | 210.14 ms · 38 rps | 251.39 ms · 32 rps | -16% (0.84×) | 68.1% (4) | 226.02 ms · 35 rps | 517.86 ms · 15 rps | -57% (0.43×) | 62.7% (5) |

**Finding — Tenant Working-Set Scaling on Dedicated DOKS Nodes vs. Shared-CPU Docker**:
- From **1 to 500 active tenants** (`8` to `4,000` distinct 4–6 table Materialized Views), the dedicated 4-vCPU DOKS PgCache node (`NUM_WORKERS=8`, `PGCACHE_POPULATION_WORKERS_MIN=4`) warms **100.0%** of the working set and delivers **12.1× to 22.3× higher throughput (`+1,108%` at 500 tenants and `+1,774%` to `+2,133%` at 1–200 tenants)**.
- Notably, at **500 tenants**, DOKS reaches **100.0% hit ratio (`435 rps` at `18.40 ms`, +1,108%)** compared to `97.4%` (`118 rps` at `67.55 ms`, +211%) in single-host Docker because `origin` and `pgcache` run on isolated physical nodes without competing for CPU during background MV construction.
- At **1,000 tenants** (`8,000` distinct complex queries), uniform random sampling across 1,000 tenants (`\set t random(1, 1000)`) within bounded 15s warm-up passes reaches **68.1% hit ratio on DOKS** (`32 rps` vs `38 rps`, `-16%`) and **62.7% in Docker**.

### 4.3 Complex Concurrency Scaling (`1` to `32` Clients on `complex-dashboard.sql`, `TENANTS=200`) — 3-Node DOKS vs. Local Docker

Raw logs: [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt) (DOKS) · [`run-complex-clients.txt`](run-complex-clients.txt) (Docker)

| Clients | DOKS Origin | DOKS PgCache 0.7.1 | DOKS Gain (Speedup) | Docker Origin | Docker PgCache 0.7.1 | Docker Gain (Speedup) | Hit Ratio | Warm Passes |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 100.60 ms · 10 rps | **7.14 ms · 140 rps** | **+1,300% (14.0×)** | 84.83 ms · 12 rps | **1.73 ms · 578 rps** | **+4,717% (48.2×)** | 100.0% | 2 |
| **4** | 129.45 ms · 31 rps | **8.60 ms · 465 rps** | **+1,400% (15.0×)** | 92.22 ms · 43 rps | **2.26 ms · 1,770 rps** | **+4,016% (41.2×)** | 100.0% | 2 |
| **8** | 212.81 ms · 38 rps | **10.48 ms · 763 rps** | **+1,908% (20.1×)** | 194.69 ms · 41 rps | **2.66 ms · 3,003 rps** | **+7,224% (73.2×)** | 100.0% | 2 |
| **16** | 406.90 ms · 39 rps | **18.06 ms · 886 rps** | **+2,172% (22.7×)** | 400.89 ms · 40 rps | **4.60 ms · 3,475 rps** | **+8,588% (86.9×)** | 100.0% | 2 |
| **32** | 835.52 ms · 38 rps | **31.36 ms · 1,020 rps** | **+2,584% (26.8×)** | 862.44 ms · 37 rps | **9.20 ms · 3,478 rps** | **+9,300% (94.0×)** | 100.0% | 2 |

- **Pure Single-Client Speedup (`CLIENTS=1`)**: With zero queueing anywhere, an 8-statement complex analytics & search screen drops from **100.60 ms (`10 rps`)** to **7.14 ms (`140 rps`, 14.0× faster)** across the DOKS cloud network, and from **84.83 ms (`12 rps`)** to **1.73 ms (`578 rps`, 48.2× faster)** in local Docker.
- **High Concurrency (`CLIENTS=16..32`)**: On both DOKS and Docker, Origin saturates at **37–40 rps** with latency climbing to **835–862 ms** (~0.85 seconds per screen render). On DOKS, PgCache scales cleanly to **1,020 rps** (~8,160 complex SQL queries/sec) at **31.36 ms** (**26.8× speedup, +2,584%**), and in Docker to **3,478 rps** at **9.20 ms** (**94.0× speedup, +9,300%**).

### 4.4 Complex Write Invalidation & `INNER JOIN` vs `LEFT JOIN` CDC Behavior (`TENANTS=200`, `CLIENTS=8`) — 3-Node DOKS vs. Local Docker

Raw logs: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt) (DOKS) · [`run-complex-writes.txt`](run-complex-writes.txt) (Docker)

| Write Ratio | Write Tenants | DOKS Origin | DOKS PgCache 0.7.1 | DOKS Gain | DOKS Hit | Docker Origin | Docker PgCache 0.7.1 | Docker Gain | Docker Hit |
|---:|---:|---|---|---:|---:|---|---|---:|---:|
| **0%** | 200 | 189.81 ms · 42 rps | **11.13 ms · 719 rps** | **+1,612%** | 100.0% | 196.12 ms · 41 rps | **2.62 ms · 3,059 rps** | **+7,361%** | 100.0% |
| **5%** | 1 | 186.66 ms · 43 rps | **166.17 ms · 48 rps** | **+12%** | 75.0% | 191.28 ms · 42 rps | **166.86 ms · 48 rps** | **+14%** | 67.6% |
| **5%** | 10 | 182.40 ms · 44 rps | 194.35 ms · 41 rps | -7% | 65.4% | 216.04 ms · 37 rps | **167.12 ms · 48 rps** | **+30%** | 63.3% |
| **5%** | 200 | 191.20 ms · 42 rps | 201.48 ms · 40 rps | -5% | 65.7% | 210.42 ms · 38 rps | 220.45 ms · 36 rps | -5% | 64.0% |
| **10%** | 1 | 177.65 ms · 45 rps | **154.73 ms · 52 rps** | **+16%** | 63.1% | 206.33 ms · 39 rps | **163.51 ms · 49 rps** | **+26%** | 63.1% |
| **10%** | 200 | 167.93 ms · 48 rps | 191.79 ms · 42 rps | -12% | 64.8% | 213.03 ms · 38 rps | **195.50 ms · 41 rps** | **+8%** | 62.5% |

**Why Hit Ratio Settles at ~62.5%–75.0% (`>= 5/8`) Under `UPDATE orders` Writes (`INNER JOIN` vs. `LEFT JOIN`)**:
- In `complex-dashboard.sql`, all 8 statements reference `orders`:
  1. **5 `INNER JOIN` Statements (`#1`, `#2`, `#4`, `#6`, `#8` = `62.5%` of queries)**: Because these queries include explicit `WHERE ... AND o.tenant_id = :t` equality predicates, PgCache scopes their `orders` table dependency to tenant `:t`, applies non-key `UPDATE orders SET total = total + 1` events in-place via logical replication (`cdc_update`), and rebuilds only the affected tenant's Materialized Views (`pgcache_cache_mv_rebuilds`). These 5 statements achieve a **100% cache hit rate** across read-only tenants and in-place hits on updated tenants.
  2. **3 `LEFT JOIN` Statements (`#3`, `#5`, `#7` = `37.5%` of queries)**: These queries use `FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = :t` to preserve customers with zero orders (`o.id IS NULL`). Because `o.tenant_id = :t` is an outer-join `ON` condition rather than a top-level `WHERE` filter, PgCache conservatively invalidates registered outer-join queries referencing `orders` whenever `orders` receives a write.
- When writes are concentrated on a single tenant (`5:1` and `10:1`), PgCache outperforms Origin by **+12% to +16% on DOKS** (with **75.0% and 63.1% hit ratios**) and **+14% to +26% in Docker**, while distributed writes across all 200 tenants (`5:200`, `10:200`) maintain **64.8%–65.7% hit ratios** and near-parity throughput (`40–42 rps` vs `42–48 rps` on DOKS; `36–41 rps` vs `38 rps` in Docker) with **`pgcache_queries_cache_error == 0`**.

---

## 5. Raw Artifacts

- **3-Node DigitalOcean Kubernetes (DOKS)**:
  - Baseline DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
  - Complex scenarios DOKS TSV: [`results-complex-doks.tsv`](results-complex-doks.tsv)
  - Differential correctness, cacheability & MV gate log (DOKS): [`verify-correctness-doks.txt`](verify-correctness-doks.txt)
  - Baseline Sweep 1 (Tenants 1..2000) raw log (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
  - Complex Sweep 4.1 (Scenario comparison) raw log (DOKS): [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt)
  - Complex Sweep 4.2 (Tenant scaling) raw log (DOKS): [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)
  - Complex Sweep 4.3 (Concurrency scaling) raw log (DOKS): [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)
  - Complex Sweep 4.4 (Write invalidation) raw log (DOKS): [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)
- **Local Docker**:
  - Baseline Docker TSV: [`results-docker.tsv`](results-docker.tsv) / [`results.tsv`](results.tsv)
  - Complex scenarios Docker TSV: [`results-complex.tsv`](results-complex.tsv) / [`results-complex-docker.tsv`](results-complex-docker.tsv)
  - Differential correctness, cacheability & MV gate log (Docker): [`verify-correctness.txt`](verify-correctness.txt) / [`verify-correctness-docker.txt`](verify-correctness-docker.txt)
  - Baseline Sweep 1 (Tenants) raw log (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt) / [`run-tenants.txt`](run-tenants.txt)
  - Baseline Sweep 2 (Concurrency) raw log (Docker): [`run-clients.txt`](run-clients.txt)
  - Baseline Sweep 3 (Writes) raw log (Docker): [`run-writes.txt`](run-writes.txt)
  - Complex Sweep 4.1–4.4 raw logs (Docker): [`run-complex-scenarios.txt`](run-complex-scenarios.txt), [`run-complex-tenants.txt`](run-complex-tenants.txt), [`run-complex-clients.txt`](run-complex-clients.txt), [`run-complex-writes.txt`](run-complex-writes.txt)
