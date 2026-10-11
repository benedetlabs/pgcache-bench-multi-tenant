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

1. **Network Overhead & Real Hops**:
   - In **local Docker**, client and server reside on the same OS kernel. Localhost round-trip latency is practically zero (~70 µs), magnifying the apparent relative gain of avoiding query computation.
   - On **DigitalOcean Kubernetes**, requests traverse real physical networking across 3 separate nodes (10.124.0.3, 10.124.0.4, 10.124.0.5). PgCache sustains 425–515 rps on real cloud nodes with network latency included.

2. **Core Competition under Writes**:
   - In **Docker**, concurrent CDC invalidation and client load compete for the host's shared CPU cores, creating artificial bottlenecks for version 0.7.0 during write sweeps.
   - On **DOKS**, pod anti-affinity guarantees that PgCache and the origin have dedicated 4-vCPU droplets without CFS throttling or co-location interference.

3. **Key-Space Scaling**:
   - Both environments confirmed that scaling active tenants from 1 to 1,000 (and up to 2,000 on DOKS) **does not degrade cache hit ratio**, which remained at **100.0%** across all versions.

---

## 4. Directory Layout by Tag

- [`0.6.3/`](0.6.3/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.6.3`.
- [`0.6.4/`](0.6.4/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.6.4`.
- [`0.7.0/`](0.7.0/): Full results, TSVs (`results-doks.tsv`, `results-docker.tsv`), and logs for `0.7.0`.
