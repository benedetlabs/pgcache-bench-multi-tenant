# PgCache 0.6.3 Benchmark Report: Scaling from 1 to 2,000 Tenants on a 3-Node Cloud Cluster

> 🇧🇷 **[Ler em português](README-pt.md)**

This report documents the baseline verification of **PgCache v0.6.3** (`pgcache/pgcache:0.6.3`) on a **3-node Kubernetes cluster in the cloud** (executed on DigitalOcean DOKS with `3× s-4vcpu-8gb` in a single availability zone, and reproducible on any cloud provider), running PostgreSQL 17, PgCache, and the benchmark client on three separate virtual machines. See the [**Workload Guide (`workload/README.md`)**](../../workload/README.md) and [`workload/dashboard.sql`](../../workload/dashboard.sql) for the exact SQL queries executed.

---

## 1. Key Takeaways

- **100.0% Cache Hit Rate Up to 2,000 Tenants**: Multiplying the number of active tenants from 1 to 2,000 did not cause cache evictions or degrade hit rate. Once warmed, PgCache answered 100% of queries from memory.
- **Consistent 1.4× to 1.9× Throughput Gain**: On the 8-query operational dashboard (`workload/dashboard.sql`), PgCache reduced full-screen response time from **25.6–32.2 ms** on PostgreSQL down to **16.7–19.4 ms**, delivering **+40% to +93% more screens per second**.
- **Predictable Warm-Up**: The cache settled within 2 warm-up passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants.

---

## 2. Cluster Setup (3 Dedicated Cloud VMs)

| Component | Configuration |
|---|---|
| **Cluster Topology** | 3 separate physical nodes on DigitalOcean (`sfo3` single-AZ, `--ha=false`) |
| **Node Size** | 3× `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM per VM) |
| **Node Isolation** | Strict `podAntiAffinity` (1 dedicated node each for `origin`, `pgcache`, and `loadgen`) |
| **Networking** | `hostNetwork: true` (direct node IP routing) |
| **Origin Database** | PostgreSQL 17, `shared_buffers=512MB`, 500k orders, 2M order items (~594 MB), 2,000 tenants |
| **PgCache** | `pgcache/pgcache:0.6.3`, `NUM_WORKERS=4` |

---

## 3. Scaling Active Tenants (`1` to `2,000` Tenants, 8 Concurrent Clients)

Each request executes all 8 SQL queries in `workload/dashboard.sql` sequentially:

| Active Tenants | PostgreSQL Direct (Path A) | PgCache 0.6.3 (Path B) | Speedup | Hit Ratio | Warm-up Passes |
|---:|---|---|---:|---:|---:|
| **1** | 27.5 ms · 291 req/s | **17.6 ms · 455 req/s** | **+56%** | 100.0% | 2 |
| **10** | 27.0 ms · 296 req/s | **17.8 ms · 451 req/s** | **+52%** | 100.0% | 2 |
| **50** | 29.2 ms · 274 req/s | **17.5 ms · 456 req/s** | **+66%** | 100.0% | 2 |
| **100** | 30.3 ms · 264 req/s | **19.4 ms · 412 req/s** | **+56%** | 100.0% | 2 |
| **500** | 32.2 ms · 248 req/s | **16.7 ms · 478 req/s** | **+93%** | 100.0% | 3 |
| **1,000** | 26.2 ms · 305 req/s | **17.5 ms · 458 req/s** | **+50%** | 100.0% | 3 |
| **2,000** | 25.6 ms · 313 req/s | **18.3 ms · 438 req/s** | **+40%** | 100.0% | 4 |

---

## 4. Raw Benchmark Logs

- 3-Node DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
- 3-Node DOKS Tenant Sweep Log: [`run-tenants-doks.txt`](run-tenants-doks.txt)
