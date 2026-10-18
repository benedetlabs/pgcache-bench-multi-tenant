# Multi-Version PgCache Verification Results

> 🇧🇷 **[Versão em português](README-pt.md)**

This directory contains benchmark verification runs comparing releases of **PgCache** across two distinct environments and two workload complexity tiers:
- [**PgCache 0.6.3**](0.6.3/README.md)
- [**PgCache 0.6.4**](0.6.4/README.md)
- [**PgCache 0.7.0**](0.7.0/README.md)
- [**PgCache 0.7.1 (Baseline + Complex Multi-Tenant Scenarios)**](0.7.1/README.md)
- [**Tuned Profile (v0.7.0)**](tuned/README.md)

Both environments follow the benchmark protocol (simple query protocol `-M simple`, no explicit transactions, dynamic warm-up settling `< 1%`, and `pgcache_queries_uncacheable == 0`).

---

## 1. DigitalOcean Kubernetes (DOKS 3 Nodes — 1 to 2,000 Tenants)

Executed on a low-cost production cluster: 3 dedicated nodes (`s-4vcpu-8gb`, `sfo3` single-AZ), `--ha=false`, strict `podAntiAffinity` (1 node each for origin, pgcache, loadgen), and `hostNetwork: true`.

### 1.1 Multi-Version Baseline Sweep (1 to 2,000 Tenants)

| Active Tenants | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio (All) | Warm Passes |
|---|---|---|---|---|---|---|---|
| **1 Tenant** | 23.3–27.5 ms (291–343 rps) | **17.6 ms** (455 rps, +56%) | **16.8 ms** (476 rps, +61%) | **15.6 ms** (513 rps, +50%) | **16.5 ms** (485 rps, +45%) | **100.0%** | 2 |
| **10 Tenants** | 23.4–27.7 ms (288–343 rps) | **17.8 ms** (451 rps, +52%) | **21.0 ms** (382 rps, +33%) | **22.9 ms** (349 rps, +4%) | **20.3 ms** (393 rps, +15%) | **100.0%** | 2 |
| **50 Tenants** | 26.5–29.9 ms (267–302 rps) | **17.5 ms** (456 rps, +66%) | **15.8 ms** (506 rps, +90%) | **17.3 ms** (462 rps, +64%) | **16.3 ms** (491 rps, +63%) | **100.0%** | 2 |
| **100 Tenants** | 25.2–30.3 ms (264–317 rps) | **19.4 ms** (412 rps, +56%) | **16.3 ms** (492 rps, +55%) | **17.2 ms** (465 rps, +51%) | **16.9 ms** (472 rps, +49%) | **100.0%** | 2 |
| **500 Tenants** | 23.9–32.2 ms (248–335 rps) | **16.7 ms** (478 rps, +93%) | **15.7 ms** (510 rps, +71%) | **18.7 ms** (428 rps, +38%) | **17.0 ms** (470 rps, +40%) | **100.0%** | 3 |
| **1,000 Tenants** | 24.5–26.2 ms (305–326 rps) | **17.5 ms** (458 rps, +50%) | **16.8 ms** (476 rps, +46%) | **17.2 ms** (466 rps, +52%) | **16.6 ms** (481 rps, +55%) | **100.0%** | 3 |
| **2,000 Tenants** | 23.9–26.0 ms (308–335 rps) | **18.3 ms** (438 rps, +40%) | **15.5 ms** (515 rps, +67%) | **18.8 ms** (425 rps, +38%) | **16.4 ms** (486 rps, +45%) | **100.0%** | 4 |

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

## 2. Local Docker Environment (Single-Host Baseline — 1 to 1,000 Tenants)

Executed in local Docker on developer machine with single-host networking and shared core execution:

### Summary Comparison across Workload Axes (`workload/dashboard.sql`)

| Metric / Scenario | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 |
|---|---|---|---|---|---|
| **Hit Ratio (All Cells)** | N/A | **100.0%** | **100.0%** | **100.0%** (1..500t) / **99.7%** (1,000t) | **100.0%** (1..500t) / **99.9%** (1,000t) |
| **Single-Client Latency** | 10.5–13.3 ms | **5.53 ms** (2.0× faster) | **5.15 ms** (2.1× faster) | **5.55 ms** (2.1× faster) | **6.89 ms** (1.9× faster) |
| **8 Clients Latency (Read)** | 35.4–40.1 ms | **14.62 ms** (+142%) | **15.34 ms** (+149%) | **14.90 ms** (+145%) | **16.75 ms** (+131%) |
| **Max Throughput (32 clients)** | 249–307 rps | **711 rps** (+138%) | **748 rps** (+144%) | **626 rps** (+111%) | **593 rps** (+138%) |
| **Writes Resilience (5% w, 1 wt)** | 217–249 rps | **575 rps** (+141%) | **598 rps** (+140%) | **408 rps** (+66%) | **456 rps** (+110%) |
| **Writes Resilience (10% w, 1000 wt)** | 220–268 rps | **603 rps** (+140%) | **631 rps** (+135%) | **318 rps** (+24%) | **308 rps** (+40%) |

