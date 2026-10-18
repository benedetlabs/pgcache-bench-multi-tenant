# PgCache Benchmark Verification — Tag 0.7.1 (Baseline & Complex Multi-Tenant Scenarios)

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.7.1** (`pgcache/pgcache:0.7.1-arm64` / `pgcache/pgcache:0.7.1`) covering two benchmark suites:
1. **Baseline Operational Dashboard (`workload/dashboard.sql`)**: Full regression verification across 1 to 1,000 tenants, 1 to 32 concurrent clients, and 0%–10% mixed write workloads (`scripts/01`–`03`).
2. **Complex Multi-Tenant SaaS Workloads (`scripts/04-complex-sweep.sh`)**: Substring text search (`ILIKE '%...%'`), deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (including zero-order customer cohorts and unreviewed product inventory), multi-dimensional analytical aggregations (`GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`), and a unified 8-statement enterprise analytics & search screen (`workload/complex-dashboard.sql`), verified by a strict **Differential Correctness, Cacheability, and MV Admission Gate** (`scripts/verify-correctness.sh`).

---

## 1. Executive Summary

- **Differential Correctness, Cacheability & MV Hit Gate (`verify-correctness.txt`)**:
  - All **12/12 distinct complex multi-tenant SQL queries** across `complex-search.sql` (4), `complex-joins.sql` (4), and `complex-analytics.sql` (4) (covering 100% of `complex-dashboard.sql`) produced byte-for-byte identical result sets between Origin PostgreSQL 17 and PgCache 0.7.1 across all three passes: cold miss/populate (Pass 1), base-table hit + MV build (Pass 2), and warm Materialized View hit (Pass 3).
  - **100% Cacheability**: `pgcache_queries_cacheable` delta = `36/36`, `pgcache_queries_uncacheable` delta = **`0`**, `pgcache_queries_cache_error` delta = **`0`**.
  - **100% Materialized View (MV) Gate Admission & Hit Verification**: `pgcache_cache_mv_gate{outcome="admit"}` = **`12/12`** (`outcome="reject"` = `0`), and `pgcache_cache_mv_hits` delta = **`12/12`** on Pass 3.
- **Baseline Dashboard (`workload/dashboard.sql`)**:
  - **Hit Ratio**: **100.0%** from 1 to 500 tenants and **99.9%** at 1,000 tenants.
  - **Throughput Gain**: **+116% to +139%** across tenant scaling (`450–514 rps` vs `196–222 rps` on Origin), **+93% to +138%** across concurrency scaling (`1..32` clients), and **+40% to +110%** under 5%–10% write ratios.
- **Complex Multi-Tenant Workloads (`workload/complex-*.sql`)**:
  - **Read-Heavy Speedup**: Once admitted into PgCache's Materialized View engine (`pgcache_mv.q_<hash>`), expensive 4-to-6 table `JOIN`/`LEFT JOIN`/`GROUP BY`/`ILIKE` queries drop from **88.7–209.6 ms** on Origin to **1.25–2.86 ms** on PgCache (~0.31–0.38 ms per statement), delivering **58.0× to 97.4× higher throughput (`+5,703%` to `+9,636%`)** at 8 clients and up to **94.0× (`+9,300%`, `3,478 rps` vs `37 rps`)** under 32 concurrent clients.
  - **Mixed Write Resilience (`INNER JOIN` In-Place CDC vs. `LEFT JOIN` Outer Invalidation)**: By scoping every joined tenant table with an explicit `:t` literal (`AND o.tenant_id = :t`, `AND oi.tenant_id = :t`, `AND c.tenant_id = :t`), the **5 `INNER JOIN` queries (`62.5%`)** in `complex-dashboard.sql` remain **100% cache hits** under `UPDATE orders` writes (updated in-place via CDC + background MV rebuild), while the **3 `LEFT JOIN` queries (`37.5%`)** (where `o.tenant_id = :t` resides in the outer-join `ON` clause) undergo conservative invalidation. Consequently, `complex-dashboard.sql` sustains a **62.5%–67.6% hit ratio** and **+8% to +30% throughput gain** across 5%–10% write workloads (`5:1`, `5:10`, `10:1`, `10:200`) with zero cache errors.

