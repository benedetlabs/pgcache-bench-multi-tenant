---
name: pgcache-complex-scenarios
description: >-
  Use this skill when designing, extending, debugging, or verifying complex
  multi-tenant SQL benchmark scenarios (text search with ILIKE, multi-table
  JOIN and LEFT JOIN chains, conditional FILTER/CASE aggregations, HAVING
  rollups) and running the differential correctness and cacheability gate.
---

# PgCache Complex Multi-Tenant Scenario Specialist

This skill defines the workflow and SQL engineering rules for the **Complex Multi-Tenant Scenario Agent**, responsible for authoring realistic, high-complexity multi-tenant SaaS workloads and verifying 100% PgCache compatibility and differential correctness.

## 1. Why Complex Scenarios Matter

In a lightweight operational dashboard (`workload/dashboard.sql`), most statements are single-table B-tree index lookups or top-N queries (`ORDER BY created_at DESC LIMIT 20`) where PostgreSQL Origin already responds in `0.2–2.0 ms`. Because PgCache is a wire-protocol proxy backed by an embedded PostgreSQL engine, it has a fixed per-query protocol floor.

Complex SaaS screens shift the bottleneck decisively onto Origin CPU and buffer scans:
1. **Substring Text Search (`workload/complex-search.sql`)**:
   - Queries with leading-wildcard predicates (`c.name ILIKE '%4%' OR c.email ILIKE '%4%'`, `p.name ILIKE '%15%'`, `r.body ILIKE '%8%'`) cannot use standard B-tree indexes for prefix range scans.
   - Origin must scan all tuples belonging to the tenant across joined tables and evaluate case-insensitive pattern matching on every row.
2. **Deep Multi-Table `JOIN` & `LEFT JOIN` Chains (`workload/complex-joins.sql`)**:
   - Joins 4 to 6 tables (`orders`, `customer`, `order_item`, `product`, `category`, `seller`, `review`).
   - Uses `LEFT JOIN` to preserve parent entities with zero child records (e.g., dormant customers with zero completed orders via `customer LEFT JOIN orders LEFT JOIN order_item`, or purchased products with zero reviews via `LEFT JOIN review`), preventing inner-join short-circuiting.
3. **Heavy Analytical Aggregations (`workload/complex-analytics.sql`)**:
   - Multi-dimensional `GROUP BY` across joined tables with `COUNT(DISTINCT ...)`, conditional aggregates `FILTER (WHERE o.status = 'done')`, `CASE WHEN oi.price >= 200 THEN ... END` margin buckets, and `HAVING` thresholds.
4. **Unified Complex SaaS Screen (`workload/complex-dashboard.sql`)**:
   - Combines 8 complex statements (3 analytical rollups, 3 deep `JOIN`/`LEFT JOIN` views, and 2 multi-table `ILIKE` text searches) into a single pgbench request.

## 2. Mandatory SQL Cacheability Rules for PgCache (`0.7.1+`)

PgCache parses incoming simple-protocol SQL queries and checks AST structure and function volatility (`pg_proc.provolatile == 'i'`). A subtle syntax mistake in a `pgbench` script will cause PgCache to classify a query as **uncacheable** (`pgcache_queries_uncacheable`) and silently forward it to Origin on every execution.

Always enforce these four rules when authoring `workload/*.sql` files:

1. **Pre-Compute Arithmetic in `pgbench` via `\set`**:
   - **WRONG**: `LIMIT 20 OFFSET :off * 20` — `pgbench` sends `OFFSET 2 * 20` over the wire, which is an arithmetic expression in `OFFSET` and is marked **uncacheable**.
   - **RIGHT**:
     ```sql
     \set off random(0, 4)
     \set off_rows :off * 10
     ...
     LIMIT 20 OFFSET :off_rows;
     ```
     `pgbench` evaluates `:off * 10` client-side and sends `OFFSET 20` (an integer literal), which is **100% cacheable**.
2. **Use Pure Literals in `WHERE` and `ILIKE` Clauses**:
   - **WRONG**: `WHERE c.name ILIKE '%' || :kw || '%'` or `WHERE status = (ARRAY['new','paid'])[:st]` — `text || int` is `STABLE` (not `IMMUTABLE`) and array subscripting in `WHERE` is marked **uncacheable**.
   - **RIGHT**: Use literal `ILIKE '%15%'` predicates combined with pre-computed numeric filter variables (`AND p.price >= :min_price`, `AND r.rating >= :min_rating`, `OFFSET :off_rows`) to vary the query space across `:tenants x :off_rows x :min_price`.
3. **Group by Base Columns, Not Expressions**:
   - **WRONG**: `SELECT coalesce(o.status, 'no_orders') ... GROUP BY coalesce(o.status, 'no_orders')` — grouping on a `coalesce(...)` expression is marked **uncacheable**.
   - **RIGHT**: `SELECT coalesce(o.status, 'no_orders') AS lifecycle_stage ... GROUP BY o.status` — `NULL` values from `LEFT JOIN` naturally form their own group in SQL, and `coalesce` in `SELECT` formats the output label while keeping the query **100% cacheable**.
4. **Deterministic Tie-Breakers in `ORDER BY`**:
   - Every `LIMIT` query MUST end its `ORDER BY` clause with unique tie-breaker columns (e.g., `ORDER BY gross_revenue DESC, p.id ASC` or `ORDER BY o.created_at DESC, oi.id DESC`) so Origin and PgCache always return identical row orderings.
5. **Use `GROUP BY` on Multi-Table Joins with Cross-Table `ORDER BY ... LIMIT`**:
   - When an ungrouped multi-table `JOIN` has `ORDER BY` referencing multiple tables plus `LIMIT N OFFSET M`, PgCache's population planner generates per-table `SELECT DISTINCT <table.*> ... LIMIT (N+M)` queries without the cross-table `ORDER BY` (since PostgreSQL forbids `SELECT DISTINCT` with `ORDER BY` columns not in the projection list), which can populate an incomplete subset of rows.
   - Including `GROUP BY` on the entity key (e.g., `GROUP BY o.id, ..., oi.id` with `coalesce(max(r.rating), 0)` for `LEFT JOIN review`) instructs PgCache to populate the complete tenant relation set before grouping and paginating, guaranteeing 100% byte-for-byte differential identity.

## 3. Running the Verification Gate

Whenever adding or modifying a workload query, execute:

```bash
DOCKER=1 ./scripts/verify-correctness.sh
```

Do not proceed to benchmark sweeps unless `Uncacheable delta: 0`, `Cache Errors delta: 0`, and all differential row comparisons report `[PASS]`.