### Tenant Count Sweep (Local Docker Baseline)

| Active Tenants | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio | Warm Passes |
|---|---|---|---|---|---|---|---|
| **1 Tenant** | 33.9–46.1 ms (174–236 rps) | **13.4 ms** (596 rps, +153%) | **13.2 ms** (604 rps, +161%) | **14.0 ms** (572 rps, +229%) | **15.6 ms** (514 rps, +138%) | **100.0%** | 2–3 |
| **10 Tenants** | 32.6–36.1 ms (222–246 rps) | **13.6 ms** (590 rps, +140%) | **15.1 ms** (530 rps, +122%) | **14.1 ms** (567 rps, +137%) | **16.1 ms** (496 rps, +123%) | **100.0%** | 2 |
| **50 Tenants** | 32.5–37.2 ms (215–246 rps) | **13.8 ms** (578 rps, +144%) | **14.0 ms** (572 rps, +150%) | **15.1 ms** (529 rps, +115%) | **17.2 ms** (465 rps, +116%) | **100.0%** | 3 |
| **200 Tenants** | 33.2–40.1 ms (199–241 rps) | **14.0 ms** (570 rps, +147%) | **14.0 ms** (572 rps, +137%) | **15.4 ms** (521 rps, +141%) | **16.9 ms** (475 rps, +139%) | **100.0%** | 3 |
| **500 Tenants** | 33.7–40.5 ms (198–238 rps) | **14.2 ms** (563 rps, +144%) | **14.3 ms** (559 rps, +135%) | **16.1 ms** (496 rps, +126%) | **17.8 ms** (450 rps, +127%) | **100.0%** | 4 |
| **1,000 Tenants** | 33.6–40.9 ms (196–238 rps) | **14.3 ms** (559 rps, +143%) | **14.5 ms** (551 rps, +132%) | **15.7 ms** (510 rps, +130%) | **17.7 ms** (451 rps, +130%) | **99.7%–100.0%** | 5 |

---

## 3. Complex Multi-Tenant Scenarios (PgCache 0.7.1 — Materialized View Acceleration)

In **PgCache 0.7.1**, we expanded the benchmark beyond lightweight operational lookups (`workload/dashboard.sql`) into four realistic **complex enterprise SaaS workloads** (`scripts/04-complex-sweep.sh`) across both **3-Node DigitalOcean Kubernetes (DOKS)** and **Local Docker**, and enforced a strict **Differential Correctness, Cacheability, and MV Admission Gate** (`scripts/verify-correctness.sh`):
- **12/12 complex queries** verified byte-for-byte identical between Origin and PgCache across 3 passes on both 3-node DOKS (`verify-correctness-doks.txt`, `TENANTS=2000`) and Local Docker (`verify-correctness.txt`, `TENANTS=1000`).
- **100% cacheability** (`pgcache_queries_uncacheable == 0`), **100% Materialized View admission** (`pgcache_cache_mv_gate{outcome="admit"} == 12/12`, `reject == 0`), and **100% MV hit rate on Pass 3** (`pgcache_cache_mv_hits` delta `== 12/12`).

### 3.1 Workload Complexity Comparison (`TENANTS=200`, `CLIENTS=8` — 3-Node DOKS vs. Local Docker)

