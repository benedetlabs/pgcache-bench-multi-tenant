# Benchmarking PgCache 0.7.1 in a Multi-Tenant SaaS: What Actually Happens on a 3-Node Cloud Cluster

> 🇧🇷 **[Ler em português](README-pt.md)**

When someone shows you a database cache benchmark, the numbers usually look too good to be true. Often, that is because the test ran on a single laptop where the client, the cache, and the database shared the same CPU and talked over localhost in microseconds — or because the benchmark only tested a single tenant running trivial primary-key lookups.

This report documents what happens when we put **PgCache 0.7.1** in front of **PostgreSQL 17** under realistic multi-tenant SaaS conditions:
- **Real network separation**: 3 dedicated Kubernetes nodes on DigitalOcean (`s-4vcpu-8gb`, one physical VM for PostgreSQL, one for PgCache, and one for the load generator). Local Docker is used strictly to test SQL correctness, never to publish performance numbers.
- **Real SaaS screens**: From a lightweight 8-query operational dashboard up to heavy enterprise screens with substring text search (`ILIKE '%...%'`), 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains, and multi-dimensional `GROUP BY` analytics.
- **No single-run luck**: Every scenario in our multi-trial suite was executed **5 independent times (`TRIALS=5`)**, destroying and recreating all pods (`origin`, `pgcache`, and `loadgen`) before every single run so we can see both the **average speedup** and the **real-world variation** between runs.

---

## 1. The TL;DR (In Plain English)

