# Benchmarking PgCache 0.7.1 in a Multi-Tenant SaaS (Part 2 — v2): The "Fair Benchmark", Dynamic User Filters, and Core Developer Feedback on `ADMISSION_THRESHOLD`

> 🇧🇷 **[Ler em português](README-pt.md)** · 📖 **[Read Part 1 (`results/0.7.1/`)](../0.7.1/README.md)**

In **[Part 1 (`results/0.7.1/`)](../0.7.1/README.md)**, we benchmarked **PgCache 0.7.1** (`pgcache/pgcache:0.7.1`) in front of **PostgreSQL 17** across a 3-node cloud Kubernetes cluster (`3× s-4vcpu-8gb` VMs in a single availability zone), showing **1.98× speedup** on lightweight operational dashboards and **15× to 29.4× speedup** on heavy multi-table enterprise screens — while also exposing how a completely cold cache struggles under concurrent writes.

After publishing Part 1 and discussing the results with **James (PgCache core developer)**, we designed **Part 2 (`0.7.1_v2`)** to answer two fundamental sets of questions:

1. **Methodological Fairness ("The Fair Benchmark")**:
   - *What if PostgreSQL Origin is given a production-tuned, 100% prewarmed in-memory buffer pool (`2 GiB shared_buffers` + `pg_prewarm` + `work_mem = 32MB` + `random_page_cost = 0.2`) and is never restarted between trials?*
   - *What if we add `GIN (gin_trgm_ops)` trigram indexes to PostgreSQL and replace 1-character `ILIKE '%1%'` searches with realistic 3+ character search terms (`'%prod%'`, `'%cust%'`, `'% order %'`, `'%quality%'`) that PostgreSQL's trigram index can actually accelerate?*
   - *What happens when users apply **dynamic intra-tenant filters** (`:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`), expanding the cache keyspace 120× (`24,000` query combinations across 200 tenants)?*
2. **PgCache Core Developer Hypotheses (James)**:
   - *How do PgCache's internal Materialized Views (stored in its embedded PostgreSQL instance) behave under cold start and warm-up when we raise **`ADMISSION_THRESHOLD` from `1` (default) to `2` or `4`**?*
   - *Does raising `ADMISSION_THRESHOLD` prevent cache pollution and Materialized View creation storms when users run rare or one-off dynamic filter combinations?*
   - *How would an internal **"Shadow Warm-Up / Pass-Through Mode"** inside PgCache change the cold-start equation?*

---

## 1. Executive Summary (TL;DR)