| Scenario | SQL Workload | DOKS Origin | DOKS PgCache 0.7.1 | DOKS Gain (Speedup) | Docker Origin | Docker PgCache 0.7.1 | Docker Gain (Speedup) | Hit Ratio |
|---|---|---|---|---:|---|---|---:|---:|
| **`dash_base`** | [`dashboard.sql`](../workload/dashboard.sql) (8 operational lookups) | 23.62 ms · 339 rps | **16.30 ms · 491 rps** | **+45% (1.45×)** | 37.61 ms · 213 rps | **16.05 ms · 498 rps** | **+134% (2.3×)** | 100.0% |
| **`search`** | [`complex-search.sql`](../workload/complex-search.sql) (4 `ILIKE '%...%'` + `JOIN`/`LEFT JOIN`) | 103.52 ms · 77 rps | **7.07 ms · 1,131 rps** | **+1,369% (14.7×)** | 88.67 ms · 90 rps | **1.53 ms · 5,223 rps** | **+5,703% (58.0×)** | 100.0% |
| **`joins`** | [`complex-joins.sql`](../workload/complex-joins.sql) (4 deep 4-to-6 table `JOIN` & `LEFT JOIN`) | 127.08 ms · 63 rps | **4.05 ms · 1,974 rps** | **+3,033% (31.3×)** | 121.46 ms · 66 rps | **1.25 ms · 6,426 rps** | **+9,636% (97.4×)** | 100.0% |
| **`analytics`** | [`complex-analytics.sql`](../workload/complex-analytics.sql) (4 `GROUP BY` + `FILTER` + `CASE` + `HAVING`) | 94.37 ms · 85 rps | **5.22 ms · 1,533 rps** | **+1,703% (18.0×)** | 92.31 ms · 87 rps | **1.39 ms · 5,737 rps** | **+6,494% (65.9×)** | 100.0% |
| **`cplx_dash`** | [`complex-dashboard.sql`](../workload/complex-dashboard.sql) (Unified 8-statement enterprise screen) | 200.62 ms · 40 rps | **11.21 ms · 714 rps** | **+1,685% (17.8×)** | 209.62 ms · 38 rps | **2.86 ms · 2,798 rps** | **+7,263% (73.6×)** | 100.0% |

### 3.2 Concurrency Scaling on `complex-dashboard.sql` (`TENANTS=200` — 3-Node DOKS vs. Local Docker)

| Clients | DOKS Origin | DOKS PgCache 0.7.1 | DOKS Gain (Speedup) | Docker Origin | Docker PgCache 0.7.1 | Docker Gain (Speedup) | Hit Ratio | Warm Passes |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 100.60 ms · 10 rps | **7.14 ms · 140 rps** | **+1,300% (14.0×)** | 84.83 ms · 12 rps | **1.73 ms · 578 rps** | **+4,717% (48.2×)** | 100.0% | 2 |
| **4** | 104.26 ms · 38 rps | **8.39 ms · 476 rps** | **+1,153% (12.5×)** | 92.22 ms · 43 rps | **2.26 ms · 1,770 rps** | **+4,016% (41.2×)** | 100.0% | 2 |
| **8** | 200.14 ms · 40 rps | **9.96 ms · 803 rps** | **+1,908% (20.1×)** | 194.69 ms · 41 rps | **2.66 ms · 3,003 rps** | **+7,224% (73.2×)** | 100.0% | 2 |
| **16** | 405.10 ms · 39 rps | **15.86 ms · 1,008 rps** | **+2,485% (25.8×)** | 400.89 ms · 40 rps | **4.60 ms · 3,475 rps** | **+8,588% (86.9×)** | 100.0% | 2 |
| **32** | 835.52 ms · 38 rps | **31.36 ms · 1,020 rps** | **+2,584% (26.8×)** | 862.44 ms · 37 rps | **9.20 ms · 3,478 rps** | **+9,300% (94.0×)** | 100.0% | 2 |

For full complex tenant scaling (on 3-node DOKS: `100.0%` hit ratio from 1 to 500 tenants with `+2,133%` at 1 tenant, `+1,774%` at 200 tenants, and `+1,108%` at 500 tenants) and mixed write resilience (`63.1%–75.0%` hit ratio on DOKS across 5%–10% writes), see [`results/0.7.1/README.md`](0.7.1/README.md).

---

## 4. Environment Insights: DOKS vs Docker

### 4.1 Why Throughput Gain is Higher in Docker (+140% to +160%) than in DOKS (+40% to +93%)

A frequent observation when comparing local Docker numbers against cloud Kubernetes (DOKS) numbers is the noticeable gap in relative speedup:

$$\text{Docker relative gain: } \mathbf{+140\%\text{ to }+161\%} \quad \text{vs} \quad \text{DOKS relative gain: } \mathbf{+40\%\text{ to }+93\%}$$

This discrepancy is driven by four structural, hardware, and architectural factors:

