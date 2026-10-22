# Benchmarking PgCache 0.7.1 in a Multi-Tenant SaaS: What Actually Happens on a 3-Node Cloud Cluster

> 🇧🇷 **[Ler em português](README-pt.md)** · 🚀 **[Read Part 2 (`results/0.7.1_v2/`): The "Fair Benchmark" (`2 GiB` Prewarmed Origin + `GIN pg_trgm`), Dynamic User Filters, & `ADMISSION_THRESHOLD` (`1` vs `2` vs `4`) Study](../0.7.1_v2/README.md)**

Does putting a read-cache proxy in front of PostgreSQL actually make a multi-tenant SaaS faster — and where does it hit its limits?

This article presents the results of testing **PgCache 0.7.1** (`pgcache/pgcache:0.7.1`) in front of **PostgreSQL 17**. Every test is designed to run on a **3-node Kubernetes cluster in any cloud provider** (AWS EKS, Azure AKS, Google GKE, or DigitalOcean DOKS), placing the database, the cache proxy, and the load generator on **three separate virtual machines** so that every query pays real network latency and has isolated CPU and RAM. For this campaign, we ran the cluster on DigitalOcean (`3× s-4vcpu-8gb` in a single availability zone).

---

## 1. What We Are Testing: The Database & SQL Workloads

> 📖 **Full SQL & Data Modeling Guide**: For the Entity-Relationship diagram, index catalog, and the exact SQL code of every query, read **[`workload/README.md`](../../workload/README.md)**.

We model a multi-tenant B2B/B2C e-commerce SaaS database created by [`sql/01-schema.sql`](../../sql/01-schema.sql) and [`sql/02-tenant.sql`](../../sql/02-tenant.sql), containing **7 relational tables** (`customer`, `orders`, `order_item`, `product`, `category`, `seller`, and `review`) populated with **500,000 orders, 2,000,000 order line items, 300,000 reviews, 200,000 products, and 100,000 customers** distributed across up to **2,000 tenant organizations**.

Instead of firing single isolated queries, each `pgbench` transaction simulates a user loading a **complete SaaS screen** made of **4 to 8 sequential SQL queries**:

| SQL Workload File | Queries per Screen | What the Screen Simulates |
|---|:---:|---|
| **[`workload/dashboard.sql`](../../workload/dashboard.sql)** | **8** | **Lightweight Operational Dashboard**: Fast indexed KPI counts (`GROUP BY status`), total revenue, customer count, recent orders pagination, and 2-table `INNER JOIN` lists. |
| **[`workload/complex-search.sql`](../../workload/complex-search.sql)** | **4** | **Substring Text Search (`ILIKE '%...%'`)**: Case-insensitive wildcard searches across customer names/emails, product names, seller names, and review text joined across 3 to 6 tables. |
| **[`workload/complex-joins.sql`](../../workload/complex-joins.sql)** | **4** | **Deep 4-to-6 Table `JOIN` & `LEFT JOIN` Chains**: Multi-hop joins (`orders → customer → order_item → product → category → seller → review`), including outer joins that preserve customers with zero orders and products with zero reviews. |
| **[`workload/complex-analytics.sql`](../../workload/complex-analytics.sql)** | **4** | **Multi-Dimensional Analytics**: OLAP-style `GROUP BY` rollups using `FILTER (WHERE ...)`, `CASE WHEN` price-tier buckets, and `HAVING` thresholds across 4 to 6 tables. |
| **[`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql)** | **8** | **Full Enterprise Screen (Uniform Traffic)**: Combines 3 analytical rollups, 3 deep multi-table joins, and 2 `ILIKE` text searches into one heavy 8-query screen, picking tenants uniformly (`1..N`). |
| **[`workload/complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)** | **8** | **Full Enterprise Screen (Pareto 80/20 Traffic)**: The exact same 8 heavy queries, but using a realistic **Zipfian (`s = 1.07`)** distribution where ~20% of tenants generate ~80% of requests. |
| **[`workload/write.sql`](../../workload/write.sql)** | **2** | **Live Transactional Writes (`UPDATE` + `INSERT`)**: Updates an existing order (`UPDATE orders`) and inserts a new line item (`INSERT INTO order_item`) to trigger Change Data Capture (CDC) replication in PgCache. |

