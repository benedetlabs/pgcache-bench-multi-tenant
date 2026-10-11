# PgCache Benchmark Verification — Tag 0.6.4

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.4** (`pgcache/pgcache:0.6.4-arm64` / `pgcache/pgcache:0.6.4`) executed in local Docker environment following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant counts, concurrency levels, and write ratios.
- **Single-Client Baseline**: **7.05× faster** (3.02 ms vs 21.28 ms) with zero queuing.
- **Max Saturation Gain**: **+1177%** at 16 concurrent clients (12.65 ms vs 161.05 ms) and **+1153%** at 32 clients.
- **Write Resilience**: Maintained **+744% throughput gain** under 10% writes across all 200 tenants.

---

## 2. Sweep 1 — Tenant Count Sweep

Evaluating query space expansion across 1, 10, 50, and 200 active tenants (concurrency fixed at 8 clients):

| Active Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 81.6 ms · 98 rps | 7.37 ms · 1,086 rps | +1008% | 100.0% | 2 |
| 10 | 79.9 ms · 100 rps | 7.25 ms · 1,104 rps | +1004% | 100.0% | 2 |
| 50 | 87.9 ms · 91 rps | 7.87 ms · 1,017 rps | +1018% | 100.0% | 3 |
| 200 | 84.9 ms · 94 rps | 7.90 ms · 1,012 rps | +977% | 100.0% | 5 |

---

## 3. Sweep 2 — Client Concurrency Sweep

Separating pure read cache speed from origin saturation (200 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 21.3 ms · 47 rps | 3.02 ms · 331 rps | +604% | 100.0% | 2 |
| 4 | 49.2 ms · 81 rps | 4.87 ms · 822 rps | +915% | 100.0% | 2 |
| 8 | 85.7 ms · 93 rps | 7.73 ms · 1,034 rps | +1012% | 100.0% | 2 |
| 16 | 161.0 ms · 99 rps | 12.65 ms · 1,264 rps | +1177% | 100.0% | 2 |
| 32 | 317.4 ms · 101 rps | 25.28 ms · 1,266 rps | +1153% | 100.0% | 2 |

---

## 4. Sweep 3 — Write Ratio and Concentration Sweep

Testing cache invalidation resilience with mixed reads and writes (8 clients, 200 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 200 | 90.8 ms · 88 rps | 7.62 ms · 1,050 rps | +1093% | 100.0% | 2 |
| 5% | 1 | 82.4 ms · 97 rps | 7.56 ms · 1,058 rps | +991% | 100.0% | 2 |
| 5% | 10 | 79.7 ms · 100 rps | 7.71 ms · 1,037 rps | +937% | 100.0% | 2 |
| 5% | 200 | 87.0 ms · 92 rps | 8.12 ms · 985 rps | +971% | 100.0% | 2 |
| 10% | 1 | 75.1 ms · 107 rps | 7.19 ms · 1,112 rps | +939% | 100.0% | 2 |
| 10% | 200 | 74.3 ms · 108 rps | 8.78 ms · 911 rps | +744% | 100.0% | 2 |

---

## 5. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log: [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