---

## 2. Differential Correctness, Cacheability & MV Admission Gate

Executed via [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) (raw log: [`verify-correctness.txt`](verify-correctness.txt)):

| Check | Result | Telemetry / Detail |
|---|---|---|
| **Byte-for-Byte Output Equality** | **PASS (12/12 queries)** | `psql -tAF '|'` output identical between Origin and PgCache across Pass 1 (miss), Pass 2 (base-table hit + MV build), and Pass 3 (warm MV hit) |
| **Cacheable Queries Delta** | **PASS (`36 / 36`)** | `pgcache_queries_cacheable` incremented by 36 across 3 passes of 12 statements |
| **Uncacheable Queries Delta** | **PASS (`0`)** | `pgcache_queries_uncacheable` delta = `0` |
| **MV Gate Admission** | **PASS (`12 / 12`)** | `pgcache_cache_mv_gate{outcome="admit"}` = `12`, `pgcache_cache_mv_gate{outcome="reject"}` = `0` |
| **Materialized View Hits** | **PASS (`12 / 12`)** | `pgcache_cache_mv_hits` delta = `12` (100% of Pass 3 queries served directly from MVs) |
| **Cache Errors Delta** | **PASS (`0`)** | `pgcache_queries_cache_error` delta = `0` |

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
1. **[`complex-search.sql`](../../workload/complex-search.sql)** (4 statements): Substring `ILIKE '%...%'` text searches across customer emails/names, product names, seller names, and review bodies combined with 2-to-6 table `INNER JOIN` and `LEFT JOIN` chains.
2. **[`complex-joins.sql`](../../workload/complex-joins.sql)** (4 statements): Deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (`orders -> customer -> order_item -> product -> category -> seller -> review`), including customer cohort retention (`LEFT JOIN orders`) and unreviewed product inventory (`LEFT JOIN review`).
3. **[`complex-analytics.sql`](../../workload/complex-analytics.sql)** (4 statements): Multi-dimensional `GROUP BY` rollups with conditional `FILTER (WHERE ...)`, `CASE WHEN` fulfillment & price-tier buckets, and `HAVING` thresholds.
4. **[`complex-dashboard.sql`](../../workload/complex-dashboard.sql)** (8 statements): Unified enterprise analytics & search screen combining 2 search queries, 3 deep multi-table `JOIN` / `LEFT JOIN` queries, and 3 heavy analytical rollups.

### 4.1 Scenario Comparison (`TENANTS=200`, `CLIENTS=8`)

Raw log: [`run-complex-scenarios.txt`](run-complex-scenarios.txt)

| Scenario | Statements | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Speedup | Hit Ratio | Warm Passes |
|---|---:|---|---|---:|---:|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 37.61 ms · 213 rps | **16.05 ms · 498 rps** | **+134%** | **2.3×** | 100.0% | 3 |
| **`search`** (`complex-search.sql`) | 4 | 88.67 ms · 90 rps | **1.53 ms · 5,223 rps** | **+5,703%** | **58.0×** | 100.0% | 4 |
| **`joins`** (`complex-joins.sql`) | 4 | 121.46 ms · 66 rps | **1.25 ms · 6,426 rps** | **+9,636%** | **97.4×** | 100.0% | 5 |
| **`analytics`** (`complex-analytics.sql`) | 4 | 92.31 ms · 87 rps | **1.39 ms · 5,737 rps** | **+6,494%** | **65.9×** | 100.0% | 5 |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 209.62 ms · 38 rps | **2.86 ms · 2,798 rps** | **+7,263%** | **73.6×** | 100.0% | 6 |

