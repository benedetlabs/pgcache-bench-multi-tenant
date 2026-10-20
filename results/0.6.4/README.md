# PgCache 0.6.4 Benchmark Report: Scaling from 1 to 2,000 Tenants on a 3-Node Cloud Cluster

> 🇧🇷 **[Ler em português](README-pt.md)**

This report documents the verification of **PgCache v0.6.4** (`pgcache/pgcache:0.6.4`) on our **3-node DigitalOcean Kubernetes (DOKS)** cluster (`3× s-4vcpu-8gb` in a single availability zone), running PostgreSQL 17, PgCache, and the benchmark client on three separate virtual machines.

> **Why Only 3-Node Cloud Numbers Are Shown**: Local Docker Compose is used strictly to set up the database and test SQL correctness locally; all performance numbers come exclusively from the 3-node Kubernetes cluster.

---

## 1. Key Takeaways

- **100.0% Cache Hit Rate Up to 2,000 Tenants**: Across every tenant tier from 1 to 2,000 active tenants, PgCache 0.6.4 maintained a 100.0% hit ratio once warmed.
- **Peak Throughput at 2,000 Tenants (515 req/s, +67%)**: On the 8-query operational dashboard (`workload/dashboard.sql`), PgCache cut screen latency from **24.5–29.9 ms** on PostgreSQL down to **15.5–21.0 ms**, delivering **+33% to +90% higher throughput**.
- **Fast Warm-Up**: Settled in 2 passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants.

---

## 2. Cluster Setup (3 Dedicated Cloud VMs)

| Component | Configuration |
|---|---|
| **Cluster Topology** | 3 separate physical nodes on DigitalOcean (`sfo3` single-AZ, `--ha=false`) |
| **Node Size** | 3× `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM per VM) |
| **Node Isolation** | Strict `podAntiAffinity` (1 dedicated node each for `origin`, `pgcache`, and `loadgen`) |
| **Networking** | `hostNetwork: true` (direct node IP routing) |
| **Origin Database** | PostgreSQL 17, `shared_buffers=512MB`, 500k orders, 2M order items (~594 MB), 2,000 tenants |
| **PgCache** | `pgcache/pgcache:0.6.4`, `NUM_WORKERS=4` |

---

## 3. Scaling Active Tenants (`1` to `2,000` Tenants, 8 Concurrent Clients)

Each request executes all 8 SQL queries in `workload/dashboard.sql` sequentially:

| Active Tenants | PostgreSQL Direct (Path A) | PgCache 0.6.4 (Path B) | Speedup | Hit Ratio | Warm-up Passes |
|---:|---|---|---:|---:|---:|
| **1** | 27.1 ms · 295 req/s | **16.8 ms · 476 req/s** | **+61%** | 100.0% | 2 |
| **10** | 27.7 ms · 288 req/s | **21.0 ms · 382 req/s** | **+33%** | 100.0% | 2 |
| **50** | 29.9 ms · 267 req/s | **15.8 ms · 506 req/s** | **+90%** | 100.0% | 2 |
| **100** | 25.2 ms · 317 req/s | **16.3 ms · 492 req/s** | **+55%** | 100.0% | 2 |
| **500** | 26.9 ms · 298 req/s | **15.7 ms · 510 req/s** | **+71%** | 100.0% | 3 |
| **1,000** | 24.5 ms · 326 req/s | **16.8 ms · 476 req/s** | **+46%** | 100.0% | 3 |
| **2,000** | 26.0 ms · 308 req/s | **15.5 ms · 515 req/s** | **+67%** | 100.0% | 4 |

---

## 4. Raw Benchmark Logs

- 3-Node DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
- 3-Node DOKS Tenant Sweep Log: [`run-tenants-doks.txt`](run-tenants-doks.txt)
