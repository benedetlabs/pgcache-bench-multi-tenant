# Multi-Version PgCache Verification Results (3-Node Kubernetes / DOKS)

> 🇧🇷 **[Versão em português](README-pt.md)**

This directory contains official benchmark verification runs comparing releases of **PgCache** across **3-Node DigitalOcean Kubernetes (DOKS)** and two workload complexity tiers:
- [**PgCache 0.6.3**](0.6.3/README.md)
- [**PgCache 0.6.4**](0.6.4/README.md)
- [**PgCache 0.7.0**](0.7.0/README.md)
- [**PgCache 0.7.1 (Baseline + Complex Multi-Tenant Scenarios)**](0.7.1/README.md)
- [**Sweep 5: 1h30m Endurance & Origin Resource Offload (`SCALE=20`)**](endurance-90m/README.md)
- [**Tuned Profile (v0.7.0)**](tuned/README.md)

> **Environment Policy**: All published benchmark performance results are collected **exclusively on 3-node Kubernetes clusters (DOKS)** with strict `podAntiAffinity` (`origin`, `pgcache`, and `loadgen` on three separate physical nodes). Local Docker Compose (`infra/docker-compose.yml`) is used solely for assembling the environment and executing functional/differential correctness tests (`scripts/verify-correctness.sh`).

---

## 1. DigitalOcean Kubernetes (DOKS 3 Nodes — 1 to 2,000 Tenants)

Executed on a production-topology cluster: 3 dedicated nodes (`s-4vcpu-8gb`, single-AZ), `--ha=false`, strict `podAntiAffinity` (1 node each for `origin`, `pgcache`, `loadgen`), and `hostNetwork: true`.

### 1.1 Multi-Version Baseline Sweep (1 to 2,000 Tenants)

| Active Tenants | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio (All) | Warm Passes |
|---|---|---|---|---|---|---|---|
| **1 Tenant** | 23.3–27.5 ms (291–343 rps) | **17.6 ms** (455 rps, +56%) | **16.8 ms** (476 rps, +61%) | **15.6 ms** (513 rps, +50%) | **16.6 ms** (481 rps, +40%) | **100.0%** | 2 |
| **10 Tenants** | 22.9–27.7 ms (288–350 rps) | **17.8 ms** (451 rps, +52%) | **21.0 ms** (382 rps, +33%) | **22.9 ms** (349 rps, +4%) | **21.7 ms** (369 rps, +5%) | **100.0%** | 2 |
| **50 Tenants** | 25.4–29.9 ms (267–315 rps) | **17.5 ms** (456 rps, +66%) | **15.8 ms** (506 rps, +90%) | **17.3 ms** (462 rps, +64%) | **17.0 ms** (470 rps, +49%) | **100.0%** | 2–3 |
| **100 Tenants** | 25.2–30.3 ms (264–317 rps) | **19.4 ms** (412 rps, +56%) | **16.3 ms** (492 rps, +55%) | **17.2 ms** (465 rps, +51%) | **16.3 ms** (491 rps, +63%) | **100.0%** | 2–3 |
| **500 Tenants** | 24.4–32.2 ms (248–329 rps) | **16.7 ms** (478 rps, +93%) | **15.7 ms** (510 rps, +71%) | **18.7 ms** (428 rps, +38%) | **16.3 ms** (490 rps, +49%) | **100.0%** | 3–4 |
| **1,000 Tenants** | 24.0–26.2 ms (305–333 rps) | **17.5 ms** (458 rps, +50%) | **16.8 ms** (476 rps, +46%) | **17.2 ms** (466 rps, +52%) | **16.9 ms** (473 rps, +42%) | **100.0%** | 3–4 |
| **2,000 Tenants** | 23.3–26.0 ms (308–343 rps) | **18.3 ms** (438 rps, +40%) | **15.5 ms** (515 rps, +67%) | **18.8 ms** (425 rps, +38%) | **16.5 ms** (485 rps, +41%) | **100.0%** | 4–6 |

### 1.2 Side-by-Side: Baseline vs Tuned Network & Engine Profile (PgCache 0.7.0)

Comparing the default cloud setup against the tuned profile (`tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_tw_reuse=1`, VirtIO RPS `rps_cpus=f`, direct host IP routing via `/etc/hosts`, `NUM_WORKERS=8`, and `MEMO_CACHE_SIZE=1073741824`):