### The Two Paths Compared
- **Path A (PostgreSQL Direct)**: The load generator connects straight to the PostgreSQL 17 VM.
- **Path B (PgCache 0.7.1)**: The load generator connects to the PgCache VM, which serves cached queries from memory and subscribes to PostgreSQL's logical replication stream (CDC) to keep results coherent.

---

## 2. Executive Summary (TL;DR)

1. **100% Identical Answers (`verify-correctness.sh`)**: Before measuring speed, we verified that all **8 baseline queries** and all **12 complex queries** return byte-for-byte identical rows on PostgreSQL and PgCache — both on static reads and immediately after live `UPDATE` and `INSERT` mutations.
2. **Simple Queries vs. Heavy Queries (1.98× vs. 29.4× Faster)**:
   - On the **lightweight dashboard** ([`dashboard.sql`](../../workload/dashboard.sql)), PostgreSQL already answers all 8 indexed queries in **57.8 ms**, so PgCache nearly **doubles throughput (+98%, from 146 to 273 screens/s)**.
   - On **heavy multi-table screens** ([`complex-search.sql`](../../workload/complex-search.sql), [`complex-joins.sql`](../../workload/complex-joins.sql), [`complex-analytics.sql`](../../workload/complex-analytics.sql)), PostgreSQL takes **130 to 308 ms** scanning and joining tables. PgCache pre-computes those views in memory and answers the entire screen in **6.9 to 23.4 ms** — delivering **15× to 29.4× more throughput (+1,400% to +2,839%)**.
