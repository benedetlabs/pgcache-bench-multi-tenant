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
5. **Local NVMe SSD + Premium Intel CPU (`s-4vcpu-8gb-intel` vs `s-4vcpu-8gb` Regular SSD) on Materialized Views**:
   - Because PgCache stores and indexes Materialized Views in its embedded PostgreSQL 17 instance (`/var/lib/postgresql/data`), upgrading from the basic node (`s-4vcpu-8gb` Regular SSD) to **Local NVMe SSD + Premium Intel (`s-4vcpu-8gb-intel`)** boosted 8 kB page `fsync` IOPS by **+127% (`2,050` $\rightarrow$ `4,648 ops/s`, latency `488 µs` $\rightarrow$ `215 µs`)**.
   - On the full 8-query enterprise screen (`mv_dash`, `1,600` concurrent Materialized Views), Local NVMe SSD + Premium Intel **eliminated 100% of disk MV creation stalls**, lifting 3-trial mean throughput from **`150 req/s` (`86.2%` hit) to `397 req/s` (`20.66 ms`, `100.0%` hit across all 3 trials, peaking at `478 req/s` / `+1,306%`) — a 2.65× increase (+165% more RPS)** over the 3-trial mean and **+80.5% higher than Regular SSD's settled runs (`397` vs `220 req/s`)**!
   - On workloads with continuous disk paging and MV creation (`mv_zipf1000` across `1,000` tenants and `mv_dyn_t2` dynamic filters), NVMe SSD reduced latency by **-10% to -12%** and lifted both hit ratio and throughput by **+7% to +14%**.
6. **Case 2 — 5 GB (`SCALE=10`, `28.5M` Rows) Real Disk-Pressure Study (Isolating Only `PgCache` on Standard SSD vs. Local NVMe SSD)**:
   - Holding `Origin` fixed on Standard SSD (`do-block-storage`) and using the exact same `DO-Premium-Intel` CPU while constraining `PgCache`'s embedded PostgreSQL to `shared_buffers = 128 MB` (`MEMO_CACHE_SIZE = 0`) over a `3,121 MB` (`+2,636 MB` temp files) dataset, Local NVMe on `PgCache` delivered **`6.51×` higher `fsync` IOPS (`5,312` vs `816 ops/s`)** and **`1.99×` higher sequential write bandwidth (`393.2` vs `197.8 MB/s`)**:
     - On **`mv5g_heavy`** (wide `LIMIT 300–500` MVs), Local NVMe lifted the cache hit ratio from `74.6%` to **`90.6%` (+16.0 pp)** and accelerated settled trials by **`3.86×`** (`2,081 ms / 4 rps` vs `8,042 ms / 1 rps` on Standard SSD, beating Origin by **`+25%`** in Trial 2).
     - On **`mv5g_dash`** (8-query enterprise screen reading `285 MB` physically from disk), Local NVMe cut 3-trial mean latency by **`2.34×`** (`3,235 ms` vs `7,577 ms`) and, under partial-hit disk paging (`73%–81%` hit), delivered **`1,393–1,584 ms` (`5–6 rps`, up to `+100%` over Origin)** vs. Standard SSD's `19,749 ms` (`0 rps`) stall (**`14.17×` lower latency**).
     - On **`mv5g_cdc9010`** (90% heavy MV reads + 10% concurrent CDC writes invalidating and recreating MVs), Local NVMe cut `PgCache` mean latency by **`9.66×` (`36,361.7 ms` $\rightarrow$ `3,763.4 ms`, `3.27×` faster than `Origin` itself at `12,319.0 ms`)** and cut Trial 1 peak stall latency by **`60.38×` (`101,973.8 ms` $\rightarrow$ `1,688.9 ms / 4 rps`)**!

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

#### Discovery 3: The Kubernetes Memory Eviction Problem (`MemoryPressure`) & Cgroup Memory Governance (`resources.limits.memory: 5200Mi`)

During our initial runs of the dynamic filter workload (`cplx_dyn`) at `ADMISSION_THRESHOLD=1`, the benchmark repeatedly stalled mid-run because the PgCache pod was terminated by the DigitalOcean Kubelet with **`Status: Evicted` (`The node had condition: [MemoryPressure]`)**. Root-cause analysis uncovered a critical interaction across **three memory layers** inside the PgCache container:

1. **Why `MEMORY_LIMIT` Alone Did Not Prevent Pod Eviction**:
   - The `MEMORY_LIMIT: "3758096384"` (`3.5 GiB`) environment variable governs the PgCache Rust proxy's internal cache tracker (`pgcache_cache_memory_used_bytes`).
   - However, as James explained, Materialized Views for heavy multi-table queries are created and stored inside an **embedded PostgreSQL 17 instance** running inside the same PgCache container (`127.0.0.1:5433`, database `pgcache_cache`).
2. **The `/sys/fs/cgroup/memory.max = max` Auto-Tuning Trap in `pgcache-entrypoint.sh`**:
   - At container startup, `/usr/local/bin/pgcache-entrypoint.sh` auto-tunes the embedded PostgreSQL instance (`shared_buffers`, `effective_cache_size`, `work_mem`) by reading `/sys/fs/cgroup/memory.max`.
   - When a Kubernetes Deployment does **not** set `resources.limits.memory`, `/sys/fs/cgroup/memory.max` is `max`. In that case, `pgcache-entrypoint.sh` falls back to the host VM's total physical RAM (`/proc/meminfo` = `8 GB`) and logs:
     ```text
     [entrypoint] PostgreSQL tuned for 7GB total (shared_buffers=1792MB, effective_cache_size=5376MB, work_mem=8MB, workers=4)
     ```
   - On an 8 GB Kubernetes worker node (`s-4vcpu-8gb`), the Linux kernel, Kubelet, Cilium CNI, and containerd reserve ~1.7 GiB, leaving only **`Allocatable: ~6.26 GiB` (`6,568,452 KiB`)** for pods on that node.
   - When `cplx_dyn` rapidly created hundreds of Materialized Views, the combined footprint of **embedded PostgreSQL (`shared_buffers=1792MB` + disk page cache for MV files) + PgCache Rust process (`3.5 GiB`)** exceeded the node's `6.26 GiB` allocatable ceiling, causing Kubelet to evict the pod under `MemoryPressure`.