| Active Tenants | Baseline Origin | Baseline PgCache | Baseline Gain | Tuned Origin | Tuned PgCache | Tuned Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23.3 ms · 343 rps | 15.6 ms · 513 rps | +50% | 30.4 ms · 263 rps | 24.0 ms · 333 rps | +27% | 100.0% | 2 |
| **10** | 23.9 ms · 335 rps | 22.9 ms · 349 rps | +4% | 33.1 ms · 242 rps | 22.0 ms · 363 rps | +50% | 100.0% | 2 |
| **50** | 28.5 ms · 281 rps | 17.3 ms · 462 rps | +64% | 32.7 ms · 245 rps | 21.5 ms · 371 rps | +51% | 100.0% | 2 |
| **100** | 26.0 ms · 307 rps | 17.2 ms · 465 rps | +51% | 33.0 ms · 243 rps | 19.3 ms · 414 rps | **+70%** | 100.0% | 2 |
| **500** | 25.7 ms · 311 rps | 18.7 ms · 428 rps | +38% | 30.0 ms · 266 rps | 22.3 ms · 359 rps | +35% | 100.0% | 3 |
| **1,000** | 26.0 ms · 307 rps | 17.2 ms · 466 rps | +52% | 33.2 ms · 241 rps | 19.7 ms · 405 rps | **+68%** | 100.0% | 3 |
| **2,000** | 25.9 ms · 309 rps | 18.8 ms · 425 rps | +38% | 34.2 ms · 234 rps | 20.5 ms · 390 rps | **+67%** | 100.0% | 4 |

---

## 2. Complex Multi-Tenant Scenarios on 3-Node DOKS (PgCache 0.7.1 — Materialized View Acceleration)

In **PgCache 0.7.1**, we expanded the benchmark beyond lightweight operational lookups (`workload/dashboard.sql`) into four realistic **complex enterprise SaaS workloads** (`scripts/04-complex-sweep.sh`) on **3-Node DigitalOcean Kubernetes (DOKS)**, and enforced a strict **Differential Correctness, Cacheability, MV Admission, and Post-CDC Gate** (`scripts/verify-correctness.sh`):
- **12/12 complex queries** verified byte-for-byte identical between Origin and PgCache across 3 static passes (`verify-correctness-doks.txt`, `TENANTS=2000`) plus Post-CDC live mutation verification.
- **100% cacheability** (`pgcache_queries_uncacheable == 0`), **100% Materialized View admission** (`pgcache_cache_mv_gate{outcome="admit"} == 12/12`, `reject == 0`), and **100% MV hit rate on Pass 3** (`pgcache_cache_mv_hits` delta `== 12/12`).

### 2.1 Workload Complexity Comparison (`TENANTS=200`, `CLIENTS=8` — 3-Node DOKS)

| Scenario | SQL Workload | DOKS Origin (Path A) | DOKS PgCache 0.7.1 (Path B) | DOKS Gain (Speedup) | Hit Ratio | Warm Passes |
|---|---|---|---|---:|---:|---:|
| **`dash_base`** | [`dashboard.sql`](../workload/dashboard.sql) (8 operational lookups) | 23.06 ms · 347 rps | **15.92 ms · 503 rps** | **+45% (1.45×)** | 100.0% | 2 |
| **`search`** | [`complex-search.sql`](../workload/complex-search.sql) (4 `ILIKE '%...%'` + `JOIN`/`LEFT JOIN`) | 74.26 ms · 108 rps | **5.04 ms · 1,586 rps** | **+1,369% (14.7×)** | 100.0% | 3 |
| **`joins`** | [`complex-joins.sql`](../workload/complex-joins.sql) (4 deep 4-to-6 table `JOIN` & `LEFT JOIN`) | 148.87 ms · 54 rps | **4.73 ms · 1,692 rps** | **+3,033% (31.3×)** | 100.0% | 3 |
| **`analytics`** | [`complex-analytics.sql`](../workload/complex-analytics.sql) (4 `GROUP BY` + `FILTER` + `CASE` + `HAVING`) | 102.38 ms · 78 rps | **5.69 ms · 1,406 rps** | **+1,703% (18.0×)** | 100.0% | 4 |
| **`cplx_dash`** | [`complex-dashboard.sql`](../workload/complex-dashboard.sql) (Unified 8-statement enterprise screen) | 204.39 ms · 39 rps | **11.50 ms · 696 rps** | **+1,685% (17.8×)** | 100.0% | 5 |