3. **Why Real-World 80/20 Traffic Matters at 2,000 Tenants**:
   - When 2,000 tenants follow a realistic **Pareto 80/20 distribution** ([`complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)), the active tenant cohort warms quickly (**64.1% hit rate**) and PgCache stays ahead of PostgreSQL even from a cold start.
4. **Where the Cache Struggles (Cold Start Under Heavy Writes)**:
   - When warmed first, PgCache handles 5%–10% write traffic cleanly (**63%–75% hit rate**).
   - However, if you restart the cache **completely cold** while simultaneously bombarding the database with both `UPDATE orders` and `INSERT INTO order_item` ([`write.sql`](../../workload/write.sql)), replication invalidations fight against initial cache population and throughput drops below PostgreSQL (**-85%**). Always warm your read working set before cutting over heavy mixed read/write traffic.
5. **Follow-Up in Part 2 ([`results/0.7.1_v2/`](../0.7.1_v2/README.md))**:
   - See **[Part 2 (`0.7.1_v2`)](../0.7.1_v2/README.md)** for our follow-up study with a **2 GiB prewarmed + `GIN pg_trgm` tuned PostgreSQL Origin**, **3+ char trigram text search (`search_3c`)**, **dynamic intra-tenant user filters (`cplx_dyn`)**, and an empirical sweep of **`ADMISSION_THRESHOLD = 1` vs `2` vs `4`** based on feedback from James (PgCache core developer).

---

## 3. Multi-Trial Benchmark: Consolidated Table & All 5 Individual Runs (`TRIALS=5`)

In cloud environments, a single benchmark run can be skewed by a lucky warm-up or a background network hiccup. To eliminate single-run anomalies, we executed every scenario **5 independent times (`TRIALS=5`, `DURATION=15s`, `CLIENTS=8`)**.

Before **every single trial**, our automation (`reset_all_pods` in [`scripts/lib.sh`](../../scripts/lib.sh)) cleaned up any inserted rows and **recreated the PostgreSQL pod, the PgCache pod, and the loadgen pod from scratch**, warming the cache dynamically (`warm_until_settled`) before measuring Path B.

Raw logs: [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt) · [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt) · [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)

### 3.1 Consolidated 5-Run Summary

| Scenario & SQL Workload (`CLIENTS=8`) | PostgreSQL Direct (Path A Mean) | PgCache 0.7.1 (Path B Mean) | Hit Rate | Mean Speedup (5-Run Min/Max Spread) |
|---|---|---|---:|---|
| **1. Lightweight Dashboard** ([`dashboard.sql`](../../workload/dashboard.sql), 200 tenants) | 57.8 ms · **146 req/s** *(±40.5 sd)* | **29.4 ms · 273 req/s** *(±16.3 sd)* | **100.0%** | **1.98× (+98%)** *(-68% / +69%)* |
| **2. Substring Text Search** ([`complex-search.sql`](../../workload/complex-search.sql), 200 tenants) | 129.6 ms · **63 req/s** *(±9.2 sd)* | **6.9 ms · 1,170 req/s** *(±126.1 sd)* | **100.0%** | **18.8× (+1,778%)** *(-266% / +243%)* |
| **3. Deep 4-to-6 Table Joins** ([`complex-joins.sql`](../../workload/complex-joins.sql), 200 tenants) | 238.9 ms · **34 req/s** *(±2.8 sd)* | **8.2 ms · 991 req/s** *(±160.6 sd)* | **100.0%** | **29.4× (+2,839%)** *(-666% / +443%)* |
| **4. Multi-Dimensional Analytics** ([`complex-analytics.sql`](../../workload/complex-analytics.sql), 200 tenants) | 175.3 ms · **46 req/s** *(±4.1 sd)* | **9.0 ms · 905 req/s** *(±122.1 sd)* | **100.0%** | **19.8× (+1,883%)** *(-395% / +267%)* |
| **5. Full Enterprise Screen — Uniform** ([`complex-dashboard.sql`](../../workload/complex-dashboard.sql), 200 tenants) | 307.5 ms · **26 req/s** *(±1.2 sd)* | **23.4 ms · 389 req/s** *(±132.6 sd)* | **100.0%** | **15.0× (+1,400%)** *(-766% / +684%)* |
| **6. Full Enterprise Screen — Pareto 80/20** ([`complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql), 200 tenants) | 339.2 ms · **24 req/s** *(±4.1 sd)* | **76.0 ms · 267 req/s** *(±191.3 sd)* | **97.5%** | **11.5× (+1,051%)** *(-1,016% / +917%)* |
| **7. Full Enterprise Screen — Pareto 80/20** ([`complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql), 2,000 tenants) | 373.1 ms · **22 req/s** *(±1.9 sd)* | **351.2 ms · 24 req/s** *(±5.4 sd)* | **64.1%** | **1.09× (+9%)** *(-26% / +30%)* |
| **8. Cold-Start + 5% Writes (`UPDATE`+`INSERT`)** ([`complex-dashboard.sql`](../../workload/complex-dashboard.sql) + [`write.sql`](../../workload/write.sql)) | 327.9 ms · **25 req/s** *(±2.7 sd)* | 2,995.5 ms · **3 req/s** *(±2.6 sd)* | **32.4%** | **0.15× (-85%)** *(-8% / +23%)* |

---

### 3.2 Run-by-Run Breakdown: All 5 Executions per Scenario

Below are the exact measurements recorded in each of the 5 pod-recreated trials (`Trial 1` through `Trial 5`).

#### Scenario 1: Lightweight Operational Dashboard — [`workload/dashboard.sql`](../../workload/dashboard.sql) (8 queries, 200 tenants)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 38.91 ms | 206 req/s | 29.94 ms | 267 req/s | 100.00% | **+29.6% (1.30×)** | 6 |
| **Trial 2** | 72.54 ms | 110 req/s | 27.18 ms | 294 req/s | 100.00% | **+167.3% (2.67×)** | 5 |
| **Trial 3** | 69.15 ms | 116 req/s | 29.14 ms | 275 req/s | 99.99% | **+137.1% (2.37×)** | 5 |
| **Trial 4** | 47.41 ms | 169 req/s | 28.58 ms | 280 req/s | 100.00% | **+65.7% (1.66×)** | 6 |
| **Trial 5** | 61.18 ms | 131 req/s | 31.98 ms | 250 req/s | 99.99% | **+90.8% (1.91×)** | 5 |
| **Average (5 Runs)** | **57.84 ms** | **146 req/s** *(±40.5 sd, -36/+60)* | **29.36 ms** | **273 req/s** *(±16.3 sd, -23/+21)* | **100.0%** | **+98% (1.98×)** | **5.4** |

> **What we see across the 5 runs**: Notice how PostgreSQL Direct (Path A) fluctuates between `110 req/s` and `206 req/s` (`±40.5 sd`) right after a pod restart as its buffer pool and I/O warm up, whereas PgCache (Path B) is rock-solid across all 5 runs (`250 to 294 req/s`, `±16.3 sd`).

---

#### Scenario 2: Substring Text Search (`ILIKE '%...%'`) — [`workload/complex-search.sql`](../../workload/complex-search.sql) (4 queries, 200 tenants)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 107.94 ms | 74 req/s | 6.61 ms | 1,210 req/s | 100.00% | **+1,535.1% (16.4×)** | 5 |
| **Trial 2** | 120.00 ms | 67 req/s | 6.03 ms | 1,327 req/s | 100.00% | **+1,880.6% (19.8×)** | 5 |
| **Trial 3** | 161.05 ms | 50 req/s | 7.84 ms | 1,020 req/s | 100.00% | **+1,940.0% (20.4×)** | 6 |
| **Trial 4** | 121.72 ms | 66 req/s | 7.52 ms | 1,064 req/s | 100.00% | **+1,512.1% (16.1×)** | 5 |
| **Trial 5** | 137.43 ms | 58 req/s | 6.50 ms | 1,230 req/s | 100.00% | **+2,020.7% (21.2×)** | 5 |
| **Average (5 Runs)** | **129.63 ms** | **63 req/s** *(±9.2 sd, -13/+11)* | **6.90 ms** | **1,170 req/s** *(±126.1 sd, -150/+157)* | **100.0%** | **+1,778% (18.8×)** | **5.2** |

---

#### Scenario 3: Deep 4-to-6 Table `JOIN` & `LEFT JOIN` Chains — [`workload/complex-joins.sql`](../../workload/complex-joins.sql) (4 queries, 200 tenants)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 214.54 ms | 37 req/s | 9.51 ms | 841 req/s | 100.00% | **+2,173.0% (22.7×)** | 6 |
| **Trial 2** | 242.98 ms | 33 req/s | 7.17 ms | 1,116 req/s | 100.00% | **+3,281.8% (33.8×)** | 7 |
| **Trial 3** | 268.60 ms | 30 req/s | 9.74 ms | 821 req/s | 100.00% | **+2,636.7% (27.4×)** | 7 |
| **Trial 4** | 245.73 ms | 33 req/s | 8.02 ms | 997 req/s | 100.00% | **+2,921.2% (30.2×)** | 6 |
| **Trial 5** | 222.48 ms | 36 req/s | 6.78 ms | 1,181 req/s | 100.00% | **+3,180.6% (32.8×)** | 6 |
| **Average (5 Runs)** | **238.86 ms** | **34 req/s** *(±2.8 sd, -4/+3)* | **8.24 ms** | **991 req/s** *(±160.6 sd, -170/+190)* | **100.0%** | **+2,839% (29.4×)** | **6.4** |

---

#### Scenario 4: Multi-Dimensional Analytics (`GROUP BY / FILTER / HAVING`) — [`workload/complex-analytics.sql`](../../workload/complex-analytics.sql) (4 queries, 200 tenants)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 172.20 ms | 46 req/s | 7.73 ms | 1,035 req/s | 100.00% | **+2,150.0% (22.5×)** | 7 |
| **Trial 2** | 175.57 ms | 46 req/s | 7.84 ms | 1,020 req/s | 100.00% | **+2,117.4% (22.2×)** | 6 |
| **Trial 3** | 159.02 ms | 50 req/s | 10.07 ms | 794 req/s | 100.00% | **+1,488.0% (15.9×)** | 8 |
| **Trial 4** | 203.17 ms | 39 req/s | 10.33 ms | 774 req/s | 100.00% | **+1,884.6% (19.8×)** | 6 |
| **Trial 5** | 166.40 ms | 48 req/s | 8.89 ms | 900 req/s | 100.00% | **+1,775.0% (18.8×)** | 7 |
| **Average (5 Runs)** | **175.27 ms** | **46 req/s** *(±4.1 sd, -7/+4)* | **8.97 ms** | **905 req/s** *(±122.1 sd, -131/+130)* | **100.0%** | **+1,883% (19.8×)** | **6.8** |

---

#### Scenario 5: Full Enterprise Screen (Uniform Tenant Selection) — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (8 queries, 200 tenants)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 319.77 ms | 25 req/s | 20.59 ms | 389 req/s | 100.00% | **+1,456.0% (15.6×)** | 8 |
| **Trial 2** | 316.40 ms | 25 req/s | 14.66 ms | 546 req/s | 100.00% | **+2,084.0% (21.8×)** | 7 |
| **Trial 3** | 303.35 ms | 26 req/s | 41.86 ms | 191 req/s | 99.96% | **+634.6% (7.3×)** | 8 |
| **Trial 4** | 284.58 ms | 28 req/s | 17.26 ms | 463 req/s | 100.00% | **+1,553.6% (16.5×)** | 8 |
| **Trial 5** | 313.51 ms | 26 req/s | 22.39 ms | 357 req/s | 100.00% | **+1,273.1% (13.7×)** | 8 |
| **Average (5 Runs)** | **307.52 ms** | **26 req/s** *(±1.2 sd, -1/+2)* | **23.35 ms** | **389 req/s** *(±132.6 sd, -198/+157)* | **100.0%** | **+1,400% (15.0×)** | **7.8** |

> **Why Trial 3 is so informative**: In Trial 3, the cache hit rate was `99.96%` instead of `100.00%`. Because a single cold miss on a 6-table query takes ~40 ms to populate on the fly, that tiny `0.04%` miss rate pulled Trial 3's average latency to `41.86 ms (191 req/s)` versus `14.66–22.39 ms (357–546 req/s)` on the other 4 runs. Showing all 5 runs lets you see both the typical speed (~400–546 req/s) and the sensitivity to even a fraction of a percent of cache misses.

---

#### Scenario 6: Full Enterprise Screen with Pareto 80/20 Traffic (`200` Tenants) — [`workload/complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 266.60 ms | 30 req/s | 48.32 ms | 166 req/s | 99.28% | **+453.3% (5.5×)** | 8 |
| **Trial 2** | 313.86 ms | 25 req/s | 16.95 ms | 472 req/s | 100.00% | **+1,788.0% (18.9×)** | 8 |
| **Trial 3** | 412.61 ms | 19 req/s | 37.92 ms | 211 req/s | 99.73% | **+1,010.5% (11.1×)** | 8 |
| **Trial 4** | 347.18 ms | 23 req/s | 259.23 ms | 31 req/s | 88.27% | **+34.8% (1.3×)** | 5 |
| **Trial 5** | 355.99 ms | 22 req/s | 17.59 ms | 455 req/s | 100.00% | **+1,968.2% (20.7×)** | 8 |
| **Average (5 Runs)** | **339.25 ms** | **24 req/s** *(±4.1 sd, -5/+6)* | **76.00 ms** | **267 req/s** *(±191.3 sd, -236/+205)* | **97.5%** | **+1,051% (11.5×)** | **7.4** |

> **Why Trial 4 stopped warming at Pass 5**: Because Zipfian traffic repeatedly hits the hot 20% of tenants, two consecutive warm-up passes can show `< 1%` hit-rate change around `88%`, causing `warm_until_settled` to start the measurement window early while cold long-tail tenants are still populating (`31 req/s`). When the warm-up runs all 8 passes (Trials 1, 2, 3, and 5), throughput reaches **166 to 472 req/s (5.5× to 20.7× faster)**.

---

#### Scenario 7: Full Enterprise Screen with Pareto 80/20 Traffic (`2,000` Tenants) — [`workload/complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 354.03 ms | 23 req/s | 253.83 ms | 32 req/s | 70.02% | **+39.1% (1.39×)** | 7 |
| **Trial 2** | 374.73 ms | 21 req/s | 310.03 ms | 26 req/s | 68.46% | **+23.8% (1.24×)** | 8 |
| **Trial 3** | 383.77 ms | 21 req/s | 400.58 ms | 20 req/s | 62.19% | -4.8% (0.95×) | 5 |
| **Trial 4** | 413.70 ms | 19 req/s | 392.73 ms | 20 req/s | 61.13% | **+5.3% (1.05×)** | 5 |
| **Trial 5** | 339.23 ms | 24 req/s | 398.85 ms | 20 req/s | 58.75% | -16.7% (0.83×) | 4 |
| **Average (5 Runs)** | **373.09 ms** | **22 req/s** *(±1.9 sd, -3/+2)* | **351.21 ms** | **24 req/s** *(±5.4 sd, -4/+8)* | **64.1%** | **+9% (1.09×)** | **5.8** |

---

#### Scenario 8: Cold-Start Cache Under 5% Live `UPDATE` + `INSERT` Writes — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) @ 95% + [`workload/write.sql`](../../workload/write.sql) @ 5%

| Execution | Path A Latency | Path A RPS | Path B Latency | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 322.66 ms | 25 req/s | 2,851.12 ms | 3 req/s | 32.95% | -88.0% (0.12×) | 3 |
| **Trial 2** | 378.34 ms | 21 req/s | 979.29 ms | 8 req/s | 36.52% | -61.9% (0.38×) | 3 |
| **Trial 3** | 285.19 ms | 28 req/s | 3,263.27 ms | 2 req/s | 29.37% | -92.9% (0.07×) | 3 |
| **Trial 4** | 346.50 ms | 23 req/s | 3,367.50 ms | 2 req/s | 27.43% | -91.3% (0.09×) | 3 |
| **Trial 5** | 306.65 ms | 26 req/s | 4,516.17 ms | 2 req/s | 35.59% | -92.3% (0.08×) | 3 |
| **Average (5 Runs)** | **327.87 ms** | **25 req/s** *(±2.7 sd, -4/+3)* | **2,995.47 ms** | **3 req/s** *(±2.6 sd, -1/+5)* | **32.4%** | **-85% (0.15×)** | **3.0** |

---

## 4. Scaling Sweeps Across Tenants, Concurrency, and Warm Writes

In addition to the 5-trial suite above, we ran scaling sweeps to observe how the system behaves as we vary one dimension at a time.

### 4.1 Scaling Active Tenants on the Lightweight Dashboard (`1` to `2,000` Tenants — [`workload/dashboard.sql`](../../workload/dashboard.sql))

Raw log: [`run-tenants-doks.txt`](run-tenants-doks.txt) · TSV: [`results-doks.tsv`](results-doks.tsv)

| Active Tenants | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Speedup | Hit Ratio | Warm-up Passes |
|---:|---|---|---:|---:|---:|
| **1** | 23.3 ms · 343 req/s | **16.6 ms · 481 req/s** | **+40%** | 100.0% | 2 |
| **10** | 22.9 ms · 350 req/s | **21.7 ms · 369 req/s** | **+5%** | 100.0% | 2 |
| **50** | 25.4 ms · 315 req/s | **17.0 ms · 470 req/s** | **+49%** | 100.0% | 3 |
| **100** | 26.5 ms · 302 req/s | **16.3 ms · 491 req/s** | **+63%** | 100.0% | 3 |
| **500** | 24.4 ms · 329 req/s | **16.3 ms · 490 req/s** | **+49%** | 100.0% | 4 |
| **1,000** | 24.0 ms · 333 req/s | **16.9 ms · 473 req/s** | **+42%** | 100.0% | 4 |
| **2,000** | 23.3 ms · 343 req/s | **16.5 ms · 485 req/s** | **+41%** | 100.0% | 6 |

---

### 4.2 Scaling Active Tenants on the Heavy Enterprise Screen (`1` to `1,000` Uniform Tenants — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql))

Raw log: [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)

| Active Tenants (Uniform) | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Speedup | Hit Ratio | Warm-up Passes |
|---:|---|---|---:|---:|---:|
| **1** | 206.8 ms · 39 req/s | **9.2 ms · 871 req/s** | **22.3× (+2,133%)** | 100.0% | 2 |
| **10** | 198.2 ms · 40 req/s | **9.6 ms · 835 req/s** | **20.9× (+1,988%)** | 100.0% | 2 |
| **50** | 227.5 ms · 35 req/s | **10.8 ms · 740 req/s** | **21.1× (+2,014%)** | 100.0% | 6 |
| **200** | 212.8 ms · 38 req/s | **11.2 ms · 712 req/s** | **18.7× (+1,774%)** | 100.0% | 7 |
| **500** | 223.9 ms · 36 req/s | **18.4 ms · 435 req/s** | **12.1× (+1,108%)** | 100.0% | 8 |
| **1,000** *(8-pass warm cap)* | 210.1 ms · 38 req/s | 251.4 ms · 32 req/s | 0.84× (-16%) | 68.1% | 4 |

---

### 4.3 Scaling Concurrent Users (`1` to `32` Clients — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql))

Raw log: [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)

| Concurrent Clients | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Speedup | Hit Ratio |
|---:|---|---|---:|---:|
| **1** | 100.6 ms · 10 req/s | **7.1 ms · 140 req/s** | **14.0× (+1,300%)** | 100.0% |
| **4** | 129.5 ms · 31 req/s | **8.6 ms · 465 req/s** | **15.0× (+1,400%)** | 100.0% |
| **8** | 212.8 ms · 38 req/s | **10.5 ms · 763 req/s** | **20.1× (+1,908%)** | 100.0% |
| **16** | 406.9 ms · 39 req/s | **18.1 ms · 886 req/s** | **22.7× (+2,172%)** | 100.0% |
| **32** | 835.5 ms · 38 req/s | **31.4 ms · 1,020 req/s** | **26.8× (+2,584%)** | 100.0% |

---

### 4.4 Warm Cache Under Live Writes ([`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) + `UPDATE orders`)

Unlike Scenario 8 in Section 3 (which started from a 100% cold pod restart), this test **warms the 200-tenant cache first** and then introduces 5% or 10% live writes:
- **5 of the 8 queries (`62.5%`) use `INNER JOIN`** with `WHERE o.tenant_id = :t`, allowing PgCache to update the tenant's data in-place via CDC replication and keep serving **100% cache hits**.
- **3 of the 8 queries (`37.5%`) use `LEFT JOIN`** (where `o.tenant_id = :t` sits inside the outer join's `ON` clause to preserve zero-order customers), which PgCache conservatively invalidates whenever `orders` changes.

Raw log: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)

| Write Ratio | Tenants Receiving Writes | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Gain / Loss | Hit Ratio |
|---:|---:|---|---|---:|---:|
| **0% (Read-Only)** | — | 189.8 ms · 42 req/s | **11.1 ms · 719 req/s** | **+1,612% (17.1×)** | 100.0% |
| **5% Writes** | 1 hot tenant | 186.7 ms · 43 req/s | **166.2 ms · 48 req/s** | **+12%** | 75.0% |
| **5% Writes** | 10 tenants | 182.4 ms · 44 req/s | 194.4 ms · 41 req/s | -7% | 65.4% |
| **5% Writes** | All 200 tenants | 191.2 ms · 42 req/s | 201.5 ms · 40 req/s | -5% | 65.7% |
| **10% Writes** | 1 hot tenant | 177.7 ms · 45 req/s | **154.7 ms · 52 req/s** | **+16%** | 63.1% |
| **10% Writes** | All 200 tenants | 167.9 ms · 48 req/s | 191.8 ms · 42 req/s | -12% | 64.8% |

---

## 5. Correctness Gate Summary ([`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh))

Full output log: [`verify-correctness-doks.txt`](verify-correctness-doks.txt)

| Stage | What It Verifies | Result |
|---|---|---|
| **Stage 1: Baseline Queries (8/8)** | Runs all 8 queries from [`workload/dashboard.sql`](../../workload/dashboard.sql) on PostgreSQL and PgCache and compares every row byte-for-byte. | **PASS (8/8 identical, 100% cacheable)** |
| **Stage 2: Complex Static Queries (12/12)** | Runs all 12 complex queries from [`complex-search.sql`](../../workload/complex-search.sql), [`complex-joins.sql`](../../workload/complex-joins.sql), and [`complex-analytics.sql`](../../workload/complex-analytics.sql) across 3 passes. | **PASS (12/12 identical, 100% MV hit rate)** |
| **Stage 3: Live CDC Mutation (`UPDATE` + `INSERT`)** | Executes live `UPDATE orders`, `UPDATE order_item`, and `INSERT INTO order_item` on PostgreSQL, waits for CDC replication, and re-verifies all 12 complex queries on PgCache. | **PASS (12/12 identical after live writes)** |

---

## 6. Raw Benchmark Files & Logs

- **Part 2 Follow-Up Study (`results/0.7.1_v2/`)**: [`results/0.7.1_v2/README.md`](../0.7.1_v2/README.md)
- **SQL Workloads & Schema Documentation**: [`workload/README.md`](../../workload/README.md)
- **5-Trial Multi-Run Logs (with Full Pod Recreation)**:
  - Complex Scenarios (`TRIALS=5`): [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)
  - Pareto/Zipfian 80/20 (`TRIALS=5`): [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)
  - Cold-Start `UPDATE + INSERT` Writes (`TRIALS=5`): [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)
- **Single-Pass Scaling & Correctness Logs**:
  - Correctness Gate Output: [`verify-correctness-doks.txt`](verify-correctness-doks.txt)
  - Baseline Tenant Sweep (`1..2000`): [`run-tenants-doks.txt`](run-tenants-doks.txt) · [`results-doks.tsv`](results-doks.tsv)
  - Complex Scenario Comparison: [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt) · [`results-complex-doks.tsv`](results-complex-doks.tsv)
  - Complex Tenant Scaling (`1..1000`): [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)
  - Complex Concurrency Scaling (`1..32` clients): [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)
  - Complex Warm-Cache Write Sweep: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)