**Why Complex Queries Achieve 58×–97× Speedup (Two-Stage Caching & MV Admission Gate)**:
- In PgCache 0.7.1, query caching operates in two distinct tiers:
  1. **Table-Level Subsumption (`public.*`)**: Base tables (`orders`, `order_item`, `product`, `customer`, `review`, `seller`, `category`) are populated in PgCache's embedded PostgreSQL instance. If a query hits `public.*` directly (`pgcache_cache_mv_fallthrough`), PgCache still executes the SQL join/aggregation locally (~16 ms for 8 lightweight queries in `dash_base`).
  2. **Materialized View Admission Gate (`pgcache_mv.q_<hash>`)**: When a query has `OFFSET 0` (no positive `OFFSET`), groups on non-nullable entity keys (`mv=true`), and either scans `>= 1,000` pre-aggregation rows (`--mv_compute_min_rows=1000`) or achieves a `>= 10:1` row reduction ratio (`--mv_size_ratio=10`), PgCache admits the query into its Materialized View engine (`pgcache_cache_mv_gate{outcome="admit"}`).
- Because all 8 queries in `complex-dashboard.sql` (and all 12 queries across `complex-search`, `complex-joins`, and `complex-analytics`) satisfy the MV gate, PgCache pre-materializes the 10-to-20 row result view in `pgcache_mv.q_<hash>` and serves subsequent queries via `pgcache_cache_mv_hits` in **~0.31–0.38 ms per statement** (`1.25–1.53 ms` for 4 statements; `2.86 ms` for 8 statements), compared to **88.7–209.6 ms** on Origin.

### 4.2 Complex Tenant Scaling (`1` to `1,000` Tenants on `complex-dashboard.sql`, `CLIENTS=8`)

Raw log: [`run-complex-tenants.txt`](run-complex-tenants.txt)

| Active Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Speedup | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|---:|
| **1** | 208.31 ms · 38 rps | **2.28 ms · 3,511 rps** | **+9,139%** | **92.4×** | 100.0% | 2 |
| **10** | 168.59 ms · 47 rps | **2.24 ms · 3,579 rps** | **+7,515%** | **76.1×** | 100.0% | 2 |
| **50** | 184.07 ms · 43 rps | **2.27 ms · 3,532 rps** | **+8,114%** | **82.1×** | 100.0% | 3 |
| **200** | 206.95 ms · 39 rps | **2.90 ms · 2,763 rps** | **+6,985%** | **70.8×** | 100.0% | 8 |
| **500** | 212.27 ms · 38 rps | **67.55 ms · 118 rps** | **+211%** | **3.1×** | 97.4% | 8 |
| **1,000** *(cold 8-pass cap)* | 226.02 ms · 35 rps | 517.86 ms · 15 rps | -57% | 0.43× | 62.7% | 5 |

**Finding — Tenant Working-Set Scaling & Cold-Start Registration Rate at 500–1,000 Tenants**:
- From **1 to 200 tenants** (`8` to `1,600` distinct 4–6 table Materialized Views), PgCache warms 100.0% of the working set and delivers **+6,985% to +9,139% throughput gains (`70.8× to 92.4×` speedup, `2,763–3,579 rps` vs `38–47 rps` on Origin)**.
- At **500 tenants** (`4,000` distinct complex queries), PgCache reaches a **97.4% hit ratio** within 8 warm-up passes and outperforms Origin by **+211% (`3.1×` speedup, `118 rps` vs `38 rps`, `67.55 ms` vs `212.27 ms`)**.
- At **1,000 tenants** (`8,000` distinct complex queries), uniform random sampling across 1,000 tenants (`\set t random(1, 1000)`) combined with per-tenant cold population cost (~100–250 ms per cold tenant `SELECT DISTINCT` + MV build) warms **62.7%** of queries within the bounded 15s pass window, leaving 37.3% cold misses in flight during the measured pass.

### 4.3 Complex Concurrency Scaling (`1` to `32` Clients on `complex-dashboard.sql`, `TENANTS=200`)

Raw log: [`run-complex-clients.txt`](run-complex-clients.txt)

