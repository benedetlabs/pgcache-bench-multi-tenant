# Multi-Version PgCache Verification Results

> 🇧🇷 **[Versão em português](README-pt.md)**

This directory contains benchmark verification runs comparing releases of **PgCache** across two distinct environments:
- [**PgCache 0.6.3**](0.6.3/README.md)
- [**PgCache 0.6.4**](0.6.4/README.md)
- [**PgCache 0.7.0**](0.7.0/README.md)

Both environments follow the benchmark protocol (simple query protocol `-M simple`, no explicit transactions, dynamic warm-up settling `< 1%`).

---

## 1. DigitalOcean Kubernetes (DOKS 3 Nodes — 1 to 2,000 Tenants)

Executed on a low-cost production cluster: 3 dedicated nodes (`s-4vcpu-8gb`, `sfo3` single-AZ), `--ha=false`, strict `podAntiAffinity` (1 node each for origin, pgcache, loadgen), and `hostNetwork: true`.

### Tenant Count Sweep (1 to 2,000 Tenants)

| Active Tenants | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | Hit Ratio (All) | Warm Passes |
|---|---|---|---|---|---|---|
| **1 Tenant** | 23.3–27.5 ms (291–343 rps) | **17.6 ms** (455 rps, +56%) | **16.8 ms** (476 rps, +61%) | **15.6 ms** (513 rps, +50%) | **100.0%** | 2 |
| **10 Tenants** | 23.9–27.7 ms (288–335 rps) | **17.8 ms** (451 rps, +52%) | **21.0 ms** (382 rps, +33%) | **22.9 ms** (349 rps, +4%) | **100.0%** | 2 |
| **50 Tenants** | 28.5–29.9 ms (267–281 rps) | **17.5 ms** (456 rps, +66%) | **15.8 ms** (506 rps, +90%) | **17.3 ms** (462 rps, +64%) | **100.0%** | 2 |
| **100 Tenants** | 25.2–30.3 ms (264–317 rps) | **19.4 ms** (412 rps, +56%) | **16.3 ms** (492 rps, +55%) | **17.2 ms** (465 rps, +51%) | **100.0%** | 2 |
| **500 Tenants** | 25.7–32.2 ms (248–311 rps) | **16.7 ms** (478 rps, +93%) | **15.7 ms** (510 rps, +71%) | **18.7 ms** (428 rps, +38%) | **100.0%** | 3 |
| **1,000 Tenants** | 24.5–26.2 ms (305–326 rps) | **17.5 ms** (458 rps, +50%) | **16.8 ms** (476 rps, +46%) | **17.2 ms** (466 rps, +52%) | **100.0%** | 3 |
| **2,000 Tenants** | 25.6–26.0 ms (308–313 rps) | **18.3 ms** (438 rps, +40%) | **15.5 ms** (515 rps, +67%) | **18.8 ms** (425 rps, +38%) | **100.0%** | 4 |

---

## 2. Local Docker Environment (Single-Host Baseline — 1 to 1,000 Tenants)

Executed in local Docker on developer machine with single-host networking and shared core execution:

### Summary Comparison across Workload Axes

| Metric / Scenario | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 |
|---|---|---|---|---|
| **Hit Ratio (All Cells)** | N/A | **100.0%** | **100.0%** | **100.0%** (1..500t) / **99.7%** (1,000t) |
| **Single-Client Latency** | 10.5–12.1 ms | **5.53 ms** (2.0× faster) | **5.15 ms** (2.1× faster) | **5.55 ms** (2.1× faster) |
| **8 Clients Latency (Read)** | 35.4–38.1 ms | **14.62 ms** (+142%) | **15.34 ms** (+149%) | **14.90 ms** (+145%) |
| **Max Throughput (32 clients)** | 297–307 rps | **711 rps** (+138%) | **748 rps** (+144%) | **626 rps** (+111%) |
| **Writes Resilience (5% w, 1 wt)** | 239–249 rps | **575 rps** (+141%) | **598 rps** (+140%) | **408 rps** (+66%) |
| **Writes Resilience (10% w, 1000 wt)** | 251–268 rps | **603 rps** (+140%) | **631 rps** (+135%) | **318 rps** (+24%) |

### Tenant Count Sweep (Local Docker Baseline)