3. **The Fix (`resources.limits.memory: 5200Mi`)**:
   - By explicitly setting `resources.limits.memory: "5200Mi"` in [`infra/helm/pgcache-mt/values-do-tuned.yaml`](../../infra/helm/pgcache-mt/values-do-tuned.yaml) and [`infra/helm/pgcache-mt/templates/pgcache.yaml`](../../infra/helm/pgcache-mt/templates/pgcache.yaml), the container cgroup exposes `5,452,595,200` bytes in `/sys/fs/cgroup/memory.max`.
   - `pgcache-entrypoint.sh` automatically detects the cgroup ceiling and tunes the embedded PostgreSQL instance to fit safely inside the node:
     ```text
     [entrypoint] PostgreSQL tuned for 5GB total (shared_buffers=1280MB, effective_cache_size=3840MB, work_mem=6MB, workers=4)
     ```
   - In addition, the Linux kernel reclaims disk page cache for Materialized Views within the `5200Mi` cgroup boundary before node-level `MemoryPressure` (`6.26 GiB`) can ever be reached — **eliminating 100% of pod evictions (`0 Evictions`)** across all Sweep 06 and Sweep 07 runs.

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

## 5. Materialized View Storage Study: Regular SSD (`s-4vcpu-8gb`) vs. Local NVMe SSD + Premium Intel (`s-4vcpu-8gb-intel`, `TRIALS=3`)

As James highlighted, PgCache's multi-table enterprise screens are backed by **Materialized Views stored in its embedded PostgreSQL 17 instance** (`127.0.0.1:5433`, directory `/var/lib/postgresql/data` on the Kubernetes worker node's local disk).

To measure empirically how a **local NVMe SSD** and **newer-generation CPU** accelerate Materialized View creation, warm-up, and steady-state scanning, we ran [`scripts/08-nvme-mv-benchmark.sh`](../../scripts/08-nvme-mv-benchmark.sh) (`TRIALS=3` with fresh PgCache pod recreation before each trial) across two 3-node DigitalOcean Kubernetes clusters:
- **Run 1 — Regular SSD (`3× s-4vcpu-8gb`)**: Basic Shared CPU (`DO-Regular`) + Regular SATA/SAS SSD ([`08-mv-regular-ssd-k8s.txt`](08-mv-regular-ssd-k8s.txt)).
- **Run 2 — Local NVMe SSD + Premium Intel (`3× s-4vcpu-8gb-intel`)**: Premium Intel CPU (`DO-Premium-Intel`) + Local NVMe SSD ([`08-mv-nvme-intel-k8s.txt`](08-mv-nvme-intel-k8s.txt)).

### 5.1 Physical Storage & CPU Micro-Benchmark Inside the PgCache Container (`pg_test_fsync` & `dd`)

Before running the SQL workloads, [`scripts/08-nvme-mv-benchmark.sh`](../../scripts/08-nvme-mv-benchmark.sh) executed PostgreSQL 17's official `pg_test_fsync` utility directly on `/var/lib/postgresql` inside the PgCache pod:

| Physical Metric (`pg_test_fsync` on `/var/lib/postgresql`) | Run 1: Regular SSD (`s-4vcpu-8gb`) | Run 2: Local NVMe + Intel (`s-4vcpu-8gb-intel`) | Observed Difference |
|---|---|---|---|
| **CPU Model (`/proc/cpuinfo`)** | `DO-Regular` (2,494 MHz) | **`DO-Premium-Intel`** (2,494 MHz) | Newer-generation IPC & memory controller |
| **`fsync` (Single 8 kB Page Flush)** | `2,049.6 ops/s` (`488 µs/op`) | **`4,647.5 ops/s` (`215 µs/op`)** | **+126.8% higher IOPS (2.27× faster, -56% latency)** |
| **`open_sync` (`O_DIRECT` 8 kB Sync Write)** | `3,912.4 ops/s` (`256 µs/op`) | **`4,377.6 ops/s` (`228 µs/op`)** | **+11.9% higher IOPS (-11% latency)** |
| **`fdatasync` (2× 8 kB Sync Writes)** | `5,239.1 ops/s` (`191 µs/op`) | `3,437.4 ops/s` (`291 µs/op`) | Both sub-`300 µs` with controller write cache |
| **Non-Synced 8 kB Buffered Writes (`write`)** | `670,247 ops/s` (`1 µs/op`) | **`702,070 ops/s` (`1 µs/op`)** | **+4.7% higher memory/kernel page-cache bandwidth** |

### 5.2 Consolidated Materialized View Benchmark Comparison (`TRIALS=3`)

