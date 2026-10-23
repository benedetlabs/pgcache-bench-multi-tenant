# PgCache 0.8.0 Multi-Tenant SaaS Benchmark: Outer Join Subsumption, Column-Level CDC Invalidation & `pgcache_cache_subsumptions` Warm-Up Curve (`0.8.0` vs. `0.7.1`)

> 🇧🇷 **[Ler em português](README-pt.md)** · 📖 **[Read Part 1 (`0.7.1`)](../0.7.1/README.md)** · 📖 **[Read Part 2 (`0.7.1_v2`)](../0.7.1_v2/README.md)**

This report documents the complete evaluation of **PgCache `0.8.0` (`pgcache/pgcache:0.8.0`)** in direct comparison against **`0.7.1` / `0.7.1_v2`** on our 3-node DigitalOcean Kubernetes cluster (`3× s-4vcpu-8gb` in `nyc1`, `TRIALS=3` with full PgCache pod recreation between trials).

In addition to repeating all official benchmark sweeps (`01` through `04`, `06`, `07`, and `verify-correctness.sh`), we created and ran **[`10-subsumption-curve.sh`](../../scripts/10-subsumption-curve.sh)** — suggested by **James (PgCache core developer)** — to measure the step-by-step warm-up curve (`8 × 15s = 120s`) of **`pgcache_cache_subsumptions`** comparing `0.8.0` against `0.7.1`.

---

## 1. What Changed in PgCache 0.8.0 and Why It Matters for Multi-Tenant SaaS

