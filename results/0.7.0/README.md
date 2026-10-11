# PgCache Benchmark Verification — Tag 0.7.0

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.7.0** (`pgcache/pgcache:0.7.0-arm64` / `pgcache/pgcache:0.7.0`) executed in local Docker environment across 1,000 tenants following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across tenants 1..500 and **99.7%** at 1,000 tenants (first sign of key-space explosion / cold-set eviction).
- **Single-Client Baseline**: **2.06× faster** (5.55 ms vs 11.45 ms) with zero queuing.
- **Max Saturation Gain**: **+145%** at 8 clients (14.90 ms vs 36.48 ms, 537 rps) and **+111% to +126%** at 16–32 clients.
- **Write Resilience**: Maintained **+24% to +69% throughput gain** under concurrent writes across 1,000 tenants. In local single-host Docker environments, concurrent CDC invalidation introduces higher local CPU competition than earlier versions, which will benefit from isolated 3-node Kubernetes placement.

---

## 2. Sweep 1 — Tenant Count Sweep

Evaluating query space expansion across 1, 10, 50, 200, 500, and 1,000 active tenants (concurrency fixed at 8 clients):

| Active Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 46.1 ms · 174 rps | 13.98 ms · 572 rps | +229% | 100.0% | 3 |
| 10 | 33.5 ms · 239 rps | 14.12 ms · 567 rps | +137% | 100.0% | 2 |
| 50 | 32.5 ms · 246 rps | 15.13 ms · 529 rps | +115% | 100.0% | 3 |
| 200 | 37.0 ms · 216 rps | 15.37 ms · 521 rps | +141% | 100.0% | 3 |
| 500 | 36.5 ms · 219 rps | 16.13 ms · 496 rps | +126% | 100.0% | 4 |
| 1000 | 36.0 ms · 222 rps | 15.70 ms · 510 rps | +130% | 99.7% | 5 |

---

## 3. Sweep 2 — Client Concurrency Sweep

Separating pure read cache speed from origin saturation (1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 11.5 ms · 87 rps | 5.55 ms · 180 rps | +107% | 100.0% | 2 |
| 4 | 19.5 ms · 205 rps | 9.10 ms · 439 rps | +114% | 100.0% | 2 |
| 8 | 36.5 ms · 219 rps | 14.90 ms · 537 rps | +145% | 100.0% | 2 |
| 16 | 58.9 ms · 272 rps | 25.97 ms · 616 rps | +126% | 100.0% | 2 |
| 32 | 107.8 ms · 297 rps | 51.09 ms · 626 rps | +111% | 100.0% | 2 |

---

## 4. Sweep 3 — Write Ratio and Concentration Sweep

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35.6 ms · 225 rps | 14.91 ms · 537 rps | +139% | 100.0% | 2 |
| 5% | 1 | 32.5 ms · 246 rps | 19.60 ms · 408 rps | +66% | 100.0% | 2 |
| 5% | 10 | 31.6 ms · 253 rps | 19.43 ms · 412 rps | +63% | 100.0% | 2 |
| 5% | 1000 | 31.8 ms · 252 rps | 20.96 ms · 382 rps | +52% | 100.0% | 2 |
| 10% | 1 | 32.1 ms · 249 rps | 18.97 ms · 422 rps | +69% | 100.0% | 2 |
| 10% | 1000 | 31.2 ms · 257 rps | 25.14 ms · 318 rps | +24% | 100.0% | 2 |

---

## 5. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log: [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