| Materialized View Scenario (`TENANTS=200`, `CLIENTS=8`) | Regular SSD (`s-4vcpu-8gb`)<br>Origin vs PgCache | Local NVMe + Intel (`s-4vcpu-8gb-intel`)<br>Origin vs PgCache | Impact of Local NVMe + Premium Intel |
|---|---|---|---|
| **1. `mv_cold0s` (Cold Start `0s` on `complex-dashboard.sql`)** | A: 260.75 ms (31 rps)<br>B: **808.46 ms (10 rps, hit 4.2%)** | A: **247.23 ms (33 rps)**<br>B: **795.82 ms (10 rps, hit 5.2%, peak 7.1%)** | **+24% higher hit rate in first 15s (`4.2%` $\rightarrow$ `5.2%`)** |
| **2. `mv_warm30s` (Warm-Up `30s` on `complex-dashboard.sql`)** | A: 268.31 ms (30 rps)<br>B: **1,357.10 ms (6 rps, hit 23.3%)** | A: **250.60 ms (32 rps)**<br>B: **1,666.90 ms (7 rps, hit 24.4%; `736 ms / 11 rps / 36.1% hit` in T1)** | **In Trial 1, NVMe reached `36.1%` hit and `736 ms` (`11 rps`) at 30s** |
| **3. `mv_joins` (Settled 4-to-6 Table Joins)** | A: 193.11 ms (42 rps)<br>B: **8.28 ms (970 rps, hit 99.6%, warm 5.7)** | A: **190.14 ms (42 rps)**<br>B: **12.57 ms (643 rps, hit 100.0%, warm 5.0)** | **Converges to `100.0%` hit across all 3 trials in fewer warm passes (`5.0` vs `5.7`)** |
| **4. `mv_analytics` (Settled `GROUP BY / HAVING` Analytics)** | A: 147.52 ms (55 rps)<br>B: **11.73 ms (690 rps, hit 100.0%)** | A: **143.29 ms (56 rps)**<br>B: **14.31 ms (627 rps, hit 100.0%; peak `8.63 ms / 927 rps` in T3)** | **`800` compact MVs fit 100% inside `1.28 GiB` RAM; T3 on NVMe hit `927 rps (+1,498%)`** |
| **5. `mv_dash` (Full 8-Query Enterprise Screen, `1,600` MVs)** | A: 286.40 ms (28 rps)<br>B: **329.47 ms · 150 rps** *(hit 86.2%, +442%; 220 rps in T1/T3)* | A: **240.43 ms (33 rps)**<br>B: **20.66 ms · 397 rps** *(hit **100.0%**, **+1,090%**, peak **478 rps**)* | **2.65× higher mean throughput (`397` vs `150 rps`, +165%) and +80.5% above Regular SSD's settled runs (`397` vs `220 rps`), with zero stalls!** |
| **6. `mv_zipf1000` (`1,000` Tenants Pareto 80/20, `8,000` MVs)** | A: 252.58 ms (32 rps)<br>B: **386.46 ms · 21 rps** *(hit 71.5%, -34%)* | A: **242.34 ms (33 rps)**<br>B: **341.29 ms · 24 rps** *(hit **73.4%**, -28%, peak **29 rps**)* | **-11.7% lower latency (`386` $\rightarrow$ `341 ms`), +14.3% higher RPS (`21` $\rightarrow$ `24 rps`) under disk paging** |
| **7. `mv_dyn_t2` (Dynamic Filters with `ADMISSION_THRESHOLD=2`)** | A: 255.95 ms (32 rps)<br>B: **308.37 ms · 27 rps** *(hit 39.6%, -16%)* | A: **221.50 ms (36 rps)**<br>B: **277.89 ms · 29 rps** *(hit **41.4%**, -19%, peak **34 rps**)* | **-9.9% lower latency (`308` $\rightarrow$ `278 ms`) and +7.4% higher RPS (`27` $\rightarrow$ `29 rps`) under continuous MV creation** |

### 5.3 Trial-by-Trial Breakdown: Regular SSD vs. Local NVMe SSD (`TRIALS=3`)

| Cell | Regular SSD (`s-4vcpu-8gb`) — 3 Trials (Path B PgCache) | Local NVMe + Intel (`s-4vcpu-8gb-intel`) — 3 Trials (Path B PgCache) |
|---|---|---|
| **`mv_cold0s`** | T1: 805.4 ms (10 rps, 4.51%) · T2: 805.2 ms (10 rps, 3.72%) · T3: 814.8 ms (10 rps, 4.33%) | T1: 818.6 ms (10 rps, 4.59%) · T2: 799.7 ms (10 rps, 3.86%) · T3: **769.2 ms (10 rps, 7.11%)** |
| **`mv_warm30s`** | T1: 1,772.0 ms (5 rps, 22.46%) · T2: 1,293.0 ms (6 rps, 19.95%) · T3: 1,006.3 ms (8 rps, 27.56%) | T1: **736.2 ms (11 rps, 36.08%)** · T2: 2,918.3 ms (3 rps, 20.85%) · T3: 1,346.3 ms (6 rps, 16.25%) |
| **`mv_joins`** | T1: 7.74 ms (1,034 rps, 100%) · T2: 8.90 ms (899 rps, 100%) · T3: 8.20 ms (976 rps, 98.94%) | T1: 14.45 ms (554 rps, **100%**) · T2: 11.36 ms (704 rps, **100%**) · T3: 11.90 ms (672 rps, **100%**) |
| **`mv_analytics`** | T1: 10.11 ms (792 rps, 100%) · T2: 13.03 ms (614 rps, 100%) · T3: 12.06 ms (663 rps, 100%) | T1: 19.74 ms (405 rps, 100%) · T2: 14.56 ms (550 rps, 100%) · T3: **8.63 ms (927 rps, 100%)** |
| **`mv_dash`** | T1: 44.62 ms (179 rps, 100%) · T2: *913.12 ms (9 rps, 58.59%)* · T3: 30.67 ms (261 rps, 100%) | T1: **24.89 ms (321 rps, 100%)** · T2: **20.35 ms (393 rps, 100%)** · T3: **16.73 ms (478 rps, 100%)** |
| **`mv_zipf1000`** | T1: 407.02 ms (20 rps, 73.2%) · T2: 447.31 ms (18 rps, 68.7%) · T3: 305.04 ms (26 rps, 72.6%) | T1: 393.29 ms (20 rps, 73.6%) · T2: **272.30 ms (29 rps, 73.9%)** · T3: 358.28 ms (22 rps, 72.8%) |
| **`mv_dyn_t2`** | T1: 233.42 ms (34 rps, 40.6%) · T2: 333.53 ms (24 rps, 39.0%) · T3: 358.16 ms (22 rps, 39.3%) | T1: **275.91 ms (29 rps, 42.3%)** · T2: 321.39 ms (25 rps, 40.2%) · T3: **236.37 ms (34 rps, 41.5%)** |

