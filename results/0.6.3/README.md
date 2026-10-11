# PgCache Benchmark Verification — Tag 0.6.3

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.3** (`pgcache/pgcache:0.6.3-arm64` / `pgcache/pgcache:0.6.3`) executed in local Docker environment following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant counts, concurrency levels, and write ratios.
- **Single-Client Baseline**: **7.37× faster** (3.36 ms vs 24.77 ms) with zero queuing.
- **Max Saturation Gain**: **+1299%** at 32 concurrent clients (23.34 ms vs 327.39 ms).
- **Write Resilience**: Maintained **+706% throughput gain** even under 10% writes distributed across all 200 tenants.

---

## 2. Sweep 1 — Tenant Count Sweep

Evaluating query space expansion across 1, 10, 50, and 200 active tenants (concurrency fixed at 8 clients):

| Active Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 88.3 ms · 91 rps | 7.55 ms · 1,060 rps | +1065% | 100.0% | 2 |
| 10 | 83.9 ms · 95 rps | 7.86 ms · 1,017 rps | +971% | 100.0% | 2 |
| 50 | 84.5 ms · 95 rps | 8.03 ms · 997 rps | +949% | 100.0% | 2 |
| 200 | 88.5 ms · 90 rps | 8.13 ms · 984 rps | +993% | 100.0% | 2 |

---

## 3. Sweep 2 — Client Concurrency Sweep

Separating pure read cache speed from origin saturation (200 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 24.8 ms · 40 rps | 3.36 ms · 298 rps | +645% | 100.0% | 2 |
| 4 | 49.2 ms · 81 rps | 4.91 ms · 814 rps | +905% | 100.0% | 2 |
| 8 | 86.7 ms · 92 rps | 7.68 ms · 1,041 rps | +1032% | 100.0% | 2 |
| 16 | 160.2 ms · 100 rps | 12.64 ms · 1,266 rps | +1166% | 100.0% | 2 |
| 32 | 327.4 ms · 98 rps | 23.34 ms · 1,371 rps | +1299% | 100.0% | 2 |

---

## 4. Sweep 3 — Write Ratio and Concentration Sweep

Testing cache invalidation resilience with mixed reads and writes (8 clients, 200 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 200 | 84.1 ms · 95 rps | 7.69 ms · 1,040 rps | +995% | 100.0% | 2 |
| 5% | 1 | 84.3 ms · 95 rps | 7.50 ms · 1,066 rps | +1022% | 100.0% | 2 |
| 5% | 10 | 79.9 ms · 100 rps | 7.77 ms · 1,029 rps | +929% | 100.0% | 2 |
| 5% | 200 | 84.2 ms · 95 rps | 8.28 ms · 967 rps | +918% | 100.0% | 2 |
| 10% | 1 | 81.4 ms · 98 rps | 7.62 ms · 1,050 rps | +971% | 100.0% | 2 |
| 10% | 200 | 79.2 ms · 101 rps | 9.83 ms · 814 rps | +706% | 100.0% | 2 |

---

## 5. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log: [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
