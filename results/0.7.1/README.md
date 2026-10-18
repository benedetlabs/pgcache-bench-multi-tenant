# PgCache Benchmark Verification — Tag 0.7.1 (Baseline & Complex Multi-Tenant Scenarios)

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.7.1** (`pgcache/pgcache:0.7.1-arm64` / `pgcache/pgcache:0.7.1`) covering two benchmark suites:
1. **Baseline Operational Dashboard (`workload/dashboard.sql`)**: Full regression verification across 1 to 1,000 tenants, 1 to 32 concurrent clients, and 0%–10% mixed write workloads (`scripts/01`–`03`).
2. **Complex Multi-Tenant SaaS Workloads (`scripts/04-complex-sweep.sh`)**: Substring text search (`ILIKE '%...%'`), deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (including zero-order customer cohorts and unreviewed product inventory), multi-dimensional analytical aggregations (`GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`), and a unified 8-statement enterprise analytics & search screen (`workload/complex-dashboard.sql`), verified by a strict **Differential Correctness, Cacheability, and MV Admission Gate** (`scripts/verify-correctness.sh`).

---

## 1. Executive Summary

- **Differential Correctness & 100% Cacheability Gate (`verify-correctness.txt`)**:
  - All **8/8 complex multi-tenant SQL queries** in `workload/complex-dashboard.sql` produced byte-for-byte identical result sets between Origin PostgreSQL 17 and PgCache 0.7.1 across both cold (Pass 1) and warm (Pass 2) executions.
  - **100% Cacheability**: `pgcache_queries_cacheable` delta = `16/16`, `pgcache_queries_uncacheable` delta = **`0`**, `pgcache_queries_error` delta = **`0`**.
  - **100% Materialized View (MV) Gate Admission**: `pgcache_cache_mv_gate{result="admitted"}` = **`8/8`** (`rejected = 0`).
- **Baseline Dashboard (`workload/dashboard.sql`)**:
  - **Hit Ratio**: **100.0%** from 1 to 500 tenants and **99.9%** at 1,000 tenants.
  - **Throughput Gain**: **+116% to +139%** across tenant scaling (`450–514 rps` vs `196–222 rps` on Origin), **+93% to +138%** across concurrency scaling (`1..32` clients), and **+40% to +110%** under 5%–10% write ratios.
- **Complex Multi-Tenant Workloads (`workload/complex-*.sql`)**:
  - **Read-Heavy Speedup**: Once admitted into PgCache's Materialized View engine (`pgcache_mv.q_<hash>`), expensive 4-to-6 table `JOIN`/`LEFT JOIN`/`GROUP BY`/`ILIKE` queries drop from **95.8–217.4 ms** on Origin to **1.31–2.73 ms** on PgCache (~0.33 ms per statement), delivering **72.8× to 96.8× higher throughput (`+7,183%` to `+9,575%`)** at 8 clients and up to **108.0× (`+10,697%`, `3,260 rps` vs `33 rps`)** under 16–32 concurrent clients.
  - **Write Invalidation Trade-off on Multi-Table MVs**: While simple operational queries (`dashboard.sql`) sustain **+40% to +110%** gains under 5%–10% `UPDATE orders` traffic, complex 6-table analytical MVs that join `orders` suffer full MV invalidation and rebuild overhead (`pgcache_cache_mv_rebuilds`, ~50–100 ms per 6-table view rebuild) under continuous writes to the central `orders` fact table.

---

## 2. Differential Correctness, Cacheability & MV Admission Gate

Executed via [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) (raw log: [`verify-correctness.txt`](verify-correctness.txt)):