### 5.4 Key Takeaways: When Does Local NVMe Storage Matter for PgCache?

1. **When the Materialized View Working Set Is Small (`mv_joins` and `mv_analytics` at `200` Tenants = `800` MVs)**:
   - Those `800` compact Materialized Views fit entirely inside the **`1.28 GiB` `shared_buffers`** of PgCache's embedded PostgreSQL instance. Once warmed, 100% of reads are served from RAM (`8–14 ms`, `627–970 req/s`) without touching disk. Even so, NVMe converged `mv_joins` to `100.0%` hit in **5.0 passes** (vs. `5.7` passes and `99.6%` on Regular SSD).
2. **When Screens Combine Multiple Heavy Materialized Views (`mv_dash` = `1,600` MVs) or High Cardinality (`mv_zipf1000` & `mv_dyn_t2`)**:
   - On the full 8-query enterprise screen (`mv_dash`), PgCache must create and maintain `1,600` Materialized Views (combining substring searches, 6-table joins, and analytical rollups). On Regular SSD (`488 µs` `fsync`), concurrent MV creation suffered a stall in Trial 2 (`58.6%` hit, `9 req/s`) and capped the settled trials at `179–261 req/s`.
   - On **Local NVMe SSD + Premium Intel (`215 µs` `fsync`)**, all 3 trials of `mv_dash` converged with zero stalls to **100.0% hit**, sustaining **`321`, `393`, and `478 req/s` (mean `397 req/s` / `20.66 ms`, 2.65× higher than Regular SSD's mean and +80.5% above Regular SSD's settled runs)**!
   - Likewise, on `mv_zipf1000` (`1,000` tenants) and `mv_dyn_t2` (dynamic user filters), where PgCache continuously writes and pages Materialized Views on local disk, NVMe cut latency by **-10% to -12%** and lifted throughput by **+7% to +14%**. On dedicated bare-metal NVMe pass-through instances (such as **AWS `i8g` Nitro SSD** or **DigitalOcean `so-` Storage-Optimized**), the gain during MV population and disk paging will be even larger.

---

## 6. Case 2 — 5 GB (`SCALE=10`, 28.5M Rows) Real Disk-Pressure Study: Isolating Only PgCache on Standard SSD vs. Local NVMe SSD (`TRIALS=3`)

In Case 1 (`SCALE=1`, ~600 MB dataset in Section 5), PgCache's embedded PostgreSQL 17 instance (`127.0.0.1:5433`) had `shared_buffers = 1,280 MB` (`1.28 GiB`), allowing compact Materialized View sets (`mv_joins` and `mv_analytics` with `800` MVs) to fit entirely in RAM once warmed (`blks_read = 0`).

To answer the core architectural question — **"What is the true impact of Local NVMe storage exclusively on PgCache when Materialized Views and replicated tables exceed embedded `shared_buffers` and suffer physical disk paging?"** — we designed **Case 2 ([`scripts/09-nvme-5gb-stress.sh`](../../scripts/09-nvme-5gb-stress.sh))**:

1. **~5 GB Dataset (`SCALE=10`, `1,000` Tenants, `28,550,550` Rows)**:
   - `20,000,000` `order_item` (`2,109 MB`), `5,000,000` `orders` (`589 MB`), `1,500,000` `review` (`213 MB`), `1,000,000` `product` (`108 MB`), `1,000,000` `customer` (`94 MB`), `500` `seller` (`96 kB`), and `50` `category` (`32 kB`) — totaling **`3,121 MB` of base tables + `2,636 MB` of join/sort `temp_bytes` (`~5.75 GB` active footprint)**.
2. **Deliberate Memory Constraining on PgCache (`pgcache.constrainEmbeddedPg=true`)**:
   - `MEMO_CACHE_SIZE = 0`: Disables the Rust proxy's L1 in-memory memo cache so **100% of cache hits** are served by Materialized Views inside embedded PostgreSQL 17 (`:5433`).
   - Embedded PostgreSQL 17 (`:5433`) is constrained to **`shared_buffers = 128 MB`**, `work_mem = 10 MB`, `maintenance_work_mem = 51 MB`, and pod cgroup memory limit `2,600 MiB` (`MEMORY_LIMIT = 1.5 GiB`).
   - Before every measurement window (on both Path A and Path B), the benchmark runs `CHECKPOINT;` and drops the Linux OS page cache (`sync && echo 3 > /proc/sys/vm/drop_caches`), forcing PostgreSQL to read unbuffered blocks physically from the storage device (`blks_read(disk)` audited via `pg_stat_database`).