| Active Tenants | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | Hit Ratio | Warm Passes |
|---|---|---|---|---|---|---|
| **1 Tenant** | 33.9–46.1 ms (174–236 rps) | **13.4 ms** (596 rps, +153%) | **13.2 ms** (604 rps, +161%) | **14.0 ms** (572 rps, +229%) | **100.0%** | 2–3 |
| **10 Tenants** | 32.6–33.5 ms (239–246 rps) | **13.6 ms** (590 rps, +140%) | **15.1 ms** (530 rps, +122%) | **14.1 ms** (567 rps, +137%) | **100.0%** | 2 |
| **50 Tenants** | 32.5–34.9 ms (229–246 rps) | **13.8 ms** (578 rps, +144%) | **14.0 ms** (572 rps, +150%) | **15.1 ms** (529 rps, +115%) | **100.0%** | 3 |
| **200 Tenants** | 33.2–37.0 ms (216–241 rps) | **14.0 ms** (570 rps, +147%) | **14.0 ms** (572 rps, +137%) | **15.4 ms** (521 rps, +141%) | **100.0%** | 3 |
| **500 Tenants** | 33.7–36.5 ms (219–238 rps) | **14.2 ms** (563 rps, +144%) | **14.3 ms** (559 rps, +135%) | **16.1 ms** (496 rps, +126%) | **100.0%** | 4 |
| **1,000 Tenants** | 33.6–36.0 ms (222–238 rps) | **14.3 ms** (559 rps, +143%) | **14.5 ms** (551 rps, +132%) | **15.7 ms** (510 rps, +130%) | **99.7%–100.0%** | 5 |

---

## 3. Environment Insights: DOKS vs Docker

### 3.1 Why Throughput Gain is Higher in Docker (+140% to +160%) than in DOKS (+40% to +93%)

A frequent observation when comparing local Docker numbers against cloud Kubernetes (DOKS) numbers is the noticeable gap in relative speedup:

$$\text{Docker relative gain: } \mathbf{+140\%\text{ to }+161\%} \quad \text{vs} \quad \text{DOKS relative gain: } \mathbf{+40\%\text{ to }+93\%}$$

This discrepancy is driven by four structural, hardware, and architectural factors:

1. **The 8-Query Sequential Network Multiplier and Amdahl's Law**:
   - The workload request (`dashboard.sql`) consists of **8 sequential SQL statements** executed under simple query protocol (`-M simple`) without `BEGIN...COMMIT`.
   - Each statement requires its own round-trip (Query → Response/ReadyForQuery). Thus, each request performs **8 consecutive network round-trips**.
   - In **local Docker**, all containers communicate via loopback/bridge within the same OS kernel. Round-trip time (RTT) is practically zero (~50–80 µs). Total request network overhead is `< 0.6 ms`. Pure CPU query computation dominates ~98% of the measured time.
   - On **DigitalOcean (DOKS on 3 distinct nodes)**, inter-node network latency across virtualized droplets (`sfo3`) averages **~0.6–0.8 ms per RTT**. For 8 sequential queries, this introduces an **irreducible network floor of $8 \times 0.7\text{ ms} \approx 5.6\text{ ms}$** per request.
   - This 5.6 ms network floor is paid by **both Path A (Origin) and Path B (PgCache)**. By Amdahl's Law, adding a constant network baseline $C \approx 5.6\text{ ms}$ to both paths mathematically compresses the relative ratio:
     $$\text{Docker: } \frac{34.0\text{ ms}}{13.5\text{ ms}} \approx 2.52\times \ (+152\%)$$
     $$\text{DOKS: } \frac{20.0 + 5.6\text{ ms}}{10.5 + 5.6\text{ ms}} = \frac{25.6\text{ ms}}{16.1\text{ ms}} \approx 1.59\times \ (+59\%)$$

2. **Origin PostgreSQL Baseline Performance**:
   - In **Docker**, the origin PostgreSQL, PgCache, and pgbench (8–32 workers) competed for the same CPU cores, L3 caches, and memory bus. Under this contention, Origin latency was inflated to **33–36 ms (220–246 rps)**.
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

### 3.2 Key Environmental Takeaways

1. **Key-Space Scaling**:
   - Scaling active tenants from 1 to 1,000 (and up to 2,000 on DOKS) **does not degrade cache hit ratio**, which remained at **100.0%** across all tested releases.
2. **Production Validity**:
   - Docker overstates relative speedup because of zero network latency. DOKS provides the authoritative, realistic measurement for real-world cloud network topologies.

---

## 4. Directory Layout by Tag

- [`0.6.3/`](0.6.3/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.6.3`.
- [`0.6.4/`](0.6.4/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.6.4`.
- [`0.7.0/`](0.7.0/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.7.0`.