1. **Zero Wrong Answers**: Before measuring speed, our automated verification script ([`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh)) compares every query result byte-for-byte between PostgreSQL and PgCache. All **8 baseline queries** and all **12 complex queries** returned 100% identical rows — before and after live `UPDATE` and `INSERT` mutations.
2. **Simple Queries vs. Heavy Queries (1.9× vs. 29× Faster)**:
   - On our **lightweight operational dashboard** (`dashboard.sql`), PostgreSQL is already fairly fast (~58 ms for 8 queries), so PgCache roughly **doubles throughput (+98%, from 146 to 273 req/s)**.
   - On **heavy multi-table screens** (4-to-6 table joins, text searches, and analytical rollups), PostgreSQL bogs down scanning and joining rows (130 to 308 ms per screen). PgCache pre-computes these results into in-memory Materialized Views and answers the entire screen in **7 to 23 ms** — delivering **15× to 29× more throughput (+1,400% to +2,839%)**.
3. **Why Real-World 80/20 Traffic Saves Large Multi-Tenant Clusters**:
   - If 1,000+ tenants hit heavy queries with a flat, uniform random distribution from a cold start, the cache spends all its time populating cold tenants.
   - Real SaaS traffic follows the **Pareto 80/20 rule** (20% of tenants generate 80% of traffic). Under an 80/20 Zipfian distribution across **2,000 tenants**, the active tenants quickly settle into cache (**64.1% hit ratio**) and PgCache maintains a positive lead even from a cold start.
4. **Where It Hurts (Cold Start Under Heavy Writes)**:
   - When the cache is already warm, it handles 5%–10% `UPDATE` traffic well (**63%–75% hit ratio**).
   - However, if you restart the cache **completely cold** while simultaneously bombarding the database with both `UPDATE orders` and `INSERT INTO order_item`, continuous replication invalidations fight against initial cache population, dropping throughput below uncached PostgreSQL (**-85%**). **Lesson**: warm your read working set before cutting over heavy mixed read/write traffic.

---

## 2. How to Read the Numbers

Every "request" in this benchmark is not a single SQL statement — it is a **complete SaaS screen render** made of **4 to 8 sequential SQL queries** executed one after another:
- **Path A (PostgreSQL Direct)**: The application talks straight to PostgreSQL.
- **Path B (PgCache 0.7.1)**: The application talks to PgCache.
- **RPS (Requests/sec)**: How many full SaaS screens the system completed per second with 8 concurrent clients.
- **Variation (`-Δ/+Δ` and `sd`)**: Across 5 full pod recreations, `-Δ/+Δ` shows how far the worst and best runs drifted from the average, and `sd` is the standard deviation.

---

## 3. Multi-Trial Results: 5 Runs with Full Pod Recreation (`TRIALS=5`)

In this suite, before every single trial, our script wiped any test inserts and restarted the PostgreSQL pod, the PgCache pod, and the loadgen pod from scratch.

Raw logs: [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt) · [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt) · [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)

| What We Tested (200 Tenants, 8 Clients) | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Cache Hit Rate | Average Speedup (5-Run Spread) |
|---|---|---|---:|---|
| **Lightweight Operational Dashboard** (`dashboard.sql`, 8 queries) | 57.8 ms · **146 req/s** *(±40.5 sd)* | **29.4 ms · 273 req/s** *(±16.3 sd)* | **100.0%** | **1.98× faster (+98%)** *(-68% / +69%)* |
| **Substring Text Search** (`complex-search.sql`, 4 `ILIKE` + joins) | 129.6 ms · **63 req/s** *(±9.2 sd)* | **6.9 ms · 1,170 req/s** *(±126.1 sd)* | **100.0%** | **18.8× faster (+1,778%)** *(-266% / +243%)* |
| **Deep 4-to-6 Table Joins** (`complex-joins.sql`, `INNER` & `LEFT JOIN`) | 238.9 ms · **34 req/s** *(±2.8 sd)* | **8.2 ms · 991 req/s** *(±160.6 sd)* | **100.0%** | **29.4× faster (+2,839%)** *(-666% / +443%)* |
| **Multi-Dimensional Analytics** (`complex-analytics.sql`, `GROUP BY / HAVING`) | 175.3 ms · **46 req/s** *(±4.1 sd)* | **9.0 ms · 905 req/s** *(±122.1 sd)* | **100.0%** | **19.8× faster (+1,883%)** *(-395% / +267%)* |
| **Full Enterprise Screen (Uniform)** (`complex-dashboard.sql`, 8 heavy queries) | 307.5 ms · **26 req/s** *(±1.2 sd)* | **23.4 ms · 389 req/s** *(±132.6 sd)* | **100.0%** | **15.0× faster (+1,400%)** *(-766% / +684%)* |
| **Full Enterprise Screen (80/20 Pareto, 200 Tenants)** (`complex-dashboard-zipfian.sql`) | 339.2 ms · **24 req/s** *(±4.1 sd)* | **76.0 ms · 267 req/s** *(±191.3 sd)* | **97.5%** | **11.5× faster (+1,051%)** *(-1,016% / +917%)* |
| **Full Enterprise Screen (80/20 Pareto, 2,000 Tenants)** (`complex-dashboard-zipfian.sql`) | 373.1 ms · **22 req/s** *(±1.9 sd)* | **351.2 ms · 24 req/s** *(±5.4 sd)* | **64.1%** | **1.09× faster (+9%)** *(-26% / +30%)* |
| **Cold-Start + 5% Live Writes (`UPDATE` + `INSERT`)** (`complex-dashboard` + `write.sql`) | 327.9 ms · **25 req/s** *(±2.7 sd)* | 2,995.5 ms · **3 req/s** *(±2.6 sd)* | **32.4%** | **0.15× (-85% slower)** *(-8% / +23%)* |

### What These 5-Run Numbers Tell Us

- **Why the gap between simple and complex queries is so wide**: Across 3 separate cloud VMs, every SQL query pays ~0.7 ms just to cross the network. An 8-query screen pays **~5.6 ms of pure network travel** no matter how fast the database is. On the lightweight dashboard (`57.8 ms` on PostgreSQL), network travel and basic SQL parsing eat up half the potential savings, so PgCache gives you **+98%**. On the 4-to-6 table joins (`238.9 ms` on PostgreSQL), PgCache's Materialized Views turn expensive join trees into a single fast lookup (`8.2 ms`), jumping to **29.4× faster (+2,839%)**.
- **Why we fixed two queries in `dashboard.sql`**: In earlier runs, two queries in `dashboard.sql` calculated expressions inline (`OFFSET :off * 20` and `(ARRAY[...])[:st]`). PgCache treated those two queries as uncacheable and forwarded them to PostgreSQL, capping baseline throughput around ~128 req/s. Pre-computing those values into plain parameters brought the hit rate to a true **100.0%** and lifted Path B to **273 req/s (+98%)**.
- **Why running 5 trials matters**: In the 200-tenant Zipfian test, 4 out of 5 trials hit **99.3%–100% cache hit rates (166 to 472 req/s)**, while Trial 4 settled slightly early at **88.3% (31 req/s)**. A single benchmark run could have reported 472 req/s or 31 req/s by pure chance; running 5 fresh trials reveals both the true average (**267 req/s, 11.5× faster**) and the warm-up variance.

---

## 4. Deep Dive: Single-Pass Scaling Sweeps on 3-Node DOKS

In addition to the 5-trial suite above, we ran full scaling sweeps across tenant count, client concurrency, and write ratios on the 3-node DOKS cluster.

### 4.1 Scaling Active Tenants on the Lightweight Dashboard (`1` to `2,000` Tenants)

Does multiplying the query space by 2,000 tenants break the cache on simple queries? No — once warm, PgCache maintains a **100.0% hit ratio** all the way to 2,000 tenants.

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

### 4.2 Scaling Active Tenants on the Heavy Enterprise Screen (`1` to `1,000` Uniform Tenants)

On the heavy 8-query enterprise screen (`complex-dashboard.sql`), each tenant registers 8 multi-table Materialized Views. Up to **500 active tenants (4,000 views)**, PgCache warms 100% of the working set and delivers **12× to 22× higher throughput**.

Raw log: [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)

| Active Tenants (Uniform) | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Speedup | Hit Ratio | Warm-up Passes |
|---:|---|---|---:|---:|---:|
| **1** | 206.8 ms · 39 req/s | **9.2 ms · 871 req/s** | **22.3× (+2,133%)** | 100.0% | 2 |
| **10** | 198.2 ms · 40 req/s | **9.6 ms · 835 req/s** | **20.9× (+1,988%)** | 100.0% | 2 |
| **50** | 227.5 ms · 35 req/s | **10.8 ms · 740 req/s** | **21.1× (+2,014%)** | 100.0% | 6 |
| **200** | 212.8 ms · 38 req/s | **11.2 ms · 712 req/s** | **18.7× (+1,774%)** | 100.0% | 7 |
| **500** | 223.9 ms · 36 req/s | **18.4 ms · 435 req/s** | **12.1× (+1,108%)** | 100.0% | 8 |
| **1,000** *(8-pass warm cap)* | 210.1 ms · 38 req/s | 251.4 ms · 32 req/s | 0.84× (-16%) | 68.1% | 4 |

> **Why 1,000 uniform tenants slows down (and why Section 3 tested 2,000 Zipfian tenants)**: When 1,000 tenants are picked with uniform probability during short 15-second passes, the cache has to build 8,000 heavy Materialized Views all at once, reaching 68.1% hit rate before the warm-up cap stops. When traffic follows a realistic 80/20 Pareto distribution (`z_tenants=2000` in Section 3), the hot tenants warm up first and keep PgCache ahead even at **2,000 tenants**.

---

### 4.3 Scaling Concurrent Users (`1` to `32` Clients on the Heavy Enterprise Screen)

What happens when traffic spikes from 1 user to 32 simultaneous users?
- At **1 client**, there is no CPU queueing anywhere: PgCache answers a 100.6 ms screen in **7.1 ms (14.0× faster)**.
- At **32 clients**, PostgreSQL's 4 vCPUs saturate at **38 req/s** and response time climbs to **835.5 ms** (nearly a full second per page). PgCache absorbs the read load from memory, serving **1,020 screens/sec (over 8,160 complex SQL queries/sec)** at **31.4 ms (26.8× faster)**.

Raw log: [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)

| Concurrent Clients | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Speedup | Hit Ratio |
|---:|---|---|---:|---:|
| **1** | 100.6 ms · 10 req/s | **7.1 ms · 140 req/s** | **14.0× (+1,300%)** | 100.0% |
| **4** | 129.5 ms · 31 req/s | **8.6 ms · 465 req/s** | **15.0× (+1,400%)** | 100.0% |
| **8** | 212.8 ms · 38 req/s | **10.5 ms · 763 req/s** | **20.1× (+1,908%)** | 100.0% |
| **16** | 406.9 ms · 39 req/s | **18.1 ms · 886 req/s** | **22.7× (+2,172%)** | 100.0% |
| **32** | 835.5 ms · 38 req/s | **31.4 ms · 1,020 req/s** | **26.8× (+2,584%)** | 100.0% |

---

### 4.4 What Happens When Data Changes? (Warm Cache vs. Live Writes)

When the cache is **warmed first** and then subjected to 5% or 10% write traffic (`UPDATE orders`), we see an interesting split inside the 8-query enterprise screen:
- **5 of the 8 queries (`62.5%`) use `INNER JOIN`**: Because they filter directly on `WHERE o.tenant_id = :t`, PgCache updates the affected tenant's data in-place via PostgreSQL logical replication (CDC) and rebuilds only that tenant's view in the background. These queries stay **100% cache hits**.
- **3 of the 8 queries (`37.5%`) use `LEFT JOIN`**: To preserve customers who have zero orders (`LEFT JOIN orders o ON ... AND o.tenant_id = :t`), the tenant filter sits inside the outer join's `ON` clause. Whenever `orders` changes, PgCache conservatively invalidates those 3 outer-join queries.

As a result, the overall cache hit rate settles right around **63% to 75%**:

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

## 5. Correctness Gate Summary (3-Stage Verification)

Before trusting any performance number, [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) runs three strict checks ([`verify-correctness-doks.txt`](verify-correctness-doks.txt)):

| Stage | What It Verifies | Result on 3-Node DOKS |
|---|---|---|
| **Stage 1: Baseline Queries (8/8)** | Runs all 8 queries from `dashboard.sql` against PostgreSQL and PgCache and compares every row byte-for-byte. | **PASS (8/8 identical, 0 uncacheable)** |
| **Stage 2: Complex Static Queries (12/12)** | Runs all 12 complex queries across 3 passes (cold miss, base-table hit, and warm Materialized View hit). | **PASS (12/12 identical, 100% MV hit rate)** |
| **Stage 3: Live CDC Mutation (`UPDATE` + `INSERT`)** | Executes live `UPDATE orders`, `UPDATE order_item`, and `INSERT INTO order_item` on PostgreSQL, waits for CDC replication, and re-verifies all 12 complex queries on PgCache. | **PASS (12/12 identical after live writes)** |

---

## 6. Raw Benchmark Files & Logs

- **5-Trial Multi-Run Logs (with Full Pod Recreation)**:
  - Complex Scenarios (`TRIALS=5`): [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)
  - Pareto/Zipfian 80/20 (`TRIALS=5`): [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)
  - Cold-Start `UPDATE + INSERT` Writes (`TRIALS=5`): [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)
- **Single-Pass Scaling & Verification Logs (3-Node DOKS)**:
  - Correctness Gate Output: [`verify-correctness-doks.txt`](verify-correctness-doks.txt)
  - Baseline Tenant Sweep (`1..2000`): [`run-tenants-doks.txt`](run-tenants-doks.txt) · [`results-doks.tsv`](results-doks.tsv)
  - Complex Scenario Comparison: [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt) · [`results-complex-doks.tsv`](results-complex-doks.tsv)
  - Complex Tenant Scaling (`1..1000`): [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)
  - Complex Concurrency Scaling (`1..32` clients): [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)
  - Complex Warm-Cache Write Sweep: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)