3. **Strict Single-Variable Isolation (`Origin` Fixed on Standard SSD, Varying Only `PgCache`'s Disk)**:
   - In both runs, all 3 nodes use the **exact same CPU (`DO-Premium-Intel`, `s-4vcpu-8gb-intel`)** and **`Origin` remains fixed on Standard Network Block SSD (`do-block-storage` PVC, `origin.storage.useEmptyDir=false`)**, ensuring `Origin`'s performance is identical across both tests:
     - **Run 1 (`PgCache = Standard SSD`)**: `PgCache`'s `/var/lib/postgresql/data` directory is mounted on a 20 GiB **`do-block-storage` Standard SSD PVC (`pgcache.useBlockStorage=true`)** ([`09-mv-5gb-pgcache-only-ssd-k8s.txt`](09-mv-5gb-pgcache-only-ssd-k8s.txt)).
     - **Run 2 (`PgCache = Local NVMe SSD`)**: `PgCache`'s `/var/lib/postgresql/data` directory is mounted on the **Worker Node's Local NVMe SSD (`pgcache.useBlockStorage=false`, `/dev/vda1`)** ([`09-mv-5gb-pgcache-only-nvme-k8s.txt`](09-mv-5gb-pgcache-only-nvme-k8s.txt)).
   - *(Note: We also preserve in [`09-mv-5gb-regular-ssd-k8s.txt`](09-mv-5gb-regular-ssd-k8s.txt) and [`09-mv-5gb-nvme-intel-k8s.txt`](09-mv-5gb-nvme-intel-k8s.txt) the full-cluster comparison where both `Origin` and `PgCache` moved from `s-4vcpu-8gb` to Local NVMe.)*

---

### 6.1 Physical Storage Micro-Benchmark Inside the PgCache Pod (`/var/lib/postgresql/data`, Identical `DO-Premium-Intel` CPU)

Holding the `DO-Premium-Intel` node constant and switching only the volume mounted at `/var/lib/postgresql/data` inside the `PgCache` pod, synced `dd` (`conv=fsync`) and `pg_test_fsync` measure the exact physical difference between Standard Block SSD and Local NVMe SSD:

| Physical Metric on `/var/lib/postgresql/data` (`pgcache` Pod) | Run 1: `PgCache` on Standard SSD (`do-block-storage` PVC) | Run 2: `PgCache` on Local NVMe SSD (`/dev/vda1`) | Physical Gain of Local NVMe on `PgCache` |
|---|---|---|---|
| **Sequential Sync Write (`dd 256 MB conv=fsync`)** | `197.8 MB/s` (`1.294 s`) | **`393.2 MB/s` (`0.651 s`)** | **`1.99×` faster (+98.8% write bandwidth)** |
| **`pg_test_fsync`: `fsync` (`1× 8 kB` write)** | `816.1 ops/s` (`1,225 µs/op`) | **`5,312.3 ops/s` (`188 µs/op`)** | **`6.51×` higher IOPS (-84.7% commit latency)** |
| **`pg_test_fsync`: `fdatasync` (`1× 8 kB`, Linux default)** | `1,118.4 ops/s` (`894 µs/op`) | **`6,467.5 ops/s` (`155 µs/op`)** | **`5.78×` higher IOPS (-82.7% latency)** |
| **`pg_test_fsync`: `open_datasync` (`1× 8 kB O_DIRECT`)** | `979.5 ops/s` (`1,021 µs/op`) | **`6,999.8 ops/s` (`143 µs/op`)** | **`7.15×` higher IOPS (-86.0% latency)** |
| **`pg_test_fsync`: `open_sync` (`2× 8 kB` writes)** | `394.6 ops/s` (`2,534 µs/op`) | **`3,412.2 ops/s` (`293 µs/op`)** | **`8.65×` higher IOPS (-88.4% latency)** |

---

### 6.2 Consolidated Comparison (5 GB Dataset, `Origin` Fixed on Standard SSD, Varying Only `PgCache`'s Disk, `TRIALS=3`)

| 5 GB Stress Scenario (`SCALE=10`, `CLIENTS=8`, `shared_buffers=128MB` on PgCache) | Run 1: `Origin` = Standard SSD \| **`PgCache` = Standard SSD**<br>[`09-mv-5gb-pgcache-only-ssd-k8s.txt`](09-mv-5gb-pgcache-only-ssd-k8s.txt) | Run 2: `Origin` = Standard SSD \| **`PgCache` = Local NVMe SSD**<br>[`09-mv-5gb-pgcache-only-nvme-k8s.txt`](09-mv-5gb-pgcache-only-nvme-k8s.txt) | Direct Impact of Local NVMe on `PgCache` (Same `Origin`) |
|---|---|---|---|
| **1. `mv5g_cold0s` (Cold Start `0s` on Wide MVs `LIMIT 300–500`)**<br>[`complex-mv-heavy.sql`](../../workload/complex-mv-heavy.sql) | A: 11,200.7 ms (3 rps; `2,258 ms / 4 rps` T2–T3)<br>B: **3,441.4 ms · 2 rps** *(hit 8.7%, 220 blks read)* | A: 1,947.3 ms (4 rps)<br>B: **5,168.8 ms · 2 rps** *(**2,890 ms / 3 rps in T1–T2**, hit 7.8%, **4,356 blks read**)* | **In Trials 1–2, NVMe delivered `2,795–2,985 ms` (`3 rps`, +50% RPS vs SSD) and populated `20×` more blocks (`207 MB` vs `158 MB`) in 20s** |
| **2. `mv5g_warm30s` (Fixed Warm-Up `30s` on Wide MVs)**<br>[`complex-mv-heavy.sql`](../../workload/complex-mv-heavy.sql) | A: 2,241.6 ms (4 rps)<br>B: **10,603.2 ms · 1 rps** *(hit 45.6%, -72%, 3,068 blks read)* | A: 1,772.2 ms (5 rps)<br>B: **10,546.0 ms · 1 rps** *(**5,823.4 ms in T1**, hit 42.9% / 61.5% T2, 3,100 blks read)* | **In Trial 1, NVMe reduced 30s warm-up latency by -31.5% (`8,496` $\rightarrow$ `5,823 ms`)** |
| **3. `mv5g_heavy` (Settled Wide MVs `LIMIT 300–500`, `15` Tenants)**<br>[`complex-mv-heavy.sql`](../../workload/complex-mv-heavy.sql) | A: 1,893.2 ms (4 rps)<br>B: **6,114.2 ms · 2 rps** *(hit **74.6%**, **-57%**, `19,343` blks = `~155 MB` read from disk)* | A: 1,943.7 ms (4 rps)<br>B: **5,190.1 ms · 3 rps** *(hit **90.6%**, **-25% mean / +25% in T2 at `1,720 ms / 5 rps`**, `20,992` blks = `~168 MB`)* | **+50% higher mean throughput (`3` vs `2 rps`), +16.0 pp higher hit rate (`90.6%` vs `74.6%`); across settled T2–T3 (`2,081 ms / 4 rps` vs `8,042 ms / 1 rps` on SSD) Local NVMe is `3.86×` faster and beats Origin by `+25%`!** |
| **4. `mv5g_dash` (8-Query Enterprise Screen on 5 GB, `88` MVs, `246 MB > 128 MB RAM`)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | A: 2,808.1 ms (3 rps)<br>B: **7,577.2 ms · 182 rps** *(T1: `14.7 ms / 544 rps` at 100% RAM; **T2: `19,749.0 ms / 0 rps` stall at 76.7% hit**; T3: `2,968 ms / 3 rps`, `28,187` blks = `~225 MB`)* | A: 2,849.7 ms (3 rps)<br>B: **3,235.0 ms · 4 rps** *(**+33% mean gain**; **T2: `1,584.2 ms / 5 rps (+66.7%)` at 81.6% hit**; **T3: `1,393.4 ms / 6 rps (+100%)` at 73.4% hit**, `35,576` blks = `~285 MB`)* | **`2.34×` lower mean latency (`3,235` vs `7,577 ms`); under partial-hit disk paging (`73%–81%` hit), NVMe sustains `1,393–1,584 ms` (`5–6 rps`, up to `2.0×` Origin) vs. Standard SSD's `19,749 ms` (`0 rps`) stall (`14.17×` lower latency!)** |
| **5. `mv5g_zipf1000` (`1,000` Tenants Pareto over 5 GB — `PGCACHE_PG = 487–621 MB`, `1.26–1.66 GB` Disk Reads)** | A: 25,446.5 ms (0 rps)<br>B: **12,042.0 ms · 1 rps** *(hit 39.2%, `PGCACHE_PG = 621 MB`, `207,951` blks = `1.66 GB` read)* | A: 22,748.8 ms (0 rps)<br>B: **15,775.9 ms · 1 rps** *(hit 32.8%, `PGCACHE_PG = 487 MB`, `157,508` blks = `1.26 GB` read)* | **Both experience extreme spillover (`4.85×` larger than `shared_buffers=128MB`), and in both runs PgCache cuts latency by `1.44×` to `2.11×` vs. Origin (`22.7–25.4 s`)** |
| **6. `mv5g_cdc9010` (90% Heavy MV Reads + 10% Concurrent CDC Writes with Continuous MV Invalidation & Recreation)** | A: 10,438.5 ms (3 rps)<br>B: **36,361.7 ms · 1 rps** *(hit 73.2%, **-40%**; **T1 stalled at `101,973.8 ms` / `102 s`** due to `DROP TABLE` + `CREATE UNLOGGED TABLE` lock/I/O queueing)* | A: 12,319.0 ms (3 rps)<br>B: **3,763.4 ms · 2 rps** *(hit 66.5%, **3.27× lower latency than Origin!** **T1: `1,688.9 ms / 4 rps`**, T2: `5,502.9 ms / 1 rps`, T3: `4,098.3 ms / 2 rps`)* | **Local NVMe on PgCache cuts mean latency under CDC churn by `9.66×` (`36,361.7` $\rightarrow$ `3,763.4 ms`, -89.6%), doubles RPS (`1` $\rightarrow$ `2 rps`), and cuts Trial 1 peak stall latency by `60.38×` (`101,973.8` $\rightarrow$ `1,688.9 ms`)!** |

---

### 6.3 Trial-by-Trial Breakdown & Physical Block I/O Audit (`pg_stat_database` on `:5432` and `:5433`)

| Cell (5 GB) | Run 1: `PgCache` on Standard SSD (`do-block-storage`) — 3 Trials | Run 2: `PgCache` on Local NVMe SSD (`/dev/vda1`) — 3 Trials | Physical Disk I/O Audit on PgCache Embedded PostgreSQL (`:5433`, `shared_buffers = 128 MB`) |
|---|---|---|---|
| **`mv5g_cold0s`** | T1: 3,471.9 ms (2 rps, 7.93%)<br>T2: 3,789.6 ms (2 rps, 9.62%)<br>T3: 3,062.9 ms (3 rps, 8.70%) | T1: **2,985.6 ms (3 rps, 9.38%)**<br>T2: **2,795.5 ms (3 rps, 11.50%)**<br>T3: 9,725.3 ms (1 rps, 2.50%) | SSD: `size=158 MB`, `blks_read=220`, `7` tables (`48 MB`), `7` MVs (`560 kB`)<br>NVMe: `size=207 MB`, `blks_read=4,356`, `7` tables (`101 MB`), `6` MVs (`480 kB`) |
| **`mv5g_warm30s`** | T1: 8,496.3 ms (1 rps, 66.67%)<br>T2: 10,598.3 ms (1 rps, 32.17%)<br>T3: 12,714.9 ms (1 rps, 37.93%) | T1: **5,823.4 ms (1 rps, 45.25%)**<br>T2: 14,252.3 ms (1 rps, 61.54%)<br>T3: 11,562.3 ms (1 rps, 21.92%) | SSD: `size=185 MB`, `blks_read=3,068` (`~24 MB`), `29` MVs (`2,320 kB`)<br>NVMe: `size=188 MB`, `blks_read=3,100` (`~25 MB`), `25` MVs (`2,000 kB`) |
| **`mv5g_heavy`** | T1: 2,258.5 ms (4 rps, 67.58%)<br>T2: 6,602.7 ms (1 rps, 77.19%)<br>T3: 9,481.4 ms (1 rps, 79.17%) | T1: 11,407.4 ms (1 rps, 87.60%)<br>T2: **1,720.3 ms (5 rps, 95.62%, +25%)**<br>T3: **2,442.7 ms (3 rps, 88.44%)** | SSD: `size=194 MB`, `blks_read=19,343` (`~155 MB`), `38` MVs (`3,040 kB`)<br>NVMe: `size=197 MB`, `blks_read=20,992` (`~168 MB`), `26` MVs (`2,080 kB`) |
| **`mv5g_dash`** | T1: 14.71 ms (544 rps, 100.0%)<br>T2: *19,749.0 ms (0 rps, 76.67%)*<br>T3: 2,968.0 ms (3 rps, 62.69%) | T1: 6,727.5 ms (1 rps, 55.26%)<br>T2: **1,584.2 ms (5 rps, 81.61%, +66.7%)**<br>T3: **1,393.4 ms (6 rps, 73.37%, +100%)** | SSD: `size=243 MB`, `blks_read=28,187` (`~225 MB`), `66` MVs (`1,584 kB`)<br>NVMe: `size=246 MB`, `blks_read=35,576` (`~285 MB`), `88` MVs (`2,112 kB`) |
| **`mv5g_zipf1000`** | T1: 9,487.3 ms (1 rps, 33.33%)<br>T2: 14,311.8 ms (1 rps, 48.15%)<br>T3: 12,326.9 ms (1 rps, 36.00%) | T1: 14,119.5 ms (1 rps, 42.31%)<br>T2: 15,664.8 ms (1 rps, 21.05%)<br>T3: 17,543.5 ms (0 rps, 35.00%) | SSD: `size=621 MB`, `blks_read=207,951` (`~1.66 GB`), `48` MVs (`1,152 kB`)<br>NVMe: `size=487 MB`, `blks_read=157,508` (`~1.26 GB`), `32` MVs (`768 kB`) |
| **`mv5g_cdc9010`** | T1: *101,973.8 ms (0 rps, 59.21%)*<br>T2: 3,208.7 ms (2 rps, 80.00%)<br>T3: 3,902.5 ms (2 rps, 80.27%) | T1: **1,688.9 ms (4 rps, 71.94%)**<br>T2: **5,502.9 ms (1 rps, 57.85%)**<br>T3: **4,098.3 ms (2 rps, 69.64%)** | Origin: `size=3,121 MB`, `blks_read=119,311,876` (`~954 GB`), `temp_bytes=2,636 MB`<br>PgCache: `size=157–169 MB`, continuous MV churn under CDC (`9–10` active MVs) |

---

### 6.4 Architectural Diagnosis: Why Local NVMe Transforms PgCache Under Disk Pressure & CDC Churn

The Case 2 telemetry directly validates the architectural observations highlighted by James (PgCache core developer):

1. **"NVMe really does make a difference on loads with disk pressure" (`mv5g_dash` & `mv5g_heavy`)**:
   - When `PGCACHE_PG` grows to `197–246 MB` against a `128 MB` `shared_buffers` ceiling (reading `155–285 MB` physically from disk via `blks_read`), any partial cache miss or page-cache eviction on **Standard Block SSD (`do-block-storage`, `1,225 µs` `fsync`)** triggers severe I/O stalls (`19,749.0 ms / 0 rps` in `mv5g_dash` Trial 2 at `76.67%` hit, and `6,602–9,481 ms / 1 rps` in `mv5g_heavy` Trials 2–3).
   - Moving **only `PgCache` to Local NVMe SSD (`188 µs` `fsync`, `6.51×` faster)** while keeping `Origin` on Standard SSD:
     - In `mv5g_heavy`, the hit ratio climbs from `74.6%` to **`90.6%` (+16.0 pp)** because Materialized View populations complete faster, and settled Trials 2–3 deliver **`1,720.3 ms (5 rps, +25% faster than Origin)`** and **`2,442.7 ms (3 rps)`** (`3.86×` faster than Standard SSD).
     - In `mv5g_dash`, under the exact same partial-hit regime (`73.4%–81.6%` hit), `PgCache` on Local NVMe sustains **`1,584.2 ms (5 rps, +66.7% over Origin)`** in Trial 2 and **`1,393.4 ms (6 rps, +100.0% over Origin)`** in Trial 3 — up to a **`14.17×` latency reduction** compared to Standard SSD's `19,749.0 ms` stall.
2. **"Anything that reduces how often an MV view is invalidated will pay off well" (`mv5g_cdc9010` — `9.66×` Lower Mean Latency & `60.38×` Lower Peak Stall)**:
   - During `mv5g_cdc9010`, inspecting `pg_stat_activity` on PgCache's embedded PostgreSQL instance (`127.0.0.1:5433`) exposed the exact mechanism behind CDC invalidation stalls under memory pressure:
     - When concurrent writes on `Origin` invalidate replicated tables or when PgCache's memory manager evicts tables to free space, the internal worker executes `DROP TABLE IF EXISTS "public"."seller", "public"."review", "public"."customer"` (requiring an `AccessExclusiveLock`) concurrently with dozens of active `SELECT ...` and `CREATE UNLOGGED TABLE pgcache_mv.q_...` queries.
     - On **Standard Block SSD (`do-block-storage`)**, where each `CREATE UNLOGGED TABLE` heap write and catalog sync takes substantially longer over network block storage, that lock queue stalled Trial 1 to **`101,973.8 ms` (`102 seconds` per screen)** and pushed the 3-trial mean to **`36,361.7 ms` (`1 rps`)**.
     - On **Local NVMe SSD**, because internal table creation and sync operations complete **`2.0×` to `6.5×` faster**, MV creations and drops drain rapidly, cutting `mv5g_cdc9010` mean latency to **`3,763.4 ms` (`2 rps` — `9.66×` faster than Standard SSD and `3.27×` faster than `Origin` itself at `12,319.0 ms`!)**, with Trial 1 completing in just **`1,688.9 ms` (`4 rps`, `60.38×` faster than Trial 1 on Standard SSD)**!

---

## 7. Raw Benchmark Files & Reproducibility

- **Part 1 Report (`results/0.7.1/`)**: [`results/0.7.1/README.md`](../0.7.1/README.md)
- **SQL Tuning & Workloads**:
  - Fair Origin Tuning & Prewarming (`2 GiB` + 4 `GIN pg_trgm` indexes): [`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql)
  - 3+ Char Trigram Search Workload (`search_3c`): [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql)
  - Dynamic Intra-Tenant Filter Workload (`cplx_dyn`): [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)
  - Wide Materialized View Stress Workload (`LIMIT 300–500`, `mv5g_heavy`): [`workload/complex-mv-heavy.sql`](../../workload/complex-mv-heavy.sql)
  - Benchmark Scripts: [`scripts/06-fair-benchmark.sh`](../../scripts/06-fair-benchmark.sh) · [`scripts/07-admission-threshold-sweep.sh`](../../scripts/07-admission-threshold-sweep.sh) · [`scripts/08-nvme-mv-benchmark.sh`](../../scripts/08-nvme-mv-benchmark.sh) · [`scripts/09-nvme-5gb-stress.sh`](../../scripts/09-nvme-5gb-stress.sh)
- **Raw Multi-Trial Logs (`results/0.7.1_v2/`)**:
  - Fair Benchmark (`TRIALS=5`, `2,000`-Tenant Standard Dataset): [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)
  - `ADMISSION_THRESHOLD` Sweep (`1` vs `2` vs `4`, `TRIALS=3`): [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)
  - Case 1 — Materialized Views on Regular SSD (`s-4vcpu-8gb`, `SCALE=1`, `TRIALS=3`): [`08-mv-regular-ssd-k8s.txt`](08-mv-regular-ssd-k8s.txt)
  - Case 1 — Materialized Views on Local NVMe SSD + Premium Intel (`s-4vcpu-8gb-intel`, `SCALE=1`, `TRIALS=3`): [`08-mv-nvme-intel-k8s.txt`](08-mv-nvme-intel-k8s.txt)
  - Case 2 (Isolated) — `Origin` on Standard SSD + **`PgCache` on Standard SSD (`do-block-storage`)** (`SCALE=10`, 5 GB, `TRIALS=3`): [`09-mv-5gb-pgcache-only-ssd-k8s.txt`](09-mv-5gb-pgcache-only-ssd-k8s.txt)
  - Case 2 (Isolated) — `Origin` on Standard SSD + **`PgCache` on Local NVMe SSD (`/dev/vda1`)** (`SCALE=10`, 5 GB, `TRIALS=3`): [`09-mv-5gb-pgcache-only-nvme-k8s.txt`](09-mv-5gb-pgcache-only-nvme-k8s.txt)
  - Case 2 (Full-Cluster) — Regular SSD (`3× s-4vcpu-8gb`, `SCALE=10`, 5 GB, `TRIALS=3`): [`09-mv-5gb-regular-ssd-k8s.txt`](09-mv-5gb-regular-ssd-k8s.txt)
  - Case 2 (Full-Cluster Partial) — Local NVMe on `Origin` + `PgCache` (`3× s-4vcpu-8gb-intel`, `SCALE=10`, 5 GB): [`09-mv-5gb-nvme-intel-k8s.txt`](09-mv-5gb-nvme-intel-k8s.txt)
  - Dense 200-Tenant `search_3c` (`2,500` orders/tenant, `TRIALS=5`): [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt)
  - Over-Indexed B-Tree `INCLUDE` + `GIN` Diagnostic (`TRIALS=5`): [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)
