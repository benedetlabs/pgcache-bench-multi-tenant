# PgCache Benchmark Verification — Tag 0.6.3

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.3** (`pgcache/pgcache:0.6.3-arm64` / `pgcache/pgcache:0.6.3`) executed in local Docker environment across 1,000 tenants following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant counts (1..1,000), concurrency tiers, and write ratios.
- **Single-Client Baseline**: **2.04× faster** (5.53 ms vs 11.25 ms) with zero queuing.
- **Max Saturation Gain**: **+140% to +142%** at 8–16 clients and **+138%** at 32 clients (45.02 ms vs 107.17 ms, 711 rps).
- **Write Resilience**: Maintained **+137% to +141% throughput gain** under concurrent writes across 1,000 tenants.

---

## 2. Sweep 1 — Tenant Count Sweep

Evaluating query space expansion across 1, 10, 50, 200, 500, and 1,000 active tenants (concurrency fixed at 8 clients):

| Active Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 33.9 ms · 236 rps | 13.42 ms · 596 rps | +153% | 100.0% | 2 |
| 10 | 32.6 ms · 246 rps | 13.57 ms · 590 rps | +140% | 100.0% | 2 |
| 50 | 33.7 ms · 237 rps | 13.84 ms · 578 rps | +144% | 100.0% | 3 |
| 200 | 34.6 ms · 231 rps | 14.05 ms · 570 rps | +147% | 100.0% | 3 |
| 500 | 34.6 ms · 231 rps | 14.22 ms · 563 rps | +144% | 100.0% | 4 |
| 1000 | 34.7 ms · 230 rps | 14.31 ms · 559 rps | +143% | 100.0% | 5 |

---

## 3. Sweep 2 — Client Concurrency Sweep

Separating pure read cache speed from origin saturation (1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 11.2 ms · 89 rps | 5.53 ms · 181 rps | +103% | 100.0% | 2 |
| 4 | 19.2 ms · 208 rps | 8.79 ms · 455 rps | +119% | 100.0% | 2 |
| 8 | 35.4 ms · 226 rps | 14.62 ms · 547 rps | +142% | 100.0% | 2 |
| 16 | 60.3 ms · 265 rps | 25.18 ms · 635 rps | +140% | 100.0% | 2 |
| 32 | 107.2 ms · 299 rps | 45.02 ms · 711 rps | +138% | 100.0% | 2 |

---

## 4. Sweep 3 — Write Ratio and Concentration Sweep

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35.1 ms · 228 rps | 14.52 ms · 551 rps | +142% | 100.0% | 2 |
| 5% | 1 | 33.5 ms · 239 rps | 13.92 ms · 575 rps | +141% | 100.0% | 2 |
| 5% | 10 | 33.3 ms · 240 rps | 14.03 ms · 570 rps | +138% | 100.0% | 2 |
| 5% | 1000 | 33.2 ms · 241 rps | 13.93 ms · 574 rps | +138% | 100.0% | 2 |
| 10% | 1 | 31.4 ms · 254 rps | 13.28 ms · 603 rps | +137% | 100.0% | 2 |
| 10% | 1000 | 31.9 ms · 251 rps | 13.27 ms · 603 rps | +140% | 100.0% | 2 |

---

## 5. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log: [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