| Check | Result | Telemetry / Detail |
|---|---|---|
| **Byte-for-Byte Output Equality** | **PASS (8/8 queries)** | `psql -X -A -t` output identical between Origin and PgCache on Pass 1 & Pass 2 |
| **Cacheable Queries Delta** | **PASS (`16 / 16`)** | `pgcache_queries_cacheable` incremented by 16 across 2 passes of 8 statements |
| **Uncacheable Queries Delta** | **PASS (`0`)** | `pgcache_queries_uncacheable` delta = `0` (all expressions pre-computed via `\set`) |
| **MV Gate Admission** | **PASS (`8 / 8`)** | `pgcache_cache_mv_gate{result="admitted"}` = `8`, `rejected` = `0` |
| **Cache Errors Delta** | **PASS (`0`)** | `pgcache_queries_error` delta = `0` |

---

## 3. Baseline Sweeps 1–3 (`workload/dashboard.sql`)

### 3.1 Sweep 1 — Tenant Count Sweep (1 to 1,000 Tenants, `CLIENTS=8`)

| Active Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 37.08 ms · 216 rps | **15.56 ms · 514 rps** | **+138%** | 100.0% | 2 |
| **10** | 36.11 ms · 222 rps | **16.13 ms · 496 rps** | **+123%** | 100.0% | 2 |
| **50** | 37.21 ms · 215 rps | **17.22 ms · 465 rps** | **+116%** | 100.0% | 3 |
| **200** | 40.11 ms · 199 rps | **16.86 ms · 475 rps** | **+139%** | 100.0% | 3 |
| **500** | 40.48 ms · 198 rps | **17.78 ms · 450 rps** | **+127%** | 100.0% | 4 |
| **1,000** | 40.87 ms · 196 rps | **17.73 ms · 451 rps** | **+130%** | 99.9% | 5 |

### 3.2 Sweep 2 — Client Concurrency Sweep (`TENANTS=1,000`)

| Clients | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 13.26 ms · 75 rps | **6.89 ms · 145 rps** | **+93%** | 100.0% | 2 |
| **4** | 21.82 ms · 183 rps | **9.82 ms · 408 rps** | **+123%** | 100.0% | 2 |
| **8** | 38.67 ms · 207 rps | **16.75 ms · 478 rps** | **+131%** | 100.0% | 2 |
| **16** | 67.48 ms · 237 rps | **30.76 ms · 520 rps** | **+119%** | 100.0% | 2 |
| **32** | 128.51 ms · 249 rps | **53.93 ms · 593 rps** | **+138%** | 100.0% | 2 |

### 3.3 Sweep 3 — Write Ratio and Concentration Sweep (`TENANTS=1,000`, `CLIENTS=8`)

| Writes | Write Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 1,000 | 40.60 ms · 197 rps | **16.83 ms · 475 rps** | **+141%** | 100.0% | 2 |
| **5%** | 1 | 36.80 ms · 217 rps | **17.55 ms · 456 rps** | **+110%** | 100.0% | 2 |
| **5%** | 10 | 37.12 ms · 215 rps | **20.91 ms · 383 rps** | **+78%** | 100.0% | 2 |
| **5%** | 1,000 | 38.89 ms · 206 rps | **23.23 ms · 344 rps** | **+67%** | 100.0% | 2 |
| **10%** | 1 | 35.99 ms · 222 rps | **18.59 ms · 430 rps** | **+94%** | 100.0% | 2 |
| **10%** | 1,000 | 36.41 ms · 220 rps | **25.98 ms · 308 rps** | **+40%** | 100.0% | 2 |

---

## 4. Sweep 4 — Complex Multi-Tenant Scenarios (`scripts/04-complex-sweep.sh`)