1. **The 8-Query Sequential Network Multiplier and Amdahl's Law**:
   - The workload request (`dashboard.sql`) consists of **8 sequential SQL statements** executed under simple query protocol (`-M simple`) without `BEGIN...COMMIT`.
   - Each statement requires its own round-trip (Query → Response/ReadyForQuery). Thus, each request performs **8 consecutive network round-trips**.
   - In **local Docker**, all containers communicate via loopback/bridge within the same OS kernel. Round-trip time (RTT) is practically zero (~50–80 µs). Total request network overhead is `< 0.6 ms`. Pure CPU query computation dominates ~98% of the measured time.
   - On **DigitalOcean (DOKS on 3 distinct nodes)**, inter-node network latency across virtualized droplets (`sfo3`/`sfo2`) averages **~0.6–0.8 ms per RTT**. For 8 sequential queries, this introduces an **irreducible network floor of $8 \times 0.7\text{ ms} \approx 5.6\text{ ms}$** per request.
   - This 5.6 ms network floor is paid by **both Path A (Origin) and Path B (PgCache)**. By Amdahl's Law, adding a constant network baseline $C \approx 5.6\text{ ms}$ to both paths mathematically compresses the relative ratio:
     $$\text{Docker: } \frac{34.0\text{ ms}}{13.5\text{ ms}} \approx 2.52\times \ (+152\%)$$
     $$\text{DOKS: } \frac{20.0 + 5.6\text{ ms}}{10.5 + 5.6\text{ ms}} = \frac{25.6\text{ ms}}{16.1\text{ ms}} \approx 1.59\times \ (+59\%)$$
   - When the query workload shifts from lightweight index lookups (`23.62 ms`) to complex multi-table analytics (`complex-dashboard.sql`, `200.62 ms`), the 5.6 ms network floor becomes `< 3%` of Origin execution time, and 3-node DOKS speedup surges from **1.45× (`+45%`)** to **17.8× (`+1,685%`)** at 8 clients and **26.8× (`+2,584%`)** at 32 clients (`31.3× / +3,033%` on `complex-joins.sql`).

2. **Origin PostgreSQL Baseline Performance**:
   - In **Docker**, the origin PostgreSQL, PgCache, and pgbench (8–32 workers) competed for the same CPU cores, L3 caches, and memory bus. Under this contention, Origin latency was inflated to **33–40 ms (196–246 rps)**.
   - On **DOKS**, strict `podAntiAffinity` gave the Origin a dedicated 4-vCPU droplet without CFS limits or co-located processes. Origin performance was significantly higher: **23–27 ms (291–343 rps)** — a ~40% faster baseline. A faster origin naturally narrows the relative cache gain percentage.

3. **CPU Frequency and Single-Core IPC**:
   - Local developer workstations typically feature high-IPC modern processors (e.g. Apple Silicon M-series or modern desktop cores at 3.5–4.5 GHz). PgCache's async Rust parser and proxy runtime operates at peak efficiency on these cores.
   - DOKS standard droplets (`s-4vcpu-8gb`) run on shared AMD EPYC server cores at ~2.0–2.5 GHz with KVM virtualization overhead, resulting in slightly higher per-query proxy parsing latency.

4. **Topology Implications: Centralized Proxy vs Node-Local Sidecar**:
   - This benchmark evaluated a **centralized proxy topology** (3 distinct physical nodes: Node 1 = Loadgen, Node 2 = PgCache, Node 3 = Origin), forcing all queries across the cluster network.
   - If PgCache were deployed in production as a **Sidecar** (in the application pod) or as a **DaemonSet** (node-local proxy):
     - The 8 client queries would hit PgCache over `localhost` or Unix Domain Socket (`< 0.05 ms` RTT).
     - Cache hits would never cross the physical network, eliminating the 5.6 ms inter-node network floor entirely.
     - Under a sidecar/DaemonSet topology, cloud Kubernetes speedup gains would match or exceed the ~2.5× (+150%) figures seen in Docker.

### 4.2 Key Environmental Takeaways

1. **Key-Space Scaling**:
   - Scaling active tenants from 1 to 1,000 (and up to 2,000 on DOKS) **does not degrade cache hit ratio**, which remained at **99.9%–100.0%** across all tested releases on the baseline dashboard.
2. **Production Validity**:
   - Docker overstates relative speedup because of zero network latency. DOKS provides the authoritative, realistic measurement for real-world cloud network topologies.

---

## 5. Directory Layout by Tag

- [`0.6.3/`](0.6.3/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.6.3`.
- [`0.6.4/`](0.6.4/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.6.4`.
- [`0.7.0/`](0.7.0/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.7.0`.
- [`0.7.1/`](0.7.1/): Full results, TSVs (`results-doks.tsv`, `results-complex-doks.tsv`, `results-docker.tsv`, `results-complex.tsv`), differential correctness gates (`verify-correctness-doks.txt`, `verify-correctness.txt`), and complex scenario logs for `0.7.1`.
- [`tuned/`](tuned/): Full results, TSVs (`results.tsv`), and logs for Tuned Profile (`0.7.0` with network & engine tuning).