According to the [PgCache 0.8.0 Changelog](https://www.pgcache.com/docs/changelog/), four core changes directly address bottlenecks we measured in `0.7.1` and `0.7.1_v2`:

1. **Selective Column-Level `UPDATE` Invalidation (*Skip redundant cache invalidations when UPDATE does not modify any column referenced by a cached query*)**:
   - In `0.7.1`, any `UPDATE` on `orders` invalidated all cached queries for that tenant touching `orders`, even when the modified column was not referenced by the query's `SELECT`, `WHERE`, or `GROUP BY` clauses.
   - In `0.8.0`, the CDC tracker inspects which columns were actually modified by the WAL tuple before triggering cache invalidations.
2. **Subsumption for Single-Table Queries Against Outer Join Views (*Subsumption for single-table queries against outer join views*)**:
   - Single-table queries whose table is the preserved relation of a `LEFT JOIN` Materialized View can now be **subsumed** directly by that view, avoiding redundant Origin queries during warm-up.
3. **Extended Subsumption Predicate Support (`LIKE / ILIKE` and `IS NULL / IS NOT NULL`)**:
   - The subsumption engine now evaluates `LIKE` / `ILIKE` patterns and `IS NULL` / `IS NOT NULL` predicates when checking whether a newly registered query can be satisfied from an already cached result set.
4. **Reduced Lock Contention on the Hot Path**:
   - The cache writer's table registration switched from `RwLock` to a concurrent `DashMap`, and read-side table invalidation clock resolution was moved outside the exclusive cache lock — substantially reducing contention between background population/subsumption checks and concurrent reader connections.

---

## 2. Executive Summary (TL;DR): `0.8.0` vs. `0.7.1_v2`

| Evaluated Axis (3-Node DOKS `3× s-4vcpu-8gb`, `TRIALS=3`) | PgCache `0.7.1` / `0.7.1_v2` | PgCache `0.8.0` | Evolution (`0.8.0` vs. `0.7.1_v2`) |
|---|---|---|---|
| **Correctness Gate + Post-CDC Invalidations** ([`verify-correctness-doks.txt`](verify-correctness-doks.txt)) | `32/32 PASS` · **`12` invalidations** | `32/32 PASS` · **`3` invalidations** | **-75% redundant CDC invalidations** |
| **Operational Dashboard at `1,000` Tenants** ([`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt)) | 332.93 ms · `24 rps` (`62.5%` hit) | **149.08 ms · `55 rps` (`88.1%` hit)** | **2.29× faster (+25.6 pp hit ratio)** |
| **Operational Dashboard at `2,000` Tenants** ([`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt)) | 882.23 ms · `9 rps` (`20.6%` hit) | **196.26 ms · `42 rps` (`49.2%` hit)** | **4.67× faster (+28.6 pp hit ratio)** |
| **Concurrency `c=1` (`200` Tenants)** ([`02-concurrency-sweep-k8s.txt`](02-concurrency-sweep-k8s.txt)) | 63.36 ms · `16 rps` (`62.3%` hit, `-64%`) | **14.81 ms · `68 rps` (`99.9%` hit, `+34%`)** | **4.25× faster (flipped `-64%` to `+34%`)** |
| **CDC Writes `5%` Across `200` Tenants (`5:200`)** ([`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt)) | 102.49 ms · `82 rps` (`82.3%` hit) | **64.43 ms · `125 rps` (`95.9%` hit)** | **+52.4% higher RPS (`4.3×` fewer CDC misses)** |
| **CDC Writes `10%` Across `200` Tenants (`10:200`)** ([`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt)) | 121.67 ms · `69 rps` (`78.1%` hit) | **89.86 ms · `90 rps` (`92.7%` hit)** | **+30.4% higher RPS (`3.0×` fewer CDC misses)** |
| **Deep 4–6 Table Joins (`joins`)** ([`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)) | 25.68 ms · `330 rps` (`98.8%` hit) | **10.85 ms · `773 rps` (`100.0%` hit, `+2,710%`)** | **2.34× faster (`100%` hit)** |
| **Full Enterprise Screen (`cplx_dash`)** ([`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)) | 89.85 ms · `128 rps` (`97.9%` hit) | **24.62 ms · `338 rps` (`100.0%` hit, `+1,410%`)** | **2.64× faster (`100%` hit)** |
| **80/20 Pareto at `1,000` Tenants (`z_tenants=1000`)** ([`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)) | 463.82 ms · `18 rps` (`71.0%` hit, `-49%`) | **265.90 ms · `33 rps` (`79.1%` hit, `+53%`)** | **1.83× faster (flipped `-49%` to `+53%`)** |
| **80/20 Pareto at `2,000` Tenants (`z_tenants=2000`)** ([`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)) | 996.55 ms · `8 rps` (`49.9%` hit, `-77%`) | **338.95 ms · `25 rps` (`71.5%` hit, `+27%`)** | **3.13× faster (flipped `-77%` to `+27%`)** |
| **Cold-Reset Heavy Writes (`5:10` Complex Writes)** ([`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)) | 2,995.5 ms · `3 rps` (`32.4%` hit, `-85%`) | **809.01 ms · `10 rps` (`42.4%` hit, `-54%`)** | **3.33× faster (`3.70×` lower latency)** |
| **Fair Benchmark: `search_3c` (`GIN pg_trgm` + `2 GiB`)** ([`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)) | 9.23 ms · `914 rps` (`100.0%` hit, `3.4` warm) | **6.07 ms · `1,319 rps` (`100.0%` hit, `3.0` warm)** | **+44.3% faster (`+1,143%` over Origin)** |
| **Fair Benchmark: `cplx_dash` (`2 GiB` Prewarmed)** ([`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)) | 67.16 ms · `128 rps` (`97.9%` hit) | **16.55 ms · `487 rps` (`100.0%` hit, `+1,728%`)** | **3.80× faster (`0` warm-up stalls)** |
| **`ADMISSION_THRESHOLD=2` Settled (`t2_settle`)** ([`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)) | 75.34 ms · `117 rps` (`98.3%` hit) | **23.03 ms · `369 rps` (`100.0%` hit, `+1,084%`)** | **3.15× faster** |
| **`ADMISSION_THRESHOLD=4` Dynamic Filters (`t4_dyn`)** ([`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)) | 504.14 ms · `16 rps` (`-52%` on v2_3t) | **231.46 ms · `35 rps` (`18.3%` hit, `+8%` vs Origin)** | **2.19× faster (beats Origin by `+8%`!)** |

---

## 3. Special Study for James: `pgcache_cache_subsumptions` Warm-Up Curve (`0.8.0` vs. `0.7.1`)

Full raw log: **[`10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt`](10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt)** · Script: **[`scripts/10-subsumption-curve.sh`](../../scripts/10-subsumption-curve.sh)**

James suggested tracking `pgcache.cache.subsumptions` (exposed in Prometheus as `pgcache_cache_subsumptions` alongside `pgcache_cache_writer_register_subsumption_check_seconds_count`) during warm-up to compare `0.8.0` against `0.7.1`.

We recreated the PgCache pod from scratch (`cold start`) before each scenario and recorded **8 consecutive 15-second windows (`0–120s` continuous warm-up, `CLIENTS=8`)** on the exact same 3-node DOKS cluster for both **`0.8.0`** and **`0.7.1`**, covering 4 scenarios:
1. **`dashboard_200t`**: Operational dashboard (`workload/dashboard.sql`, 11 queries/tenant = `2,200` unique queries across `200` tenants).
2. **`dashboard_1000t`**: High-cardinality operational dashboard (`11,000` unique queries across `1,000` tenants).
3. **`outer_join_plus_base_200t`**: Mixed outer-join + single-table workload (`50%` [`workload/complex-joins.sql`](../../workload/complex-joins.sql) with `LEFT JOIN` over `customer` and `product` + `50%` [`workload/dashboard.sql`](../../workload/dashboard.sql) single-table queries over the preserved relations), specifically testing `0.8.0`'s *"Subsumption for single-table queries against outer join views"*.
4. **`cplx_dyn_200t`**: Enterprise screen with dynamic intra-tenant filters ([`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)).

### 3.1 Scenario 1: `dashboard_200t` (`200` Tenants, `2,200` Unique Queries) — `0.8.0` vs. `0.7.1`

Within `dashboard.sql`, 4 of the 11 statements per tenant (`4 × 200 = 800` queries across 200 tenants) filter subsets of tables already covered by broader queries for the same tenant and are direct candidates for **subsumption** during cache registration:

| Warm-Up Window | `0.7.1` RPS (Latency) | `0.8.0` RPS (Latency) | `0.7.1` Hit % | `0.8.0` Hit % | `0.7.1` `subsumptions` ($\Delta$) | `0.8.0` `subsumptions` ($\Delta$) | `0.7.1` Checks | `0.8.0` Checks |
|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **`0–15s`** | 23 rps (340.8 ms) | 19 rps (412.1 ms) | 16.10% | 16.00% | **42** (+42) | **21** (+21) | 821 | 600 |
| **`15–30s`** | 31 rps (261.9 ms) | **61 rps (132.1 ms)** | 66.59% | **77.52%** | **294** (+252) | **577 (+556)** | 1,581 | **1,990** |
| **`30–45s`** | 97 rps (82.9 ms) | **235 rps (34.0 ms)** | 95.87% | **99.44%** | **679** (+385) | **781 (+204)** | 2,125 | **2,198** |
| **`45–60s`** | 215 rps (37.2 ms) | **263 rps (30.5 ms)** | 99.72% | **99.93%** | **752** (+73) | **783 (+2)** | 2,198 | **2,200** |
| **`60–75s`** | 210 rps (38.1 ms) | **259 rps (30.9 ms)** | 99.93% | **99.98%** | **754** (+2) | **783 (+0)** | 2,200 | 2,200 |
| **`75–90s`** | 247 rps (32.4 ms) | **271 rps (29.5 ms)** | 99.99% | **99.99%** | **754** (+0) | **783 (+0)** | 2,200 | 2,200 |
| **`90–105s`** | 262 rps (30.5 ms) | **301 rps (26.6 ms)** | 100.00% | **100.00%** | **754** (+0) | **783 (+0)** | 2,200 | 2,200 |
| **`105–120s`** | 261 rps (30.7 ms) | **296 rps (27.0 ms)** | 100.00% | **100.00%** | **754** (+0) | **783 (+0)** | 2,200 | 2,200 |

**What the `dashboard_200t` curve shows:**
- In the **`15–30s`** window, `0.8.0` performs **`+556` subsumptions in a single 15s interval** (reaching **`577` cumulative subsumptions**, compared to **`294`** on `0.7.1` — **nearly 2× more subsumptions**) and doubles throughput (`61 rps` vs. `31 rps`).
- By **`30–45s`**, `0.8.0` has completed nearly every possible subsumption (**`781` of `783`**) and reaches **`235 rps` (`99.44%` hit, `34.0 ms`)**, while `0.7.1` is still at `679` subsumptions and `97 rps` (`82.9 ms`) — **`0.8.0` is `2.42×` faster at the 45-second mark**!
- Across the full 2,200 registered queries (`11 queries × 200 tenants`), `0.8.0` subsumes **`783` queries** vs. **`754`** on `0.7.1` (**`+29` additional subsumptions**) and settles at **`296–301 rps` (+15% higher than `0.7.1`)**.

---

### 3.2 Scenario 2: `dashboard_1000t` (`1,000` Tenants, `11,000` Unique Queries) — `0.8.0` vs. `0.7.1`

| Warm-Up Window | `0.7.1` RPS | `0.8.0` RPS | `0.7.1` Hit % | `0.8.0` Hit % | `0.7.1` `subsumptions` ($\Delta$) | `0.8.0` `subsumptions` ($\Delta$) | `0.7.1` Checks | `0.8.0` Checks |
|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **`0–15s`** | 35 rps | 31 rps | 2.99% | **4.42%** | **7** (+7) | **7** (+7) | 816 | **827** |
| **`15–30s`** | 38 rps | **45 rps** | 12.28% | **14.22%** | **58** (+51) | **53** (+46) | 1,648 | **1,709** |
| **`30–45s`** | 37 rps | 36 rps | 21.75% | **28.94%** | **123** (+65) | **293 (+240)** | 2,304 | **3,385** |
| **`45–60s`** | 34 rps | **36 rps** | 30.03% | **39.84%** | **233** (+110) | **467 (+174)** | 3,076 | **4,155** |
| **`60–75s`** | 40 rps | **46 rps** | 36.59% | **48.73%** | **361** (+128) | **596 (+129)** | 3,783 | **4,703** |
| **`75–90s`** | 41 rps | 37 rps | 46.40% | **53.46%** | **503** (+142) | **794 (+198)** | 4,396 | **5,392** |
| **`90–105s`** | 45 rps | 36 rps | 54.12% | **58.10%** | **712** (+209) | **943 (+149)** | 5,115 | **5,895** |
| **`105–120s`** | 41 rps | 40 rps | 61.14% | **70.31%** | **930** (+218) | **1,180 (+237)** | 5,800 | **6,415** |

**What the `dashboard_1000t` curve shows:**
- With `1,000` active tenants, removing lock contention (`DashMap` + reading table clocks outside the exclusive lock) lets `0.8.0`'s cache writer perform **`6,415` subsumption checks in 120s** (vs. `5,800` on `0.7.1`) and complete **`1,180` subsumptions** vs. **`930`** on `0.7.1` (**`+250` subsumptions / `+26.9%`**).
- At the 45-second mark, `0.8.0` has already completed **`2.38×` more subsumptions (`293` vs. `123`)**, and by 120s it reaches a **`70.31%` hit ratio** vs. `61.14%` on `0.7.1` (**`+9.17 pp` higher hit rate**). That directly explains why `01-tenant-sweep.sh` accelerated by **`2.29×` at `1,000` tenants (`55 rps` vs. `24 rps`)** and **`4.67×` at `2,000` tenants (`42 rps` vs. `9 rps`)**!

---

### 3.3 Scenario 3: `outer_join_plus_base_200t` (`LEFT JOIN` + Preserved Single-Table Relation) — `0.8.0` vs. `0.7.1`

When we combine `complex-joins.sql` (`LEFT JOIN` preserving `customer` and `product`, plus `IS NULL / IS NOT NULL`) with `dashboard.sql` (single-table queries on `customer`, `product`, and `orders` across the same `200` tenants):

| Warm-Up Window | `0.7.1` `subsumptions` ($\Delta$) | `0.8.0` `subsumptions` ($\Delta$) | `0.8.0` Subsumption Ramp Advantage |
|:---:|---:|---:|---|
| **`0–15s`** | 2 (+2) | **3 (+3)** | `+50%` |
| **`15–30s`** | 12 (+10) | **29 (+26)** | **`2.42×` more cumulative subsumptions at 30s** |
| **`30–45s`** | 58 (+46) | **86 (+57)** | **`+48.3%` more cumulative subsumptions at 45s** |
| **`45–60s`** | 140 (+82) | **188 (+102)** | **`+34.3%` more cumulative subsumptions at 60s** |
| **`60–75s`** | 298 (+158) | **294 (+106)** | Parity at mid-ramp |
| **`105–120s` (Final)** | **886** (out of 3,000 checks) | **887** (out of 2,851 checks) | **`+104` extra subsumptions over `dashboard_200t` (`887` vs. `783`), higher subsumption/check ratio (`31.1%` vs. `29.5%`)** |

---

### 3.4 Scenario 4: `cplx_dyn_200t` (Dynamic Intra-Tenant Filters on Multi-Table Queries)

In `cplx_dyn_200t` ([`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)), both `0.8.0` (`2,695` `Sub_Checks`) and `0.7.1` (`3,261` `Sub_Checks`) record **`0` `pgcache_cache_subsumptions`** across the 120s ramp.
- **Architectural Reason**: All 8 statements in `complex-dashboard-dynamic.sql` are 3-to-6 table joins and `GROUP BY / HAVING` aggregations served by the **Materialized View (MV)** engine. While `subsumption_check` is invoked on every registration (`2,695` to `3,261` times), distinct multi-table `GROUP BY / HAVING` queries with dynamic `LIMIT` values create independent Materialized Views rather than subsuming base-table memo entries, so `subsumptions` remains `0`.

---

## 4. Detailed Results Across All Sweeps (`01` to `07`) on `0.8.0`

### 4.1 Sweep 1: Tenant Scaling (`1` to `2,000` Tenants — [`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt))

| Tenants (`CLIENTS=8`) | Origin Path A (`0.8.0`) | PgCache `0.7.1_v2` (Path B) | PgCache `0.8.0` (Path B) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---:|---|---|---|---:|---:|---|
| **`1`** | 31.85 ms · 252 rps | 11.57 ms · 692 rps | **9.20 ms · 883 rps** *(±129.8 sd)* | 100.0% → **100.0%** | **+249% (3.50×)** | **+27.6% faster** |
| **`10`** | 29.43 ms · 275 rps | 17.47 ms · 458 rps | **14.42 ms · 573 rps** *(±130.1 sd)* | 100.0% → **100.0%** | **+109% (2.08×)** | **+25.1% faster** |
| **`50`** | 31.06 ms · 259 rps | 16.80 ms · 476 rps | **15.04 ms · 533 rps** *(±32.4 sd)* | 100.0% → **100.0%** | **+107% (2.06×)** | **+12.0% faster** |
| **`100`** | 34.51 ms · 233 rps | 19.21 ms · 416 rps | **21.91 ms · 367 rps** *(±28.1 sd)* | 100.0% → **100.0%** | **+59% (1.58×)** | Warm-up dropped from `5.7` to **`3.3` passes** |
| **`500`** | 39.82 ms · 208 rps | 65.98 ms · 121 rps | **52.96 ms · 153 rps** *(±20.1 sd)* | 99.6% → **99.9%** | -22% (0.74×) | **+26.4% faster** |
| **`1,000`** | 39.58 ms · 205 rps | 332.93 ms · 24 rps | **149.08 ms · 55 rps** *(±9.5 sd)* | 62.5% → **88.1%** | -73% (0.27×) | **2.29× faster (+25.6 pp hit)** |
| **`2,000`** | 38.42 ms · 208 rps | 882.23 ms · 9 rps | **196.26 ms · 42 rps** *(±10.1 sd)* | 20.6% → **49.2%** | -80% (0.20×) | **4.67× faster (+28.6 pp hit)** |

---

### 4.2 Sweep 2: Concurrency Scaling (`1` to `32` Clients Across `200` Tenants — [`02-concurrency-sweep-k8s.txt`](02-concurrency-sweep-k8s.txt))

| Clients (`TENANTS=200`) | Origin Path A (`0.8.0`) | PgCache `0.7.1_v2` (Path B) | PgCache `0.8.0` (Path B) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---:|---|---|---|---:|---:|---|
| **`1`** | 19.83 ms · 51 rps | 63.36 ms · 16 rps (`8.0` warm) | **14.81 ms · 68 rps** (`6.0` warm) | 62.3% → **99.9%** | **+34% (1.33×)** | **4.25× faster (flipped `-64%` to `+34%`)** |
| **`4`** | 18.90 ms · 212 rps | 20.73 ms · 193 rps (`8.0` warm) | **23.47 ms · 173 rps** (`5.0` warm) | 100.0% → **100.0%** | -18% | Warm-up dropped from `8.0` to **`5.0` passes** |
| **`8`** | 32.52 ms · 246 rps | 25.99 ms · 308 rps (`8.0` warm) | **29.36 ms · 272 rps** (`4.7` warm) | 100.0% → **100.0%** | **+11%** | Warm-up dropped from `8.0` to **`4.7` passes** |
| **`16`** | 66.93 ms · 239 rps | 37.59 ms · 426 rps (`6.0` warm) | **43.65 ms · 371 rps** (`4.0` warm) | 100.0% → **100.0%** | **+55% (1.55×)** | Warm-up dropped from `6.0` to **`4.0` passes** |
| **`32`** | 115.27 ms · 280 rps | 73.84 ms · 433 rps (`6.3` warm) | **78.95 ms · 408 rps** (`4.3` warm) | 100.0% → **100.0%** | **+47% (1.46×)** | Warm-up dropped from `6.3` to **`4.3` passes** |

---

### 4.3 Sweep 3: CDC Write Ratio on Operational Dashboard ([`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt))

| `Write % : Target Tenants` | Origin Path A (`0.8.0`) | PgCache `0.7.1_v2` (Path B) | PgCache `0.8.0` (Path B) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`0:200` (0% writes)** | 32.93 ms · 243 rps | 29.74 ms · 269 rps | **26.77 ms · 300 rps** | 100.0% → **100.0%** | **+23%** | **+11.5% faster (`+9%` → `+23%`)** |
| **`5:1` (5% writes, 1 tenant)** | 31.75 ms · 252 rps | 29.77 ms · 269 rps | **26.87 ms · 299 rps** | 99.3% → **99.9%** | **+18%** | **+11.2% faster (`7×` fewer CDC misses)** |
| **`5:10` (5% writes, 10 tenants)** | 28.84 ms · 278 rps | 44.69 ms · 179 rps | **40.22 ms · 201 rps** | 96.2% → **99.2%** | -27% | **+12.3% faster (`4.8×` fewer CDC misses)** |
| **`5:200` (5% writes, 200 tenants)** | 27.09 ms · 298 rps | 102.49 ms · 82 rps | **64.43 ms · 125 rps** | 82.3% → **95.9%** | -58% | **+52.4% faster (`4.3×` fewer CDC misses)** |
| **`10:1` (10% writes, 1 tenant)** | 29.57 ms · 271 rps | 33.47 ms · 239 rps | **31.61 ms · 254 rps** | 99.4% → **99.9%** | -6% | **+6.3% faster (`6×` fewer CDC misses)** |
| **`10:200` (10% writes, 200 tenants)** | 43.99 ms · 182 rps | 121.67 ms · 69 rps | **89.86 ms · 90 rps** | 78.1% → **92.7%** | -51% | **+30.4% faster (`3.0×` fewer CDC misses)** |

---

### 4.4 Sweep 4: Complex Multi-Table Scenarios, 80/20 Pareto & Heavy Writes ([`04-complex-sweep-k8s.txt`](04-complex-sweep-k8s.txt))

#### 4.4.1 Complex Scenarios (`200` Tenants, `CLIENTS=8` — [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt))

| Scenario (`200` Tenants) | Origin Path A (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`dash_base`** (`dashboard.sql`) | 49.97 ms · 160 rps | 26.65 ms · 300 rps | **28.53 ms · 282 rps** (`5.0` warm) | 100.0% → **100.0%** | **+76% (1.76×)** | Warm-up dropped from `6.7` to **`5.0` passes** |
| **`search`** (`complex-search.sql`) | 129.00 ms · 62 rps | 14.00 ms · 572 rps | **9.91 ms · 812 rps** (`4.7` warm) | 100.0% → **100.0%** | **+1,219% (13.1×)** | **+42.0% faster (`7.3` → `4.7` warm)** |
| **`joins`** (`complex-joins.sql`) | 289.78 ms · 28 rps | 25.68 ms · 330 rps | **10.85 ms · 773 rps** (`5.0` warm) | 98.8% → **100.0%** | **+2,710% (28.1×)** | **2.34× faster (`8.0` → `5.0` warm)** |
| **`analytics`** (`complex-analytics.sql`) | 206.10 ms · 39 rps | 18.50 ms · 433 rps | **12.41 ms · 655 rps** (`5.7` warm) | 98.4% → **100.0%** | **+1,583% (16.8×)** | **+51.3% faster (`8.0` → `5.7` warm)** |
| **`cplx_dash`** (`complex-dashboard.sql`) | 360.62 ms · 23 rps | 89.85 ms · 128 rps | **24.62 ms · 338 rps** (`7.7` warm) | 97.9% → **100.0%** | **+1,410% (15.1×)** | **2.64× faster (`100%` hit)** |
| **`cplx_zipf`** (`complex-dashboard-zipfian.sql`) | 396.29 ms · 20 rps | 89.85 ms · 128 rps | **20.64 ms · 393 rps** (`7.7` warm) | 97.9% → **100.0%** | **+1,863% (19.6×)** | **3.07× faster (`100%` hit)** |

#### 4.4.2 80/20 Pareto Tenant Scaling (`100` to `2,000` Tenants — [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt))

| Pareto 80/20 Tenants (`z_tenants`) | Origin Path A (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---:|---|---|---|---:|---:|---|
| **`100` Tenants** | 384.00 ms · 21 rps | 52.85 ms · 151 rps | **16.00 ms · 510 rps** (`5.7` warm) | 99.1% → **100.0%** | **+2,357% (24.3×)** | **3.38× faster** |
| **`200` Tenants** | 377.05 ms · 21 rps | 62.48 ms · 128 rps | **16.54 ms · 487 rps** (`7.3` warm) | 99.1% → **100.0%** | **+2,233% (23.2×)** | **3.80× faster** |
| **`500` Tenants** | 357.45 ms · 23 rps | 216.14 ms · 37 rps | **145.62 ms · 56 rps** (`8.0` warm) | 85.1% → **93.2%** | **+150% (2.50×)** | **+51.4% faster (+8.1 pp hit)** |
| **`1,000` Tenants** | 381.24 ms · 21 rps | 463.82 ms · 18 rps (`-49%`) | **265.90 ms · 33 rps** (`6.0` warm) | 71.0% → **79.1%** | **+53% (1.53×)** | **1.83× faster (flipped `-49%` to `+53%`)** |
| **`2,000` Tenants** | 408.88 ms · 20 rps | 996.55 ms · 8 rps (`-77%`) | **338.95 ms · 25 rps** (`6.3` warm) | 49.9% → **71.5%** | **+27% (1.27×)** | **3.13× faster (flipped `-77%` to `+27%`)** |

#### 4.4.3 Concurrent Writes on the Enterprise Screen (`MAX_WARM_PASSES=3` with Cold Reset — [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt))

| `Write % : Target Tenants` | Origin Path A (`0.8.0`) | PgCache `0.7.1` (Part 1) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1` |
|---|---|---|---|---:|---:|---|
| **`0:200` (Read-Only)** | 342.50 ms · 24 rps | 23.4 ms · 389 rps | **19.18 ms · 419 rps** | 100.0% → **100.0%** | **+1,703% (18.0×)** | **+7.7% faster** |
| **`5:1` (5% writes, 1 tenant)** | 345.34 ms · 23 rps | 21.9 ms · 365 rps *(unreset)* | **891.91 ms · 9 rps** *(cold reset)* | **48.1%** | -61% | Cold reset per trial (`3` passes) |
| **`5:10` (5% writes, 10 tenants)** | 367.47 ms · 22 rps | 2,995.5 ms · 3 rps (`-85%`) | **809.01 ms · 10 rps** | 32.4% → **42.4%** | -54% | **3.33× higher RPS (`3.70×` lower latency)** |
| **`5:200` (5% writes, 200 tenants)** | 391.69 ms · 21 rps | — | **761.62 ms · 10 rps** | **44.1%** | -50% | Steady at `10–11 rps` |
| **`10:1` (10% writes, 1 tenant)** | 319.85 ms · 25 rps | — | **704.13 ms · 12 rps** | **45.6%** | -51% | Up to `17 rps` (`49.96%` hit) in Trial 1 |
| **`10:200` (10% writes, 200 tenants)** | 329.39 ms · 25 rps | — | **762.32 ms · 11 rps** | **35.6%** | -56% | Steady at `10–11 rps` |

---

### 4.5 Sweep 6: The "Fair Benchmark" (`2 GiB shared_buffers` + `pg_prewarm` + `GIN pg_trgm` — [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt))

| Fair Benchmark Scenario (`TENANTS=200`, `CLIENTS=8`) | Tuned Origin (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`search_1c` (`ILIKE '%1%'`)** | 109.38 ms · 73 rps | 12.42 ms · 644 rps (`8.0` warm) | **9.17 ms · 874 rps** (`4.0` warm) | 100.0% → **100.0%** | **+1,095% (12.0×)** | **+35.7% faster (half the warm-up)** |
| **`search_3c` (`ILIKE` 3+ chars + `GIN`)** | 75.32 ms · 107 rps | 8.75 ms · 914 rps (`3.4` warm) | **6.07 ms · 1,319 rps** (`3.0` warm) | 100.0% → **100.0%** | **+1,143% (12.4×)** | **+44.3% faster (`1,375 rps` peak)** |
| **`cplx_dash` (8-Query Enterprise Screen)** | 302.52 ms · 27 rps | 67.16 ms · 128 rps (`97.9%` hit) | **16.55 ms · 487 rps** (`7.3` warm) | 97.9% → **100.0%** | **+1,728% (18.3×)** | **3.80× faster (`100%` hit in all 3 trials)** |
| **`cplx_dyn` (Dynamic Filters, `t=1`)** | 268.48 ms · 30 rps | 898.55 ms · 9 rps (`29.8%` hit) | **422.20 ms · 20 rps** (`8.0` warm) | 29.8% → **66.1%** | -33% (0.67×) | **2.22× faster (+36.3 pp hit)** |

---

### 4.6 Sweep 7: `ADMISSION_THRESHOLD` Study (`1` vs `2` vs `4` — [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt))

| Cell & Threshold (`TENANTS=200`, `CLIENTS=8`) | Tuned Origin (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | `0.8.0` Gain vs Origin | `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`t1_cold0s` (`threshold=1`, 0s warm)** | 255.32 ms · 31 rps | 1,796.26 ms · 4 rps (`-87.1%`) | **842.92 ms · 9 rps** | 3.30% → **4.54%** | -70.2% | **2.25× faster (`-53%` latency)** |
| **`t1_w30s` (`threshold=1`, 30s warm)** | 276.80 ms · 29 rps | 1,547.88 ms · 5 rps (`-83.9%`) | **976.53 ms · 8 rps** | 17.90% → **29.04%** | -72.4% | **+60% faster (+11.1 pp hit)** |
| **`t2_cold0s` (`threshold=2`, 0s warm)** | 278.19 ms · 29 rps | 739.14 ms · 11 rps (`-64.9%`) | **707.69 ms · 11 rps** | 2.71% → **4.26%** | -60.9% | **+58% faster than `t1_cold0s`** |
| **`t2_w30s` (`threshold=2`, 30s warm)** | 272.24 ms · 30 rps | 1,158.39 ms · 7 rps (`-77.4%`) | **605.63 ms · 13 rps** | 15.89% → **29.44%** | -56.2% | **1.86× faster (+13.6 pp hit)** |
| **`t2_settle` (`threshold=2`, settled)** | 259.55 ms · 31 rps | 75.34 ms · 117 rps (`98.3%` hit) | **23.03 ms · 369 rps** (`8.0` warm) | 98.3% → **100.0%** | **+1,084% (11.8×)** | **3.15× faster (`446 rps` peak)** |
| **`t2_dyn` (`threshold=2`, dynamic)** | 212.43 ms · 38 rps | 638.94 ms · 13 rps (`33.2%` hit) | **249.12 ms · 32 rps** (`8.0` warm) | 33.2% → **47.5%** | -13% (`+8.8%` T3) | **2.46× faster (beat Origin in T3!)** |
| **`t4_cold0s` (`threshold=4`, 0s warm)** | 245.38 ms · 33 rps | 742.20 ms · 11 rps (`-66.2%`) | **402.73 ms · 20 rps** | 1.22% → **2.68%** | -38.8% | **1.82× faster (`-52%` vs `t1_cold0s`)** |
| **`t4_w30s` (`threshold=4`, 30s warm)** | 283.80 ms · 28 rps | 568.58 ms · 14 rps (`-57.9%`) | **313.59 ms · 27 rps** | 13.45% → **22.08%** | **-4.8% (`+13.8%` T2)** | **1.93× faster (breakeven at 30s!)** |
| **`t4_settle` (`threshold=4`, settled)** | 240.75 ms · 33 rps | 591.29 ms · 14 rps (`14.1%` hit) | **258.50 ms · 31 rps** (`6.0` warm) | 14.1% → **30.1%** | **-6% (`-2.9%` T2)** | **2.21× faster (+16.0 pp hit)** |
| **`t4_dyn` (`threshold=4`, dynamic)** | 247.03 ms · 33 rps | 504.14 ms · 16 rps (`-52%`) | **231.46 ms · 35 rps** (`5.0` warm) | 9.5% → **18.3%** | **+8% (`+12.1%` T2)** | **2.19× faster (beats Origin by `+8%`!)** |

---

## 5. Artifact Index (`results/0.8.0/`)

- [`verify-correctness-doks.txt`](verify-correctness-doks.txt): Byte-for-byte differential gate (`8/8` baseline, `12/12` static complex, `12/12` post-CDC live mutations, `0` uncacheable, `3` selective invalidations).
- [`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt): `1` to `2,000` tenant scaling sweep (`TRIALS=3`).
- [`02-concurrency-sweep-k8s.txt`](02-concurrency-sweep-k8s.txt): `1` to `32` concurrent clients sweep (`TRIALS=3`).
- [`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt): CDC write-ratio sweep on the operational dashboard (`TRIALS=3`).
- [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt): 4-to-6 table enterprise scenarios (`dash_base`, `search`, `joins`, `analytics`, `cplx_dash`, `cplx_zipf`, `TRIALS=3`).
- [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt): 80/20 Pareto tenant scaling from `100` to `2,000` tenants (`TRIALS=3`).
- [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt): Concurrent writes on the enterprise screen with cold reset (`TRIALS=3`).
- [`04-complex-sweep-k8s.txt`](04-complex-sweep-k8s.txt): Consolidated log for Sweep `04`.
- [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt): The "Fair Benchmark" against `2 GiB` Prewarmed Origin + `GIN pg_trgm` (`TRIALS=3`).
- [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt): `ADMISSION_THRESHOLD` (`1`, `2`, `4`) sweep across `0s`, `30s`, `settled`, and `cplx_dyn` (`TRIALS=3`).
- [`10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt`](10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt): 120-second (`8 × 15s`) step-by-step `pgcache_cache_subsumptions` warm-up curve comparing `0.8.0` vs. `0.7.1`.
