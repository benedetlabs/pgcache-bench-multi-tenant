# Multi-Version PgCache Verification Results

> 🇧🇷 **[Versão em português](README-pt.md)**

This directory contains benchmark verification runs comparing new releases of **PgCache**:
- [**PgCache 0.6.3**](0.6.3/README.md)
- [**PgCache 0.6.4**](0.6.4/README.md)
- [**PgCache 0.7.0**](0.7.0/README.md)

All tests were executed in the multi-tenant SaaS workload (500k orders, 2M order items, 200 tenants, 8 statements per dashboard query) using the repository's dynamic warmup (`warm_until_settled`) protocol.

---

## 1. Cross-Version Comparison Summary (1,000 Tenants Workload)

| Metric / Scenario | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 |
|---|---|---|---|---|
| **Hit Ratio (All Cells)** | N/A | **100.0%** | **100.0%** | **100.0%** (1..500t) / **99.7%** (1,000t) |
| **Single-Client Latency** | 10.5–11.5 ms | **5.53 ms** (2.0× faster) | **5.15 ms** (2.1× faster) | **5.55 ms** (2.1× faster) |
| **8 Clients Latency (Read)** | 35.4–38.1 ms | **14.62 ms** (+142%) | **15.34 ms** (+149%) | **14.90 ms** (+145%) |
| **Max Throughput (32 clients)** | 297–307 rps | **711 rps** (+138%) | **748 rps** (+144%) | **626 rps** (+111%) |
| **Writes Resilience (5% w, 1 wt)** | 239–249 rps | **575 rps** (+141%) | **598 rps** (+140%) | **408 rps** (+66%) |
| **Writes Resilience (10% w, 1000 wt)** | 251–268 rps | **603 rps** (+140%) | **631 rps** (+135%) | **318 rps** (+24%) |

---

## 2. Key Observations

1. **Query Cacheability across 1,000 Tenants**:
   Every version tested demonstrated remarkable cacheability under the expanded 1,000-tenant key space. Versions **0.6.3** and **0.6.4** sustained a perfect **100.0% hit ratio** across all 1,000 tenants. In **0.7.0**, the hit ratio reached **100.0%** up to 500 tenants and **99.7%** at 1,000 tenants with 5 warm-up passes.

2. **Throughput & Concurrency**:
   Read scaling was consistent across all three releases (~522–547 rps at 8 clients, up to ~626–748 rps at 32 clients), delivering over 2× latency reductions across every concurrency tier.

3. **CDC Write Invalidation Profiles**:
   Versions **0.6.3** and **0.6.4** sustained over 600 rps under a 10% write workload. Version **0.7.0** demonstrated higher background CPU utilization on the shared local Docker machine during CDC replication under concurrent writes (sustaining 318 rps), which will benefit from the isolated 3-node Kubernetes cluster.

---

## 3. Directory Layout by Tag

- [`0.6.3/`](0.6.3/): Full results, TSV, and raw outputs for tag `0.6.3`.
- [`0.6.4/`](0.6.4/): Full results, TSV, and raw outputs for tag `0.6.4`.
- [`0.7.0/`](0.7.0/): Full results, TSV, and raw outputs for tag `0.7.0`.

---

## 4. Reproducing Local Verifications

To run local verification for any tag:

```bash
./scripts/run-tag-verification.sh <tag> [duration_seconds]
# Example:
./scripts/run-tag-verification.sh 0.7.0 5
```