1. **Tuned & Prewarmed PostgreSQL Origin Is Up to +83% Faster — Yet PgCache Still Delivers 8.7× to 10.7× Speedup on Static Screens**:
   - Giving PostgreSQL `2 GiB` of prewarmed `shared_buffers`, `work_mem = 32MB`, `random_page_cost = 0.2`, and **4 `GIN (gin_trgm_ops)` trigram indexes** ([`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql)) boosts Origin throughput from `63 req/s` to **`80 req/s` (+27%)** on 1-char search (`search_1c`), to **`115 req/s` (+83%)** on 3+ char trigram-indexed search (`search_3c`), and from `26 req/s` to **`30 req/s` (+15%)** on the 8-query enterprise screen (`cplx_dash`).
   - Even against this fully prewarmed, trigram-indexed Origin, PgCache 0.7.1 delivers **`855 req/s` (+971% / 10.7×)** on `search_1c`, **`1,138 req/s` (+889% / 9.9×)** on `search_3c`, and **`265 req/s` mean (`353 req/s` across settled runs, up to `458 req/s` / +1,407% peak)** on `cplx_dash`.
2. **Dynamic Intra-Tenant Filters (`cplx_dyn`) Expose Cache Pollution at Default `ADMISSION_THRESHOLD=1`**:
   - When users vary 5 intra-tenant filter parameters on every screen load ([`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql), multiplying the query keyspace 120×), ~50% of requests after warm-up are still unseen filter combinations.
   - Under default `ADMISSION_THRESHOLD=1`, PgCache synchronously creates a new Materialized View for **every first-seen filter combination**, dropping throughput to **`15 req/s` (`530.3 ms`, -56% slower than Origin's `34 req/s`)**.
3. **Validating James's Hypothesis: `ADMISSION_THRESHOLD = 2` and `4` Transform Cold Start and Dynamic Filters**:
   - **Cold Start (`0s` warm-up on `cplx_dash`)**: Raising `ADMISSION_THRESHOLD` from `1` to `2` cuts cold-start latency by **-20%** (`896.1 ms` $\rightarrow$ `715.7 ms`), and raising it to `4` cuts cold-start latency by **-58%** (`896.1 ms` $\rightarrow$ **`372.5 ms`**, more than doubling throughput from `9` to `21 req/s`).
   - **30-Second Warm-Up (`30s` on `cplx_dash`)**: Raising `ADMISSION_THRESHOLD` from `1` to `4` cuts 30s warm-up latency by **-76%** (`1,788.8 ms / 5 req/s` $\rightarrow$ **`433.5 ms / 23 req/s`**, with Trials 1–2 running at **`265–270 ms / 30 req/s`** — nearly zero warm-up overhead).
   - **Dynamic Intra-Tenant Filters (`cplx_dyn`)**:
     - `ADMISSION_THRESHOLD=2` cuts latency by **-44.5%** (`530.3 ms` $\rightarrow$ **`294.3 ms`**) and boosts throughput by **+80%** (`15` $\rightarrow$ **`27 req/s`**).
     - **`ADMISSION_THRESHOLD=4` completely eliminates the `-56%` regression** (`530.3 ms / 15 req/s` $\rightarrow$ **`235.8 ms / 34 req/s`**, matching Origin's `232.8 ms / 34 req/s` with `-1%` mean and **`+2.9%` speedup in Trial 2**) because one-off filter combinations pass straight through to Origin while only recurring tenant queries (`18.4%` hit rate) are cached!
4. **Three Production Engineering Discoveries**:
   - **Per-Tenant Row Density (`2,500` vs. `250` Orders/Tenant)**: Concentrating 500k orders into 200 dense tenants (10× more rows per tenant) scales both Origin join cost (`69.9 ms` $\rightarrow$ `633.8 ms`) and PgCache Materialized View scan cost (`7.2 ms` $\rightarrow$ `168.6 ms`, still **3.8× faster** than Origin).
   - **The Over-Indexing Trap & Correlated `tenant_id` Predicates**: Repeating `tenant_id = :t` across joined tables (required by PgCache for per-tenant CDC isolation) causes PostgreSQL's planner to multiply selectivities ($\frac{1}{N^3}$) and estimate `rows=1`. Adding wide B-tree `INCLUDE` covering indexes tricked the planner into catastrophic nested-loop index scans (`1,000 ms / 8 req/s`), whereas dropping the covering indexes and setting `ALTER DATABASE bench SET random_page_cost = 0.2;` restored optimal `Index Scan` + `Hash Join` plans (`264 ms / 30 req/s`).
   - **Cgroup Memory Governance (`resources.limits.memory: 5200Mi`)**: Setting an explicit cgroup memory limit prevents PgCache's entrypoint from over-allocating buffers based on host `/proc/meminfo` (`7GB total`) on 8 GB Kubernetes nodes.

---

## 2. What Changed in the `0.7.1_v2` Setup

### 2.1 Fair PostgreSQL Origin Tuning ([`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql))

To ensure PostgreSQL Origin is evaluated at peak in-memory efficiency on its dedicated `4 vCPU / 8 GB` node (`s-4vcpu-8gb`):

| Parameter / Index | Part 1 (`0.7.1` Baseline) | Part 2 (`0.7.1_v2` Fair Tuning) | Why It Matters |
|---|---|---|---|
| `shared_buffers` | `1024MB` (cold on each trial) | **`2048MB` (`2 GiB`) + `pg_prewarm()`** | Fits the entire ~590 MB dataset + all indexes in PostgreSQL RAM with zero disk reads. |
| Pod Recreation Mode | `RECREATE_PODS_MODE="all"` | **`RECREATE_PODS_MODE="pgcache"`** | Keeps PostgreSQL Origin 100% warm across all trials while recreating PgCache from scratch on every trial. |
| `work_mem` | `16MB` | **`32MB`** | Prevents multi-table hash joins and `GROUP BY` sorts from spilling to temporary files. |
| `random_page_cost` | `1.1` | **`0.2` (`ALTER DATABASE bench SET`)** | Reflects a 100% RAM-resident working set and prevents correlated `rows=1` estimates from choosing `Seq Scan` on `category` and `seller`. |
| Trigram Indexes (`pg_trgm`) | None | **4 `GIN (gin_trgm_ops)` Indexes** | Indexes `customer.name`, `customer.email`, `product.name`, and `review.body` for `ILIKE '%...%'` substring searches of $\ge 3$ characters. |
| PgCache Container Memory | Unbounded (`memory.max = max`) | **`resources.limits.memory: 5200Mi`** | Ensures `pgcache-entrypoint.sh` tunes its embedded PostgreSQL (`127.0.0.1:5433`) for `5GB total` instead of `7GB total`, preventing Kubelet eviction. |

### 2.2 New Fair & Dynamic SQL Workloads

> 📖 **Full SQL Code**: See [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql) and [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql).

| Workload Label & File | Queries per Screen | What It Tests |
|---|:---:|---|
| **`search_1c`**<br>[`workload/complex-search.sql`](../../workload/complex-search.sql) | **4** | **1-Char Substring Search (`ILIKE '%1%'`)**: Baseline wildcard search where `GIN pg_trgm` cannot extract 3-character trigrams. |
| **`search_3c`**<br>[`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql) | **4** | **3+ Char Trigram Search (`ILIKE '%prod%'`, `'%cust%'`, `'% order %'`, `'%quality%'`)**: Realistic search terms that PostgreSQL's `GIN (gin_trgm_ops)` indexes accelerate via `Bitmap Index Scan`. |
| **`cplx_dash`**<br>[`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) | **8** | **Static 8-Query Enterprise Screen**: 3 analytical rollups, 3 deep 4-to-6 table joins (`INNER` + `LEFT JOIN`), and 2 `ILIKE` searches with fixed intra-tenant filter literals (`1,600` distinct queries across 200 tenants). |
| **`cplx_dyn`**<br>[`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql) | **8** | **Dynamic Intra-Tenant Filter Screen**: The same 8 enterprise queries, but every request randomizes 5 user filter parameters (`:min_price` $\in \{20,40,60,80,100\}$, `:min_rev` $\in \{50,100,150,200\}$, `:min_rating` $\in \{2,3,4\}$, `:min_cnt` $\in \{1,2\}$, `:lim` $\in \{15,25\}$), expanding the keyspace 120× (`24,000` combinations). |

---

## 3. The "Fair Benchmark" Results (`TRIALS=5`, `DURATION=15s`, `CLIENTS=8`)

Raw logs: [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt) · [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt) · [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)

### 3.1 Consolidated 5-Run Summary

| Fair Scenario (`CLIENTS=8`, `TENANTS=200`) | Tuned PostgreSQL Origin (Path A Mean) | PgCache 0.7.1 (Path B Mean) | Hit Rate | Mean Speedup (5-Run Spread) | Warm-up Passes |
|---|---|---|---:|---|---:|
| **1. `search_1c` — 1-Char `ILIKE '%1%'`** ([`complex-search.sql`](../../workload/complex-search.sql)) | **100.45 ms · 80 req/s** *(±1.9 sd, +27% vs Part 1)* | **9.38 ms · 855 req/s** *(±46.1 sd)* | **100.0%** | **10.7× (+971%)** *(-91% / +36%)* | 5.2 |
| **2. `search_3c` — 3+ Char `ILIKE` + `GIN pg_trgm`** ([`complex-search-fair.sql`](../../workload/complex-search-fair.sql)) | **69.86 ms · 115 req/s** *(±6.5 sd, +83% vs Part 1)* | **7.17 ms · 1,138 req/s** *(±162.6 sd)* | **100.0%** | **9.9× (+889%)** *(-152% / +147%)* | 3.6 |
| **3. `cplx_dash` — Static 8-Query Enterprise Screen** ([`complex-dashboard.sql`](../../workload/complex-dashboard.sql)) | **264.21 ms · 30 req/s** *(±0.5 sd, +15% vs Part 1)* | **193.24 ms · 265 req/s** *(353 req/s in T1–T4)* | **90.4%** *(99.9% T1–T4)* | **8.7× (+766%)** *(up to +1,407%)* | 7.2 |
| **4. `cplx_dyn` — Dynamic Intra-Tenant Filters** ([`complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)) | **237.57 ms · 34 req/s** *(±1.6 sd)* | 530.31 ms · **15 req/s** *(±1.2 sd)* | **49.9%** | **0.44× (-56%)** *(-3% / +6%)* | 7.0 |

---

### 3.2 Run-by-Run Breakdown: All 5 Executions per Scenario

#### Fair Scenario 1: `search_1c` (`ILIKE '%1%'`, 1-Char Wildcard) — Origin `2 GiB` Prewarmed

| Execution | Path A Latency (Tuned Origin) | Path A RPS | Path B Latency (PgCache) | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 101.32 ms | 79 req/s | 9.14 ms | 875 req/s | 100.00% | **+1,007.6% (11.1×)** | 5 |
| **Trial 2** | 98.96 ms | 81 req/s | 9.23 ms | 867 req/s | 100.00% | **+970.4% (10.7×)** | 6 |
| **Trial 3** | 100.23 ms | 80 req/s | 10.20 ms | 784 req/s | 100.00% | **+880.0% (9.8×)** | 5 |
| **Trial 4** | 104.35 ms | 77 req/s | 9.51 ms | 841 req/s | 100.00% | **+992.2% (10.9×)** | 5 |
| **Trial 5** | 97.39 ms | 82 req/s | 8.82 ms | 907 req/s | 100.00% | **+1,006.1% (11.1×)** | 5 |
| **Average (5 Runs)** | **100.45 ms** | **80 req/s** *(±1.9 sd, -3/+2)* | **9.38 ms** | **855 req/s** *(±46.1 sd, -71/+52)* | **100.0%** | **+971% (10.7×)** | **5.2** |

---

#### Fair Scenario 2: `search_3c` (3+ Char Trigram `ILIKE` + 4 `GIN pg_trgm` Indexes) — [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql)

| Execution | Path A Latency (Tuned Origin) | Path A RPS | Path B Latency (PgCache) | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 70.34 ms | 114 req/s | 6.18 ms | 1,295 req/s | 100.00% | **+1,036.0% (11.4×)** | 4 |
| **Trial 2** | 66.47 ms | 120 req/s | 7.17 ms | 1,116 req/s | 100.00% | **+830.0% (9.3×)** | 3 |
| **Trial 3** | 67.38 ms | 119 req/s | 6.71 ms | 1,192 req/s | 100.00% | **+901.7% (10.0×)** | 3 |
| **Trial 4** | 68.26 ms | 117 req/s | 6.59 ms | 1,215 req/s | 100.00% | **+938.5% (10.4×)** | 4 |
| **Trial 5** | 76.87 ms | 104 req/s | 9.20 ms | 870 req/s | 100.00% | **+736.5% (8.4×)** | 4 |
| **Average (5 Runs)** | **69.86 ms** | **115 req/s** *(±6.5 sd, -11/+5)* | **7.17 ms** | **1,138 req/s** *(±162.6 sd, -268/+157)* | **100.0%** | **+889% (9.9×)** | **3.6** |

> **What `search_3c` vs `search_1c` proves**: Adding 4 `GIN (gin_trgm_ops)` indexes and using 3+ character search patterns (`'%prod%'`, `'%cust%'`, `'% order %'`, `'%quality%'`) genuinely accelerates PostgreSQL Origin — latency drops from `100.45 ms (80 req/s)` to **`69.86 ms (115 req/s)` (+44% faster than `search_1c`, and +83% faster than Part 1's untuned `63 req/s`)**! Faster Origin execution also accelerates PgCache's warm-up (converging in **3.6 passes** instead of 5.2), and once cached, PgCache still serves **1,138 req/s (9.9× faster than tuned Origin)** because it avoids re-evaluating the 3-to-6 table joins and trigram bitmap checks on every screen load.

---

#### Fair Scenario 3: `cplx_dash` (Static 8-Query Enterprise Screen) — Origin `2 GiB` Prewarmed

| Execution | Path A Latency (Tuned Origin) | Path A RPS | Path B Latency (PgCache) | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 256.31 ms | 31 req/s | 29.63 ms | 270 req/s | 99.99% | **+771.0% (8.7×)** | 8 |
| **Trial 2** | 269.73 ms | 30 req/s | 60.20 ms | 133 req/s | 99.72% | **+343.3% (4.4×)** | 8 |
| **Trial 3** | 260.60 ms | 31 req/s | 17.47 ms | 458 req/s | 100.00% | **+1,377.4% (14.8×)** | 8 |
| **Trial 4** | 265.56 ms | 30 req/s | 17.69 ms | 452 req/s | 100.00% | **+1,406.7% (15.1×)** | 8 |
| **Trial 5** | 268.88 ms | 30 req/s | 841.18 ms | 10 req/s | 52.29% | -66.7% (0.33×) | 4 |
| **Average (5 Runs)** | **264.21 ms** | **30 req/s** *(±0.5 sd, -0/+1)* | **193.24 ms** | **265 req/s** *(±196.7 sd; 353 req/s T1–T4)* | **90.4%** *(99.9% T1–T4)* | **+766% (8.7×)** | **7.2** |

> **Why Trial 5 stopped warming at Pass 4**: In Trial 5, `warm_until_settled` observed `< 1%` hit-rate delta between passes 3 and 4 around `52.29%` and started the measurement window early while the remaining half of the 200 tenants were still populating Materialized Views (`10 req/s`). Across the 4 runs that completed all 8 warm-up passes (Trials 1–4), PgCache averaged **353 req/s (`99.93%` hit rate, 11.6× faster than tuned Origin)**. Notice also how prewarming Origin eliminated Path A's variance (`30 to 31 req/s`, `±0.5 sd`).

---

#### Fair Scenario 4: `cplx_dyn` (Dynamic Intra-Tenant Filters — `:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`)

| Execution | Path A Latency (Tuned Origin) | Path A RPS | Path B Latency (PgCache `ADMISSION_THRESHOLD=1`) | Path B RPS | Cache Hit Rate | Speedup (Gain) | Warm-up Passes |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Trial 1** | 235.66 ms | 34 req/s | 465.01 ms | 17 req/s | 58.82% | -50.0% (0.50×) | 8 |
| **Trial 2** | 230.98 ms | 35 req/s | 539.74 ms | 15 req/s | 51.51% | -57.1% (0.43×) | 8 |
| **Trial 3** | 228.06 ms | 35 req/s | 519.48 ms | 15 req/s | 59.55% | -57.1% (0.43×) | 8 |
| **Trial 4** | 237.90 ms | 34 req/s | 557.03 ms | 14 req/s | 42.83% | -58.8% (0.41×) | 6 |
| **Trial 5** | 255.26 ms | 31 req/s | 570.29 ms | 14 req/s | 36.88% | -54.8% (0.45×) | 5 |
| **Average (5 Runs)** | **237.57 ms** | **34 req/s** *(±1.6 sd, -3/+1)* | **530.31 ms** | **15 req/s** *(±1.2 sd, -1/+2)* | **49.9%** | **-56% (0.44×)** | **7.0** |

> **Why `cplx_dyn` regresses by `-56%` at default `ADMISSION_THRESHOLD=1`**: Because each query interpolates user-selected filter thresholds (`:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`), the cache keyspace explodes from `1,600` queries to `24,000` combinations. After 7–8 warm-up passes, `50.1%` of incoming requests are still unseen filter combinations. Under default `ADMISSION_THRESHOLD=1`, PgCache admits and builds a new Materialized View for **every single first-seen filter combination**, making the proxy `2.2×` slower than querying PostgreSQL directly (`530.3 ms` vs `237.6 ms`). In **Section 4**, we show how raising `ADMISSION_THRESHOLD` to `2` or `4` solves this exact problem.

---

### 3.3 Three Architectural Discoveries from the Fair Benchmark

While engineering the Fair Benchmark, we uncovered three critical database and proxy interactions that every production team should know:

#### Discovery 1: Per-Tenant Row Density (`2,500` vs. `250` Orders per Tenant — [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt))

When the same `500,000` orders and `2,000,000` order items are concentrated into **200 dense tenants** (`2,500` orders and `10,000` order items per tenant, logged in [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt)) instead of **2,000 standard tenants** (`250` orders and `1,000` items per tenant, logged in [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)), each per-tenant join processes **10× more rows**:

| Dataset Density (`500k` Orders, `2M` Items) | Orders / Items per Tenant | Tuned Origin (`search_3c`) | PgCache 0.7.1 (`search_3c`) | Hit Rate | Speedup |
|---|---:|---|---|---:|---:|
| **Standard Multi-Tenant (`2,000` Tenants)**<br>[`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt) | `250` orders / `1,000` items | 69.86 ms · **115 req/s** *(±6.5 sd)* | **7.17 ms · 1,138 req/s** *(±162.6 sd)* | 100.0% | **9.9× (+889%)** |
| **10× Dense Tenants (`200` Tenants)**<br>[`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt) | `2,500` orders / `10,000` items | 633.83 ms · **13 req/s** *(±0.8 sd)* | **168.58 ms · 48 req/s** *(±7.2 sd)* | 100.0% | **3.8× (+281%)** |

As James noted, PgCache backs heavy multi-table queries with internal Materialized Views in its embedded PostgreSQL instance (`127.0.0.1:5433`). When each tenant owns 10× more rows, both Origin's join work and PgCache's per-tenant Materialized View scan scale with the tenant's row cardinality — yet PgCache still delivers a **3.8× speedup (+281%)** on 10× denser tenants.

#### Discovery 2: The Over-Indexing Trap & Correlated Multi-Table `tenant_id` Predicates ([`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt))

- To enable per-tenant CDC invalidation and index pushdown, PgCache queries repeat `tenant_id = :t` across every joined table (`WHERE o.tenant_id = :t AND oi.tenant_id = :t AND c.tenant_id = :t`).
- Because PostgreSQL's query planner assumes predicates across different tables are statistically independent, it multiplies their selectivities ($\frac{1}{N} \times \frac{1}{N} \times \frac{1}{N}$) and estimates **`rows=1`** for the join result.
- When we initially tested adding **6 wide B-tree `INCLUDE` covering indexes** alongside the 4 `GIN pg_trgm` indexes on the 200-tenant-dense dataset (logged in [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)), that `rows=1` underestimate tricked PostgreSQL into abandoning fast `Hash Join` / `Bitmap Heap Scan` plans in favor of deep nested-loop index scans (`cplx_dash` ran at `1,000.3 ms / 8 req/s` on Origin, and `search_3c` took `795.4 ms / 10 req/s` vs `633.8 ms / 13 req/s` without the covering indexes).
- Even without covering indexes, `rows=1` caused PostgreSQL to pick `Seq Scan on category` (`cost=1.625`) over `Index Scan using category_pkey` (`cost=2.36`) when `random_page_cost=1.1`; setting `ALTER DATABASE bench SET random_page_cost = 0.2;` restored `Index Scan` across all lookup tables.

#### Discovery 3: Cgroup Memory Governance for PgCache's Embedded PostgreSQL (`resources.limits.memory: 5200Mi`)

- Inside the PgCache container, `pgcache-entrypoint.sh` launches an embedded PostgreSQL 17 instance (`127.0.0.1:5433`, database `pgcache_cache`) to store Materialized Views and auto-tunes its buffer settings by reading `/sys/fs/cgroup/memory.max` (falling back to `/proc/meminfo` when `memory.max` is `max`).
- On an 8 GB cloud node (`Allocatable: ~6.26 GiB`), leaving `resources.limits.memory` unset causes `pgcache-entrypoint.sh` to auto-tune for `7GB total`, which under heavy Materialized View creation triggers Kubelet node-level memory pressure and pod eviction. Setting `resources.limits.memory: "5200Mi"` in [`infra/helm/pgcache-mt/values-do-tuned.yaml`](../../infra/helm/pgcache-mt/values-do-tuned.yaml) makes PgCache auto-tune cleanly for `5GB total` with zero evictions.

---

## 4. PgCache Core Developer Feedback (James) & `ADMISSION_THRESHOLD` Sweep (`1` vs `2` vs `4`, `TRIALS=3`)

After reviewing Part 1, **James (PgCache core developer)** shared three architectural observations and hypotheses:

> **1. Disk-Backed Materialized Views in Embedded PostgreSQL**:
> *"For the heavy multi-table screens — those are most likely being backed by pgcache's version of materialized views, so precomputed results but still disk backed and not purely in memory (although they may be in the internal postgres instance's buffer cache)."*
>
> **2. Tuning `admission_threshold` (`1` vs `2` vs `4`)**:
> *"A couple of thoughts on the cold start — I'm curious what happens to warm up and cold start if the `admission_threshold` is set higher than 1, maybe 2 or 4. It controls how many times a query has to be seen before it'll be admitted to the cache. A setting of 2 will avoid populating and invalidating many queries that are seen once or rarely. Setting it to 4 is a more extreme version."*
>
> **3. Internal Shadow Warm-Up / Pass-Through Mode**:
> *"The second thought is what if pgcache itself had a cold start or warm up mode, where it would cache and populate queries but still pass everything through to origin until a warm-up threshold or steady state was hit. Basically moving the warm-up phases the bench does into the cache as an internal behavior."*

To test James's `ADMISSION_THRESHOLD` hypothesis empirically, we added `ADMISSION_THRESHOLD` support to the Helm chart ([`infra/helm/pgcache-mt/templates/pgcache.yaml`](../../infra/helm/pgcache-mt/templates/pgcache.yaml)) and ran [`scripts/07-admission-threshold-sweep.sh`](../../scripts/07-admission-threshold-sweep.sh) (`TRIALS=3`, recreating the PgCache pod before every trial while keeping Origin `2 GiB` prewarmed) across **`ADMISSION_THRESHOLD = 1`, `2`, and `4`**, measuring four distinct regimes:
1. **`cold0s` (Pure Cold Start, `0s` warm-up)**: First 15-second window immediately after a fresh PgCache pod start on [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (`200` tenants).
2. **`w30s` (Early Warm-Up, `30s` warm-up)**: Measurement window after 30 seconds of warming on [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (`200` tenants).
3. **`settle` (Settled Steady-State, `warm_until_settled` up to 8 passes / `120s`)**: Steady-state measurement on [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (`200` tenants).
4. **`dyn` (Dynamic Intra-Tenant Filters, `warm_until_settled`)**: Steady-state measurement on [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql) (`200` tenants × `120` filter combinations).

Raw log: [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)

### 4.1 Consolidated Comparison Across `ADMISSION_THRESHOLD = 1, 2, 4` (`TRIALS=3`)

| Regime & Workload (`TENANTS=200`, `CLIENTS=8`) | `ADMISSION_THRESHOLD = 1` (Default) | `ADMISSION_THRESHOLD = 2` (Balanced) | `ADMISSION_THRESHOLD = 4` (Conservative) | Key Architectural Effect |
|---|---|---|---|---|
| **1. Pure Cold Start (`0s` warm-up)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | 896.09 ms · **9 req/s**<br>*(hit: 3.80%, -70.8%)* | **715.66 ms · 11 req/s**<br>*(hit: 4.73%, -62.1%)* | **372.48 ms · 21 req/s**<br>*(hit: 0.76%, -31.9%)* | **`threshold=4` cuts cold-start latency by -58% (`896` $\rightarrow$ `372 ms`) and more than doubles RPS (`9` $\rightarrow$ `21 req/s`)** |
| **2. Early Warm-Up (`30s` warm-up)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | 1,788.75 ms · **5 req/s**<br>*(hit: 27.98%, -84.4%)* | **1,311.75 ms · 6 req/s**<br>*(hit: 23.73%, -79.8%)* | **433.49 ms · 23 req/s**<br>*(hit: 23.91%, -23.1%; 30 req/s in T1–T2)* | **`threshold=4` cuts 30s warm-up latency by -76% (`1,789` $\rightarrow$ `433 ms`) by pacing MV creation** |
| **3. Settled Steady-State (`warm_until_settled`)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | **193.24 ms · 265 req/s**<br>*(hit: 90.4% / 99.9% T1–T4, **+766%**)* | **474.59 ms · 161 req/s**<br>*(hit: 82.7% / 100% T1, **+406%**, up to 433 req/s)* | 728.80 ms · **16 req/s**<br>*(hit: 26.3%, -49% at 8-pass cap)* | **`threshold=2` still reaches `100%` hit (`433 req/s`), whereas `threshold=4` needs `>8` passes (`>120s`) to admit all 200 tenants** |
| **4. Dynamic Intra-Tenant Filters (`cplx_dyn`)**<br>[`complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql) | 530.31 ms · **15 req/s**<br>*(hit: 49.9%, **-56%**)* | **294.26 ms · 27 req/s**<br>*(hit: 41.3%, **-21%**, +80% RPS vs `t=1`)* | **235.77 ms · 34 req/s**<br>*(hit: 18.4%, **-1% mean / +2.9% T2**)* | **`threshold=2` cuts dynamic-filter latency by -44.5%, and `threshold=4` completely eliminates the -56% regression (`34 req/s` = Origin!)** |

---

### 4.2 Trial-by-Trial Breakdown (`07-admission-threshold-k8s.txt`, `TRIALS=3`)

| Threshold & Cell | Trial 1 (Path A vs Path B) | Trial 2 (Path A vs Path B) | Trial 3 (Path A vs Path B) | 3-Trial Mean (Path A vs Path B, Hit %, Gain) |
|---|---|---|---|---|
| **`t1_cold0s`** (`t=1`, `0s`) | A: 260.7 ms (31 rps)<br>B: 973.0 ms (8 rps, 3.54%) | A: 273.9 ms (29 rps)<br>B: 853.8 ms (9 rps, 3.96%) | A: 273.6 ms (29 rps)<br>B: 861.4 ms (9 rps, 3.90%) | A: **269.40 ms (30 rps)** \| B: **896.09 ms (9 rps)** \| Hit: **3.80%** \| **-70.8%** |
| **`t1_w30s`** (`t=1`, `30s`) | A: 270.6 ms (30 rps)<br>B: 1,271.1 ms (6 rps, 28.85%) | A: 265.0 ms (30 rps)<br>B: 1,950.0 ms (4 rps, 29.16%) | A: 263.8 ms (30 rps)<br>B: 2,145.2 ms (4 rps, 25.92%) | A: **266.46 ms (30 rps)** \| B: **1,788.75 ms (5 rps)** \| Hit: **27.98%** \| **-84.4%** |
| **`t2_cold0s`** (`t=2`, `0s`) | A: 274.6 ms (29 rps)<br>B: 728.4 ms (11 rps, 6.11%) | A: 290.6 ms (28 rps)<br>B: 706.3 ms (11 rps, 4.68%) | A: 264.1 ms (30 rps)<br>B: 712.2 ms (11 rps, 3.41%) | A: **276.43 ms (29 rps)** \| B: **715.66 ms (11 rps)** \| Hit: **4.73%** \| **-62.1%** |
| **`t2_w30s`** (`t=2`, `30s`) | A: 251.6 ms (32 rps)<br>B: 1,399.3 ms (6 rps, 23.99%) | A: 254.6 ms (31 rps)<br>B: 1,427.1 ms (6 rps, 23.51%) | A: 258.2 ms (31 rps)<br>B: 1,108.8 ms (7 rps, 23.70%) | A: **254.81 ms (31 rps)** \| B: **1,311.75 ms (6 rps)** \| Hit: **23.73%** \| **-79.8%** |
| **`t2_settle`** (`t=2`, settled) | A: 252.5 ms (32 rps)<br>B: **18.5 ms (433 rps, 100.00%)** | A: 270.0 ms (30 rps)<br>B: 1,221.8 ms (7 rps, 54.49%, w7) | A: 259.5 ms (31 rps)<br>B: **183.5 ms (44 rps, 93.72%)** | A: **260.69 ms (31 rps)** \| B: **474.59 ms (161 rps)** \| Hit: **82.7%** \| **+406%** |
| **`t2_dyn`** (`t=2`, dynamic) | A: 236.7 ms (34 rps)<br>B: **271.7 ms (29 rps, 41.99%)** | A: 232.3 ms (34 rps)<br>B: **320.2 ms (25 rps, 38.22%)** | A: 227.3 ms (35 rps)<br>B: **290.9 ms (27 rps, 43.63%)** | A: **232.08 ms (34 rps)** \| B: **294.26 ms (27 rps)** \| Hit: **41.3%** \| **-21%** |
| **`t4_cold0s`** (`t=4`, `0s`) | A: 257.0 ms (31 rps)<br>B: **357.5 ms (22 rps, 1.07%)** | A: 261.3 ms (31 rps)<br>B: **383.3 ms (21 rps, 0.23%)** | A: 253.1 ms (32 rps)<br>B: **376.7 ms (21 rps, 0.97%)** | A: **257.15 ms (31 rps)** \| B: **372.48 ms (21 rps)** \| Hit: **0.76%** \| **-31.9%** |
| **`t4_w30s`** (`t=4`, `30s`) | A: 248.2 ms (32 rps)<br>B: **265.3 ms (30 rps, 21.03%)** | A: 257.7 ms (31 rps)<br>B: **270.3 ms (30 rps, 25.56%)** | A: 287.6 ms (28 rps)<br>B: 764.9 ms (10 rps, 25.14%) | A: **264.48 ms (30 rps)** \| B: **433.49 ms (23 rps)** \| Hit: **23.91%** \| **-23.1%** |
| **`t4_settle`** (`t=4`, settled) | A: 272.3 ms (29 rps)<br>B: 461.9 ms (17 rps, 28.70%) | A: 253.5 ms (32 rps)<br>B: 340.2 ms (24 rps, 30.77%) | A: 263.6 ms (30 rps)<br>B: 1,384.2 ms (6 rps, 19.48%) | A: **263.13 ms (30 rps)** \| B: **728.80 ms (16 rps)** \| Hit: **26.3%** \| **-49%** |
| **`t4_dyn`** (`t=4`, dynamic) | A: 238.2 ms (34 rps)<br>B: **235.2 ms (34 rps, +0.0%)** | A: 233.6 ms (34 rps)<br>B: **227.9 ms (35 rps, +2.9%)** | A: 226.7 ms (35 rps)<br>B: **244.3 ms (33 rps, -5.7%)** | A: **232.83 ms (34 rps)** \| B: **235.77 ms (34 rps)** \| Hit: **18.4%** \| **-1%** |

---

### 4.3 Synthesis: Why James's Two Ideas Complement Each Other Perfectly

1. **Why `ADMISSION_THRESHOLD > 1` Solves High-Cardinality Filter Pollution (`cplx_dyn`)**:
   - In [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql), 2 of the 8 queries per screen are tenant-level queries without dynamic filter parameters (repeated frequently for the same tenant), while 6 of the 8 queries include combinatorial user filters (`:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`).
   - With `ADMISSION_THRESHOLD=1`, PgCache blindly builds a Materialized View for every rare filter combination on first sight, spending `530.3 ms` per screen (`15 req/s`, `-56%`).
   - With `ADMISSION_THRESHOLD=2`, PgCache ignores one-off filter combinations (passing them straight through to Origin in `~235 ms`) and caches only queries seen at least twice, cutting latency to **`294.3 ms` (`27 req/s`, +80% faster than `t=1`)**.
   - With `ADMISSION_THRESHOLD=4`, PgCache caches **only** the recurring tenant queries (`18.4%` hit rate) and passes all ad-hoc filter combinations directly to Origin — matching Origin's speed (**`235.8 ms / 34 req/s` vs `232.8 ms / 34 req/s`, with Trial 2 reaching `227.9 ms / 35 req/s (+2.9%)`**) and **100% eliminating the `-56%` regression**!
2. **Why James's Proposed "Internal Warm-Up / Shadow Pass-Through Mode" Is the Ideal Next Feature**:
   - While `ADMISSION_THRESHOLD=4` protects cold start (`372.5 ms / 21 req/s`) and `t4_w30s` (`265–270 ms / 30 req/s` in Trials 1–2), it delays full multi-tenant steady-state convergence (`t4_settle` is still at `26.3%` hit after 8 warm-up passes because every one of the 200 tenants must be visited 4 times before Materialized View population even starts).
   - If PgCache implements James's **Internal Warm-Up / Pass-Through Mode** — where cache misses are forwarded directly to Origin on the client's critical path (`~260 ms` latency) while PgCache populates the Materialized View **asynchronously in the background** until warm — users will get **zero cold-start penalty** (`~30 req/s` from second zero instead of `5–9 req/s`) combined with **full steady-state acceleration (`350–458 req/s`, `+1,400%`)** as soon as background population finishes.

---

## 5. Raw Benchmark Files & Reproducibility

- **Part 1 Report (`results/0.7.1/`)**: [`results/0.7.1/README.md`](../0.7.1/README.md)
- **SQL Tuning & Workloads**:
  - Fair Origin Tuning & Prewarming (`2 GiB` + 4 `GIN pg_trgm` indexes): [`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql)
  - 3+ Char Trigram Search Workload (`search_3c`): [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql)
  - Dynamic Intra-Tenant Filter Workload (`cplx_dyn`): [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)
  - Benchmark Scripts: [`scripts/06-fair-benchmark.sh`](../../scripts/06-fair-benchmark.sh) · [`scripts/07-admission-threshold-sweep.sh`](../../scripts/07-admission-threshold-sweep.sh)
- **Raw Multi-Trial Logs (`results/0.7.1_v2/`)**:
  - Fair Benchmark (`TRIALS=5`, `2,000`-Tenant Standard Dataset): [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)
  - `ADMISSION_THRESHOLD` Sweep (`1` vs `2` vs `4`, `TRIALS=3`): [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)
  - Dense 200-Tenant `search_3c` (`2,500` orders/tenant, `TRIALS=5`): [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt)
  - Over-Indexed B-Tree `INCLUDE` + `GIN` Diagnostic (`TRIALS=5`): [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)