To evaluate how PgCache behaves on heavy relational workloads beyond primary-key and single-join lookups, we designed four complex multi-tenant SQL suites under [`workload/`](../../workload/):
1. **[`complex-search.sql`](../../workload/complex-search.sql)** (4 statements): Substring `ILIKE '%...%'` text searches across customer emails/names, product names, seller names, and review bodies combined with 2-to-4 table `INNER JOIN` and `LEFT JOIN` chains.
2. **[`complex-joins.sql`](../../workload/complex-joins.sql)** (4 statements): Deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (`orders -> customer -> order_item -> product -> category -> seller -> review`), including customer cohort retention (`LEFT JOIN orders`) and unreviewed product inventory (`LEFT JOIN review`).
3. **[`complex-analytics.sql`](../../workload/complex-analytics.sql)** (4 statements): Multi-dimensional `GROUP BY` rollups with conditional `FILTER (WHERE ...)`, `CASE WHEN` fulfillment & price-tier buckets, and `HAVING` thresholds.
4. **[`complex-dashboard.sql`](../../workload/complex-dashboard.sql)** (8 statements): Unified enterprise analytics & search screen combining 2 search queries, 3 deep multi-table `JOIN` / `LEFT JOIN` queries, and 3 heavy analytical rollups.

### 4.1 Scenario Comparison (`TENANTS=200`, `CLIENTS=8`)

Raw log: [`run-complex-scenarios.txt`](run-complex-scenarios.txt)

| Scenario | Statements | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Speedup | Hit Ratio | Warm Passes |
|---|---:|---|---|---:|---:|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 40.57 ms · 197 rps | **17.11 ms · 468 rps** | **+138%** | **2.4×** | 100.0% | 3 |
| **`search`** (`complex-search.sql`) | 4 | 98.50 ms · 81 rps | **1.34 ms · 5,982 rps** | **+7,285%** | **73.9×** | 100.0% | 4 |
| **`joins`** (`complex-joins.sql`) | 4 | 131.70 ms · 61 rps | **1.36 ms · 5,902 rps** | **+9,575%** | **96.8×** | 100.0% | 5 |
| **`analytics`** (`complex-analytics.sql`) | 4 | 95.76 ms · 84 rps | **1.31 ms · 6,118 rps** | **+7,183%** | **72.8×** | 100.0% | 4 |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 217.38 ms · 37 rps | **2.73 ms · 2,928 rps** | **+7,814%** | **79.1×** | 100.0% | 6 |

**Why Complex Queries Achieve 73×–97× Speedup (Two-Stage Caching & MV Admission Gate)**:
- In PgCache 0.7.1, query caching operates in two distinct tiers:
  1. **Table-Level Subsumption (`public.*`)**: Base tables (`orders`, `order_item`, `product`, `customer`, `review`, `seller`, `category`) are populated in PgCache's embedded PostgreSQL instance. If a query hits `public.*` directly (`pgcache_cache_mv_fallthrough`), PgCache still executes the SQL join/aggregation locally (~15–17 ms for 8 lightweight queries in `dash_base`).
  2. **Materialized View Admission Gate (`pgcache_mv.q_<hash>`)**: When a query has `OFFSET 0` (no positive `OFFSET`), groups on non-nullable entity keys (`mv=true`), and either scans `>= 1,000` pre-aggregation rows (`--mv_compute_min_rows=1000`) or achieves a `>= 10:1` row reduction ratio (`--mv_size_ratio=10`), PgCache admits the query into its Materialized View engine (`pgcache_cache_mv_gate{result="admitted"}`).
- Because all 8 queries in `complex-dashboard.sql` (and all 12 queries across `complex-search`, `complex-joins`, and `complex-analytics`) satisfy the MV gate, PgCache pre-materializes the 10-to-20 row result view in `pgcache_mv.q_<hash>` and serves subsequent queries in **~0.33 ms per statement** (`1.31–1.36 ms` for 4 statements; `2.73 ms` for 8 statements), compared to **95.8–217.4 ms** on Origin.

### 4.2 Complex Tenant Scaling (`1` to `1,000` Tenants on `complex-dashboard.sql`, `CLIENTS=8`)

Raw log: [`run-complex-tenants.txt`](run-complex-tenants.txt)