### 2.2 Concurrency Scaling on `complex-dashboard.sql` (`TENANTS=200` — 3-Node DOKS)

| Clients | DOKS Origin (Path A) | DOKS PgCache 0.7.1 (Path B) | DOKS Gain (Speedup) | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 100.60 ms · 10 rps | **7.14 ms · 140 rps** | **+1,300% (14.0×)** | 100.0% | 2 |
| **4** | 129.45 ms · 31 rps | **8.60 ms · 465 rps** | **+1,400% (15.0×)** | 100.0% | 2 |
| **8** | 212.81 ms · 38 rps | **10.48 ms · 763 rps** | **+1,908% (20.1×)** | 100.0% | 2 |
| **16** | 406.90 ms · 39 rps | **18.06 ms · 886 rps** | **+2,172% (22.7×)** | 100.0% | 2 |
| **32** | 835.52 ms · 38 rps | **31.36 ms · 1,020 rps** | **+2,584% (26.8×)** | 100.0% | 2 |

For full complex tenant scaling on 3-node DOKS (`100.0%` hit ratio from 1 to 500 tenants with `+2,133%` at 1 tenant, `+1,774%` at 200 tenants, and `+1,108%` at 500 tenants) and mixed write resilience (`63.1%–75.0%` hit ratio on DOKS across 5%–10% writes), see [`results/0.7.1/README.md`](0.7.1/README.md).

---

## 3. Architectural Insights: Network Floor & Amdahl's Law on 3-Node Cloud Clusters

1. **The 8-Query Sequential Network Multiplier and Amdahl's Law**:
   - Each request (`dashboard.sql` and `complex-dashboard.sql`) consists of **8 sequential SQL statements** executed under simple query protocol (`-M simple`) without `BEGIN...COMMIT`.
   - On **DigitalOcean (DOKS on 3 distinct nodes)**, inter-node network latency across virtualized droplets averages **~0.6–0.8 ms per RTT**. For 8 sequential queries, this introduces an **irreducible network floor of $8 \times 0.7\text{ ms} \approx 5.6\text{ ms}$** per request, paid by both Path A (Origin) and Path B (PgCache).
   - When the query workload is lightweight (`dashboard.sql`, `23.06 ms` on Origin), the `5.6 ms` network floor represents ~24% of total request time, bounding the relative speedup to **1.45×–1.93× (`+45%` to `+93%`)**.
   - When the query workload shifts to complex multi-table analytics (`complex-dashboard.sql`, `204.39 ms` on Origin), the `5.6 ms` network floor becomes `< 3%` of Origin execution time, and 3-node DOKS speedup surges to **17.8× (`+1,685%`)** at 8 clients and **26.8× (`+2,584%`)** at 32 clients (**31.3× / `+3,033%`** on `complex-joins.sql`).
2. **Why Local Docker Is Excluded from Benchmark Results**:
   - In single-host Docker (`infra/docker-compose.yml`), `origin`, `pgcache`, and `loadgen` share the same host CPU cores and communicate over loopback (`~50 µs` RTT), violating node isolation and artificially inflating relative speedup ratios. Local Docker is therefore restricted strictly to environment assembly and functional/correctness testing (`scripts/verify-correctness.sh`).

---

## 4. Directory Layout by Tag

- [`0.6.3/`](0.6.3/): Results and logs for `0.6.3`.
- [`0.6.4/`](0.6.4/): Results and logs for `0.6.4`.
- [`0.7.0/`](0.7.0/): Results and logs for `0.7.0`.
- [`0.7.1/`](0.7.1/): Official 3-node DOKS results (`results-doks.tsv`, `results-complex-doks.tsv`), differential correctness gate (`verify-correctness-doks.txt`), and complex scenario logs for `0.7.1`.
- [`endurance-90m/`](endurance-90m/): 1h30m endurance & Origin resource offload runbook and DOKS + Grafana Cloud telemetry (`SCALE=20`).
- [`tuned/`](tuned/): Results and logs for Tuned Profile (`0.7.0` with network & engine tuning on DOKS).
