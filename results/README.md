# PgCache Benchmark Results: From Simple Dashboards to 6-Table Enterprise Analytics

> 🇧🇷 **[Ler em português](README-pt.md)**

This folder contains the empirical results of putting **PgCache** in front of **PostgreSQL 17** across multiple product releases (`0.6.3`, `0.6.4`, `0.7.0`, and `0.7.1`) and across two very different kinds of multi-tenant SaaS workloads.

> **Why You Won't Find Laptop Numbers Here**: All performance results in this repository come **exclusively from 3-node Kubernetes clusters in the cloud (DigitalOcean DOKS)**, where PostgreSQL, PgCache, and the benchmark client run on three separate physical virtual machines. Local Docker (`infra/docker-compose.yml`) is used only to set up the database and verify SQL correctness — never to claim speedups.

### Quick Navigation
- [**PgCache 0.7.1 — Multi-Trial (`TRIALS=5`) & Complex Enterprise Scenarios**](0.7.1/README.md) *(Recommended starting point)*
- [**1h30m Endurance & Database Offload Test (`SCALE=20`, ~10 GB)**](endurance-90m/README.md)
- [**Network & Engine Tuning Comparison (`0.7.0` Tuned)**](tuned/README.md)
- Historical Releases: [**0.6.3**](0.6.3/README.md) · [**0.6.4**](0.6.4/README.md) · [**0.7.0**](0.7.0/README.md)

---

## 1. The Big Picture: When Does a Read Cache Pay Off?

If you only read one table in this repository, make it this one.

We ran every scenario **5 independent times (`TRIALS=5`)** on our 3-node cloud cluster, destroying and recreating the PostgreSQL, PgCache, and loadgen pods before every single trial so there is no lucky run or leftover memory state:

| Workload Type (200 Tenants, 8 Concurrent Clients) | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Cache Hit Rate | Average Speedup (5-Run Spread) |
|---|---|---|---:|---|
| **Lightweight Operational Dashboard** (`dashboard.sql`, 8 fast indexed queries) | 57.8 ms · **146 req/s** *(±40.5 sd)* | **29.4 ms · 273 req/s** *(±16.3 sd)* | **100.0%** | **1.98× faster (+98%)** *(-68% / +69%)* |
| **Substring Text Search** (`complex-search.sql`, 4 `ILIKE '%...%'` + joins) | 129.6 ms · **63 req/s** *(±9.2 sd)* | **6.9 ms · 1,170 req/s** *(±126.1 sd)* | **100.0%** | **18.8× faster (+1,778%)** *(-266% / +243%)* |
| **Deep 4-to-6 Table Joins** (`complex-joins.sql`, `INNER` & `LEFT JOIN`) | 238.9 ms · **34 req/s** *(±2.8 sd)* | **8.2 ms · 991 req/s** *(±160.6 sd)* | **100.0%** | **29.4× faster (+2,839%)** *(-666% / +443%)* |
| **Multi-Dimensional Analytics** (`complex-analytics.sql`, `GROUP BY / HAVING`) | 175.3 ms · **46 req/s** *(±4.1 sd)* | **9.0 ms · 905 req/s** *(±122.1 sd)* | **100.0%** | **19.8× faster (+1,883%)** *(-395% / +267%)* |
| **Full Enterprise Screen (Uniform)** (`complex-dashboard.sql`, 8 heavy queries) | 307.5 ms · **26 req/s** *(±1.2 sd)* | **23.4 ms · 389 req/s** *(±132.6 sd)* | **100.0%** | **15.0× faster (+1,400%)** *(-766% / +684%)* |
| **Full Enterprise Screen (80/20 Pareto, 200 Tenants)** (`complex-dashboard-zipfian.sql`) | 339.2 ms · **24 req/s** *(±4.1 sd)* | **76.0 ms · 267 req/s** *(±191.3 sd)* | **97.5%** | **11.5× faster (+1,051%)** *(-1,016% / +917%)* |
| **Full Enterprise Screen (80/20 Pareto, 2,000 Tenants)** (`complex-dashboard-zipfian.sql`) | 373.1 ms · **22 req/s** *(±1.9 sd)* | **351.2 ms · 24 req/s** *(±5.4 sd)* | **64.1%** | **1.09× faster (+9%)** *(-26% / +30%)* |

### Why Does Speedup Jump from ~2× to ~29×?

Because of **network physics** and **how much work PostgreSQL has to do**:
1. **The Network Floor**: In a real cloud cluster, every SQL statement takes ~0.7 ms just to travel between VMs. When a page makes 8 sequential queries, **~5.6 ms is spent purely on network round-trips**, whether you talk to PostgreSQL or PgCache.
2. **When Queries Are Cheap (`dashboard.sql`)**: PostgreSQL answers all 8 simple indexed queries in ~23–58 ms. Since network travel and SQL parsing already make up a big chunk of that time, PgCache roughly **doubles your throughput (+45% to +98%)**.
3. **When Queries Are Expensive (`complex-*.sql`)**: Once a page runs `ILIKE '%...%'` searches, 6-table joins, or `GROUP BY` aggregations across thousands of tenant orders, PostgreSQL takes **130 to 308 ms** per page. PgCache pre-computes those results into in-memory Materialized Views and still answers in **7 to 23 ms** — turning a sluggish 300 ms enterprise page into a snappy 20 ms response (**15× to 29× faster**).