| Active Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Speedup | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|---:|
| **1** | 249.31 ms · 32 rps | **2.67 ms · 2,996 rps** | **+9,262%** | **93.6×** | 100.0% | 2 |
| **10** | 252.09 ms · 32 rps | **2.54 ms · 3,144 rps** | **+9,725%** | **98.3×** | 100.0% | 2 |
| **50** | 268.10 ms · 30 rps | **2.58 ms · 3,097 rps** | **+10,223%** | **103.2×** | 100.0% | 3 |
| **200** *(incremental)* | 274.31 ms · 29 rps | **56.03 ms · 143 rps** | **+393%** | **4.9×** | 97.9% | 6 |
| **200** *(settled)* | 217.38 ms · 37 rps | **2.73 ms · 2,928 rps** | **+7,814%** | **79.1×** | 100.0% | 6 |
| **500** *(cold 90s cap)* | 291.64 ms · 27 rps | 1,304.31 ms · 6 rps | -78% | 0.22× | 35.2% | 6 |
| **1,000** *(cold 90s cap)* | 294.97 ms · 27 rps | 1,131.32 ms · 7 rps | -74% | 0.26× | 17.5% | 6 |

**Finding — Cold-Start Registration Rate Limiting (`pgcache_cache_reg_gate_rate`) at 500–1,000 Tenants**:
- From **1 to 200 tenants**, PgCache warms the full working set of complex Materialized Views and delivers **+7,814% to +10,223% throughput gains** (`2,928–3,144 rps` vs `29–37 rps` on Origin). Even when 2.1% of queries are still finishing background MV construction (`97.9%` hit at 200 tenants), PgCache is **4.9× faster (`+393%`)** than Origin.
- At **500 and 1,000 tenants**, each tenant introduces ~32 distinct complex query signatures (`16,000` to `32,000` heavy 6-table Materialized Views). Telemetry inspection revealed that PgCache enforces an internal cold-start registration rate limiter (`pgcache_cache_reg_gate_rate`) that throttles new query registrations to **~8–20 queries/sec** so background `CREATE MATERIALIZED VIEW` workers do not overwhelm the origin or embedded PostgreSQL instance. Within a 6-pass (90s) warm-up window, roughly ~175 tenants (~35.2% of 500 tenants, ~17.5% of 1,000 tenants) are registered, while unregistered queries wait behind the registration gate.

### 4.3 Complex Concurrency Scaling (`1` to `32` Clients on `complex-dashboard.sql`, `TENANTS=200`)

Raw log: [`run-complex-clients.txt`](run-complex-clients.txt)

| Clients | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Speedup | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|---:|
| **1** | 86.03 ms · 12 rps | **1.90 ms · 528 rps** | **+4,300%** | **44.0×** | 100.0% | 3 |
| **4** | 140.95 ms · 28 rps | **2.38 ms · 1,679 rps** | **+5,896%** | **60.0×** | 100.0% | 2 |
| **8** | 286.37 ms · 28 rps | **2.84 ms · 2,814 rps** | **+9,950%** | **100.5×** | 100.0% | 2 |
| **16** | 525.68 ms · 30 rps | **4.94 ms · 3,239 rps** | **+10,697%** | **108.0×** | 100.0% | 2 |
| **32** | 983.51 ms · 33 rps | **9.82 ms · 3,260 rps** | **+9,779%** | **98.8×** | 100.0% | 2 |

- **Pure Single-Client Speedup (`CLIENTS=1`)**: With zero queueing anywhere, an 8-statement complex analytics & search screen drops from **86.03 ms (`12 rps`)** on Origin to **1.90 ms (`528 rps`)** on PgCache — a **44.0× (`+4,300%`)** pure caching speedup.
- **High Concurrency (`CLIENTS=16..32`)**: Origin saturates at **28–33 rps** with latency climbing to **983.5 ms** (~1 second per screen render), whereas PgCache sustains **3,239–3,260 rps** (~26,000 SQL queries/sec) at **4.94–9.82 ms** per screen (**98.8× to 108.0× speedup**).

