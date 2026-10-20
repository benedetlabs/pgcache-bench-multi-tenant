# PgCache 0.7.0 Benchmark Report: Default vs. Tuned Network Profile on a 3-Node Cloud Cluster

> 🇧🇷 **[Ler em português](README-pt.md)**

This report documents the verification of **PgCache v0.7.0** (`pgcache/pgcache:0.7.0`) on our **3-node DigitalOcean Kubernetes (DOKS)** cluster (`3× s-4vcpu-8gb` in a single availability zone), comparing both the default cluster setup and our tuned Linux network & engine profile from 1 to 2,000 active tenants.

> **Why Only 3-Node Cloud Numbers Are Shown**: Local Docker Compose is used strictly to set up the database and test SQL correctness locally; all performance numbers come exclusively from the 3-node Kubernetes cluster.

---

## 1. Key Takeaways

- **100.0% Cache Hit Rate Up to 2,000 Tenants**: Across both the default and tuned profiles, PgCache 0.7.0 maintained a 100.0% hit ratio across all tenant tiers from 1 to 2,000 tenants.
- **Default Profile (+38% to +64% Gain)**: Reduced 8-query dashboard latency from **23.3–28.5 ms** on PostgreSQL down to **15.6–18.8 ms** on PgCache (up to **513 req/s**).
- **Tuned Profile Boosts High-Tenant Scaling (+38% → +67% at 2,000 Tenants)**: Enabling VirtIO multi-core packet steering (`rps_cpus=f`), direct node IP routing (bypassing CoreDNS), and 8 worker threads lifted the relative gain at 1,000–2,000 tenants to **+67%–+68%**.

---

## 2. Default vs. Tuned Cluster Configuration (3 Dedicated Cloud VMs)

| Setting | Default 3-Node DOKS | Tuned 3-Node DOKS |
|---|---|---|
| **Nodes** | 3× `s-4vcpu-8gb` (`sfo3` single-AZ, `--ha=false`) | 3× `s-4vcpu-8gb` (`sfo3` single-AZ, `--ha=false`) |
| **Node Isolation** | Strict `podAntiAffinity` + `hostNetwork: true` | Strict `podAntiAffinity` + `hostNetwork: true` |
| **Linux Network Stack** | OS Defaults | `tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_tw_reuse=1`, VirtIO RPS (`rps_cpus=f`) |
| **Host Resolution** | Headless Service DNS (`CoreDNS`) | Direct node IP routing |
| **PgCache Workers** | `NUM_WORKERS=4` | `NUM_WORKERS=8`, `PGCACHE_POPULATION_WORKERS_MIN=4`, `MEMO_CACHE_SIZE=1073741824` |

---

## 3. Scaling Active Tenants (`1` to `2,000` Tenants, 8 Concurrent Clients)

| Active Tenants | Default Origin | Default PgCache 0.7.0 | Default Gain | Tuned Origin | Tuned PgCache 0.7.0 | Tuned Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23.3 ms · 343 req/s | **15.6 ms · 513 req/s** | **+50%** | 30.4 ms · 263 req/s | **24.0 ms · 333 req/s** | **+27%** | 100.0% | 2 |
| **10** | 23.9 ms · 335 req/s | **22.9 ms · 349 req/s** | **+4%** | 33.1 ms · 242 req/s | **22.0 ms · 363 req/s** | **+50%** | 100.0% | 2 |
| **50** | 28.5 ms · 281 req/s | **17.3 ms · 462 req/s** | **+64%** | 32.7 ms · 245 req/s | **21.5 ms · 371 req/s** | **+51%** | 100.0% | 2 |
| **100** | 26.0 ms · 307 req/s | **17.2 ms · 465 req/s** | **+51%** | 33.0 ms · 243 req/s | **19.3 ms · 414 req/s** | **+70%** | 100.0% | 2 |
| **500** | 25.7 ms · 311 req/s | **18.7 ms · 428 req/s** | **+38%** | 30.0 ms · 266 req/s | **22.3 ms · 359 req/s** | **+35%** | 100.0% | 3 |
| **1,000** | 26.0 ms · 307 req/s | **17.2 ms · 466 req/s** | **+52%** | 33.2 ms · 241 req/s | **19.7 ms · 405 req/s** | **+68%** | 100.0% | 3 |
| **2,000** | 25.9 ms · 309 req/s | **18.8 ms · 425 req/s** | **+38%** | 34.2 ms · 234 req/s | **20.5 ms · 390 req/s** | **+67%** | 100.0% | 4 |

---

## 4. Raw Benchmark Logs

- 3-Node DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
- 3-Node DOKS Tenant Sweep Log: [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Tuned Profile Logs: [`../tuned/README.md`](../tuned/README.md)