---

## 2. How PgCache Evolved Across Versions (`0.6.3` → `0.7.1`)

On the lightweight operational dashboard (`workload/dashboard.sql`), we tracked PgCache from `0.6.3` to `0.7.1` across **1 to 2,000 tenants** on the 3-node DOKS cluster. Across every version and tenant tier, once warmed, PgCache maintained a **100.0% cache hit rate**:

| Active Tenants | PostgreSQL Direct (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio |
|---|---|---|---|---|---|---:|
| **1 Tenant** | 23.3–27.5 ms (291–343 req/s) | **17.6 ms** (455 req/s, +56%) | **16.8 ms** (476 req/s, +61%) | **15.6 ms** (513 req/s, +50%) | **16.6 ms** (481 req/s, +40%) | **100.0%** |
| **10 Tenants** | 22.9–27.7 ms (288–350 req/s) | **17.8 ms** (451 req/s, +52%) | **21.0 ms** (382 req/s, +33%) | **22.9 ms** (349 req/s, +4%) | **21.7 ms** (369 req/s, +5%) | **100.0%** |
| **50 Tenants** | 25.4–29.9 ms (267–315 req/s) | **17.5 ms** (456 req/s, +66%) | **15.8 ms** (506 req/s, +90%) | **17.3 ms** (462 req/s, +64%) | **17.0 ms** (470 req/s, +49%) | **100.0%** |
| **100 Tenants** | 25.2–30.3 ms (264–317 req/s) | **19.4 ms** (412 req/s, +56%) | **16.3 ms** (492 req/s, +55%) | **17.2 ms** (465 req/s, +51%) | **16.3 ms** (491 req/s, +63%) | **100.0%** |
| **500 Tenants** | 24.4–32.2 ms (248–329 req/s) | **16.7 ms** (478 req/s, +93%) | **15.7 ms** (510 req/s, +71%) | **18.7 ms** (428 req/s, +38%) | **16.3 ms** (490 req/s, +49%) | **100.0%** |
| **1,000 Tenants** | 24.0–26.2 ms (305–333 req/s) | **17.5 ms** (458 req/s, +50%) | **16.8 ms** (476 req/s, +46%) | **17.2 ms** (466 req/s, +52%) | **16.9 ms** (473 req/s, +42%) | **100.0%** |
| **2,000 Tenants** | 23.3–26.0 ms (308–343 req/s) | **18.3 ms** (438 req/s, +40%) | **15.5 ms** (515 req/s, +67%) | **18.8 ms** (425 req/s, +38%) | **16.5 ms** (485 req/s, +41%) | **100.0%** |

---

## 3. What Happens Under High Concurrency? (`1` to `32` Simultaneous Users)

When we scale concurrent users on the heavy enterprise screen (`complex-dashboard.sql`), PostgreSQL hits a hard CPU wall at **38–39 screens/sec**, and user latency balloons to **835 ms**. PgCache scales smoothly to **1,020 screens/sec (26.8× faster)** while keeping latency at **31 ms**:

| Concurrent Users | PostgreSQL Direct (Path A) | PgCache 0.7.1 (Path B) | Speedup | Hit Ratio |
|---:|---|---|---:|---:|
| **1 User** | 100.6 ms · 10 req/s | **7.1 ms · 140 req/s** | **14.0× (+1,300%)** | 100.0% |
| **4 Users** | 129.5 ms · 31 req/s | **8.6 ms · 465 req/s** | **15.0× (+1,400%)** | 100.0% |
| **8 Users** | 212.8 ms · 38 req/s | **10.5 ms · 763 req/s** | **20.1× (+1,908%)** | 100.0% |
| **16 Users** | 406.9 ms · 39 req/s | **18.1 ms · 886 req/s** | **22.7× (+2,172%)** | 100.0% |
| **32 Users** | 835.5 ms · 38 req/s | **31.4 ms · 1,020 req/s** | **26.8× (+2,584%)** | 100.0% |

---

## 4. Folder Guide

- [`0.7.1/`](0.7.1/README.md): Full write-up and raw logs for **PgCache 0.7.1** (5-trial statistical runs, complex scenarios, 80/20 Pareto scaling, and live write tests).
- [`endurance-90m/`](endurance-90m/README.md): **1h30m Endurance & Resource Offload Test** on a ~10 GB dataset (`54.5M` rows), showing how offloading reads to PgCache cuts PostgreSQL write latency in half (`227 ms → 103 ms`).
- [`tuned/`](tuned/README.md): Side-by-side comparison of default vs. tuned Linux network stack (`tcp_tw_reuse`, VirtIO RPS, direct node IP routing).
- [`0.6.3/`](0.6.3/README.md), [`0.6.4/`](0.6.4/README.md), [`0.7.0/`](0.7.0/README.md): Historical baseline runs.
