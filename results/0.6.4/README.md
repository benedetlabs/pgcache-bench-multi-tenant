# PgCache Benchmark Verification — Tag 0.6.4

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.4** (`pgcache/pgcache:0.6.4-arm64` / `pgcache/pgcache:0.6.4`) executed in local Docker environment across 1,000 tenants following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant counts (1..1,000), concurrency tiers, and write ratios.
- **Single-Client Baseline**: **2.05× faster** (5.15 ms vs 10.55 ms) with zero queuing.
- **Max Saturation Gain**: **+141% to +149%** at 8–16 clients and **+144%** at 32 clients (42.81 ms vs 104.07 ms, 748 rps).
- **Write Resilience**: Maintained **+135% to +146% throughput gain** under concurrent writes across 1,000 tenants.

---

## 2. Sweep 1 — Tenant Count Sweep

Evaluating query space expansion across 1, 10, 50, 200, 500, and 1,000 active tenants (concurrency fixed at 8 clients):

| Active Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 34.6 ms · 231 rps | 13.24 ms · 604 rps | +161% | 100.0% | 2 |
| 10 | 33.5 ms · 239 rps | 15.09 ms · 530 rps | +122% | 100.0% | 2 |
| 50 | 34.9 ms · 229 rps | 14.00 ms · 572 rps | +150% | 100.0% | 3 |
| 200 | 33.2 ms · 241 rps | 14.00 ms · 572 rps | +137% | 100.0% | 3 |
| 500 | 33.7 ms · 238 rps | 14.31 ms · 559 rps | +135% | 100.0% | 4 |
| 1000 | 33.6 ms · 238 rps | 14.52 ms · 551 rps | +132% | 100.0% | 5 |

---

## 3. Sweep 2 — Client Concurrency Sweep

Separating pure read cache speed from origin saturation (1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 10.5 ms · 95 rps | 5.15 ms · 194 rps | +104% | 100.0% | 2 |
| 4 | 18.8 ms · 213 rps | 10.51 ms · 381 rps | +79% | 100.0% | 2 |
| 8 | 38.1 ms · 210 rps | 15.34 ms · 522 rps | +149% | 100.0% | 2 |
| 16 | 61.6 ms · 260 rps | 25.54 ms · 627 rps | +141% | 100.0% | 2 |
| 32 | 104.1 ms · 307 rps | 42.81 ms · 748 rps | +144% | 100.0% | 2 |

---

## 4. Sweep 3 — Write Ratio and Concentration Sweep

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 34.3 ms · 233 rps | 13.86 ms · 577 rps | +148% | 100.0% | 2 |
| 5% | 1 | 32.1 ms · 249 rps | 13.38 ms · 598 rps | +140% | 100.0% | 2 |
| 5% | 10 | 32.3 ms · 248 rps | 13.10 ms · 611 rps | +146% | 100.0% | 2 |
| 5% | 1000 | 32.7 ms · 245 rps | 13.31 ms · 601 rps | +145% | 100.0% | 2 |
| 10% | 1 | 30.1 ms · 265 rps | 12.47 ms · 642 rps | +142% | 100.0% | 2 |
| 10% | 1000 | 29.8 ms · 268 rps | 12.67 ms · 631 rps | +135% | 100.0% | 2 |

---

## 5. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log: [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
