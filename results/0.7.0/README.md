# PgCache Benchmark Verification — Tag 0.7.0

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.7.0** (`pgcache/pgcache:0.7.0-arm64` / `pgcache/pgcache:0.7.0`) executed in local Docker environment following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant counts, concurrency levels, and write ratios.
- **Single-Client Baseline**: **5.20× faster** (4.00 ms vs 20.78 ms) with zero queuing.
- **Max Saturation Gain**: **+896%** at 16 clients (15.30 ms vs 152.81 ms) and **+869%** at 32 clients (30.85 ms vs 300.46 ms, 1,037 rps).
- **Write Resilience**: Maintained **+83% to +401% throughput gain** under concurrent writes. In local single-host Docker environments, concurrent CDC invalidation introduces higher local CPU competition than earlier versions, which will benefit from isolated 3-node Kubernetes placement.

---

## 2. Sweep 1 — Tenant Count Sweep

Evaluating query space expansion across 1, 10, 50, and 200 active tenants (concurrency fixed at 8 clients):

| Active Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 85.6 ms · 93 rps | 9.23 ms · 867 rps | +832% | 100.0% | 2 |
| 10 | 87.3 ms · 92 rps | 8.83 ms · 906 rps | +885% | 100.0% | 2 |
| 50 | 81.6 ms · 98 rps | 9.29 ms · 861 rps | +779% | 100.0% | 3 |
| 200 | 93.7 ms · 85 rps | 10.00 ms · 800 rps | +841% | 100.0% | 4 |

---

## 3. Sweep 2 — Client Concurrency Sweep

Separating pure read cache speed from origin saturation (200 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 20.8 ms · 48 rps | 4.00 ms · 250 rps | +421% | 100.0% | 2 |
| 4 | 46.1 ms · 87 rps | 5.94 ms · 674 rps | +675% | 100.0% | 2 |
| 8 | 80.8 ms · 99 rps | 8.84 ms · 905 rps | +814% | 100.0% | 2 |
| 16 | 152.8 ms · 105 rps | 15.30 ms · 1,046 rps | +896% | 100.0% | 2 |
| 32 | 300.5 ms · 107 rps | 30.85 ms · 1,037 rps | +869% | 100.0% | 2 |

---

## 4. Sweep 3 — Write Ratio and Concentration Sweep

Testing cache invalidation resilience with mixed reads and writes (8 clients, 200 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 200 | 83.2 ms · 96 rps | 8.90 ms · 899 rps | +836% | 100.0% | 2 |
| 5% | 1 | 78.0 ms · 103 rps | 15.49 ms · 516 rps | +401% | 100.0% | 2 |
| 5% | 10 | 76.3 ms · 105 rps | 33.33 ms · 240 rps | +129% | 100.0% | 2 |
| 5% | 200 | 80.6 ms · 99 rps | 35.99 ms · 222 rps | +124% | 100.0% | 2 |
| 10% | 1 | 73.7 ms · 108 rps | 21.53 ms · 372 rps | +244% | 100.0% | 2 |
| 10% | 200 | 73.8 ms · 108 rps | 40.37 ms · 198 rps | +83% | 100.0% | 2 |

---

## 5. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log: [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