### 4.4 Complex Write Invalidation & MV Rebuild Cost (`TENANTS=200`, `CLIENTS=8`)

Raw log: [`run-complex-writes.txt`](run-complex-writes.txt)

| Write Ratio | Write Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 200 | 292.04 ms · 27 rps | **2.89 ms · 2,771 rps** | **+10,163%** | 100.0% | 2 |
| **5%** | 1 | 283.13 ms · 28 rps | 901.73 ms · 9 rps | -68% | 65.8% | 2 |
| **5%** | 10 | 540.68 ms · 15 rps | 6,487.62 ms · 1 rps | -93% | 61.2% | 3 |
| **5%** | 200 | 279.00 ms · 29 rps | 1,380.21 ms · 6 rps | -79% | 34.4% | 6 |
| **10%** | 1 | 1,010.47 ms · 8 rps | **600.83 ms · 13 rps** | **+62%** | 62.1% | 3 |
| **10%** | 200 | 244.39 ms · 33 rps | 822.49 ms · 10 rps | -70% | 27.2% | 3 |

**Why Write Invalidation Behaves Differently on Complex 6-Table MVs vs. Simple Lookups**:
- On the baseline operational workload (`dashboard.sql`, Section 3.3), queries execute against base tables in `public.*` with light single/two-table lookups. When `write.sql` executes `UPDATE orders SET total = total + 1`, PgCache applies the row update via logical replication / CDC and maintains a **100.0% hit ratio** with **+40% to +110% throughput gain**.
- On `complex-dashboard.sql`, **7 of the 8 statements join `orders` across 4 to 6 tables** (`orders`, `order_item`, `product`, `category`, `seller`, `customer`, `review`) and rely on pre-computed Materialized Views (`pgcache_mv.q_<hash>`) for their 100× speedup.
- When `UPDATE orders` is sent through PgCache at 5%–10% transaction share, PgCache invalidates (`pgcache_cache_invalidations`) the Materialized Views that depend on `orders` and triggers background **6-table Materialized View rebuilds (`pgcache_cache_mv_rebuilds`)** inside its embedded PostgreSQL instance. Because each 6-table MV rebuild scans and joins thousands of rows (~50–100 ms of CPU work per MV rebuild), continuous writes to the central `orders` table saturate the embedded PostgreSQL workers with MV maintenance, reducing the effective hit ratio to `27.2%–65.8%`.
- Only when writes are concentrated on a single hot tenant (`10:1`) while Origin is itself heavily contended (`1,010.5 ms` / `8 rps`) does PgCache remain ahead (**`+62%`**, `600.8 ms` / `13 rps`) by serving the other 199 read-only tenants from cache.

---

## 5. Raw Artifacts

- Baseline machine-readable TSV: [`results.tsv`](results.tsv) / [`results-docker.tsv`](results-docker.tsv)
- Complex scenarios machine-readable TSV: [`results-complex.tsv`](results-complex.tsv)
- Differential correctness, cacheability & MV gate log: [`verify-correctness.txt`](verify-correctness.txt)
- Baseline Sweep 1 (Tenants) raw log: [`run-tenants.txt`](run-tenants.txt)
- Baseline Sweep 2 (Concurrency) raw log: [`run-clients.txt`](run-clients.txt)
- Baseline Sweep 3 (Writes) raw log: [`run-writes.txt`](run-writes.txt)
- Complex Sweep 4.1 (Scenario comparison) raw log: [`run-complex-scenarios.txt`](run-complex-scenarios.txt)
- Complex Sweep 4.2 (Tenant scaling) raw log: [`run-complex-tenants.txt`](run-complex-tenants.txt)
- Complex Sweep 4.3 (Concurrency scaling) raw log: [`run-complex-clients.txt`](run-complex-clients.txt)
- Complex Sweep 4.4 (Write invalidation) raw log: [`run-complex-writes.txt`](run-complex-writes.txt)