| Clients | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Speedup | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|---:|
| **1** | 84.83 ms · 12 rps | **1.73 ms · 578 rps** | **+4,717%** | **48.2×** | 100.0% | 2 |
| **4** | 92.22 ms · 43 rps | **2.26 ms · 1,770 rps** | **+4,016%** | **41.2×** | 100.0% | 2 |
| **8** | 194.69 ms · 41 rps | **2.66 ms · 3,003 rps** | **+7,224%** | **73.2×** | 100.0% | 2 |
| **16** | 400.89 ms · 40 rps | **4.60 ms · 3,475 rps** | **+8,588%** | **86.9×** | 100.0% | 2 |
| **32** | 862.44 ms · 37 rps | **9.20 ms · 3,478 rps** | **+9,300%** | **94.0×** | 100.0% | 2 |

- **Pure Single-Client Speedup (`CLIENTS=1`)**: With zero queueing anywhere, an 8-statement complex analytics & search screen drops from **84.83 ms (`12 rps`)** on Origin to **1.73 ms (`578 rps`)** on PgCache — a **48.2× (`+4,717%`)** pure caching speedup.
- **High Concurrency (`CLIENTS=16..32`)**: Origin saturates at **37–40 rps** with latency climbing to **862.44 ms** (~0.86 seconds per screen render), whereas PgCache sustains **3,475–3,478 rps** (~27,800 SQL queries/sec) at **4.60–9.20 ms** per screen (**86.9× to 94.0× speedup**).

### 4.4 Complex Write Invalidation & `INNER JOIN` vs `LEFT JOIN` CDC Behavior (`TENANTS=200`, `CLIENTS=8`)

Raw log: [`run-complex-writes.txt`](run-complex-writes.txt)

| Write Ratio | Write Tenants | Origin (Path A) | PgCache 0.7.1 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 200 | 196.12 ms · 41 rps | **2.62 ms · 3,059 rps** | **+7,361%** | 100.0% | 2 |
| **5%** | 1 | 191.28 ms · 42 rps | **166.86 ms · 48 rps** | **+14%** | 67.6% | 2 |
| **5%** | 10 | 216.04 ms · 37 rps | **167.12 ms · 48 rps** | **+30%** | 63.3% | 2 |
| **5%** | 200 | 210.42 ms · 38 rps | 220.45 ms · 36 rps | -5% | 64.0% | 3 |
| **10%** | 1 | 206.33 ms · 39 rps | **163.51 ms · 49 rps** | **+26%** | 63.1% | 2 |
| **10%** | 200 | 213.03 ms · 38 rps | **195.50 ms · 41 rps** | **+8%** | 62.5% | 3 |

**Why Hit Ratio Settles at ~62.5% (`5/8`) Under `UPDATE orders` Writes (`INNER JOIN` vs. `LEFT JOIN`)**:
- In `complex-dashboard.sql`, all 8 statements reference `orders`:
  1. **5 `INNER JOIN` Statements (`#1`, `#2`, `#4`, `#6`, `#8` = `62.5%` of queries)**: Because these queries include explicit `WHERE ... AND o.tenant_id = :t` equality predicates, PgCache scopes their `orders` table dependency to tenant `:t`, applies non-key `UPDATE orders SET total = total + 1` events in-place via logical replication (`cdc_update`), and rebuilds only the affected tenant's Materialized Views (`pgcache_cache_mv_rebuilds`, median `48 ms`). These 5 statements achieve a **100% cache hit rate** across read-only tenants and in-place hits on updated tenants.
  2. **3 `LEFT JOIN` Statements (`#3`, `#5`, `#7` = `37.5%` of queries)**: These queries use `FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = :t` to preserve customers with zero orders (`o.id IS NULL`). Because `o.tenant_id = :t` is an outer-join `ON` condition rather than a top-level `WHERE` filter, PgCache conservatively invalidates registered outer-join queries referencing `orders` whenever `orders` receives a write.
- As a result, exactly **5 out of 8 statements (`62.5%`)** remain warm cache hits (`62.5%–67.6%` observed hit ratio) while the 3 outer-join statements re-populate, enabling PgCache to maintain **+8% to +30% higher throughput** (`41–49 rps` vs `37–42 rps` on Origin) at 5%–10% write rates (`5:1`, `5:10`, `10:1`, `10:200`) and parity (`-5%`, `36 rps` vs `38 rps`) at `5:200`, with **`pgcache_queries_cache_error == 0`**.

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
