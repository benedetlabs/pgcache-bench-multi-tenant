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
   - Queries with leading-wildcard predicates (`c.name ILIKE '%1%' OR c.email ILIKE '%1%'`, `p.name ILIKE '%1%'`, `r.body ILIKE '%1%'`, `p.name ILIKE '%2%' OR c.email ILIKE '%2%'`) cannot use standard B-tree indexes for prefix range scans.
   - Origin must scan all tuples belonging to the tenant across joined tables and evaluate case-insensitive pattern matching on every row.
2. **Deep Multi-Table `JOIN` & `LEFT JOIN` Chains (`workload/complex-joins.sql`)**:
   - Joins 4 to 6 tables (`orders`, `customer`, `order_item`, `product`, `category`, `seller`, `review`).
   - Uses `LEFT JOIN` to preserve parent entities with zero child records (e.g., dormant customers with zero completed orders via `customer LEFT JOIN orders LEFT JOIN order_item`, or purchased products with zero reviews via `LEFT JOIN review`), preventing inner-join short-circuiting.
3. **Heavy Analytical Aggregations (`workload/complex-analytics.sql`)**:
   - Multi-dimensional `GROUP BY` across joined tables with `COUNT(DISTINCT ...)`, conditional aggregates `FILTER (WHERE o.status = 'done')`, `CASE WHEN oi.price >= 200 THEN ... END` margin buckets, and `HAVING` thresholds.
4. **Unified Complex SaaS Screen (`workload/complex-dashboard.sql`)**:
   - Combines 8 complex statements (3 analytical rollups, 3 deep `JOIN`/`LEFT JOIN` views, and 2 multi-table `ILIKE` text searches) into a single pgbench request.

## 2. Mandatory SQL Cacheability & Materialized View Rules for PgCache (`0.7.1+`)

PgCache parses incoming simple-protocol SQL queries, checks AST structure and function volatility (`pg_proc.provolatile == 'i'`), and evaluates its Materialized View (MV) admission gate (`pgcache_cache_mv_gate`). A subtle syntax mistake in a `pgbench` script will either mark a query **uncacheable** (`pgcache_queries_uncacheable`), reject it from Materialized View acceleration (`pgcache_cache_mv_gate{outcome="reject"}`), or cause cross-tenant CDC invalidation storms.

Always enforce these six rules when authoring `workload/*.sql` files:

1. **Explicit Tenant Literal Predicates (`= :t`) on Every Joined Tenant-Scoped Table**:
   - **WRONG**:
     ```sql
     FROM order_item oi JOIN orders o ON o.id = oi.order_id WHERE oi.tenant_id = :t
     -- or:
     FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = c.tenant_id WHERE c.tenant_id = :t
     ```
     Without an explicit `o.tenant_id = :t` literal predicate, PgCache cannot scope its dependency on `orders` to tenant `:t` (a single-tenant `UPDATE orders` invalidates cached queries across **all** tenants), and Origin falls back to parallel bitmap scans during per-table population.
   - **RIGHT**: Include `AND o.tenant_id = :t`, `AND oi.tenant_id = :t`, and `AND c.tenant_id = :t` in `WHERE` for `INNER JOIN` tables, and `ON ... AND o.tenant_id = :t` / `AND oi.tenant_id = :t` in `LEFT JOIN` clauses. Under this pattern, `INNER JOIN` MVs remain **100% cache hits (`0` misses)** even when the same tenant's orders are updated in-place via CDC, and `LEFT JOIN` invalidations are strictly isolated to the updated tenant (`:wtenants`).
2. **Materialized View Admission Gate (`OFFSET 0` Requirement for Complex Queries)**:
   - While pre-computed `\set off_rows :off * 10` (`OFFSET :off_rows`) passes the outer parser cacheability check (`pgcache_queries_cacheable`), PgCache 0.7.1's Materialized View gate (`pgcache_cache_mv_gate`) **rejects** queries with `OFFSET > 0` (`pgcache_cache_mv_gate{outcome="reject"}`), forcing every hit onto the slow base-table re-execution path (`pgcache_cache_mv_fallthrough`).
   - Complex multi-table `JOIN` and aggregation queries MUST omit `OFFSET` (or use `OFFSET 0`) so 100% of queries are admitted (`pgcache_cache_mv_gate{outcome="admit"}`) and served directly from pre-joined Materialized Views (`pgcache_cache_mv_hits`).
3. **Pre-Compute Any Arithmetic in `pgbench` via `\set`**:
   - **WRONG**: `LIMIT 20 OFFSET :off * 20` or `WHERE total >= :tier * 100` — `pgbench` sends `2 * 20` over the wire, which is an arithmetic expression and is marked **uncacheable**.
   - **RIGHT**: Compute `\set val :tier * 100` first so `pgbench` interpolates an integer literal.
4. **Use Pure Literals in `WHERE` and `ILIKE` Clauses**:
   - **WRONG**: `WHERE c.name ILIKE '%' || :kw || '%'` or `WHERE status = (ARRAY['new','paid'])[:st]` — `text || int` is `STABLE` (not `IMMUTABLE`) and array subscripting in `WHERE` is marked **uncacheable**.
   - **RIGHT**: Use literal `ILIKE '%1%'` or `ILIKE '%2%'` predicates combined with literal numeric thresholds (`AND p.price >= 50`, `AND r.rating >= 2`).
5. **Group by Base Columns, Not Expressions**:
   - **WRONG**: `SELECT coalesce(o.status, 'no_orders') ... GROUP BY coalesce(o.status, 'no_orders')` — grouping on a `coalesce(...)` expression is marked **uncacheable**.
   - **RIGHT**: `SELECT coalesce(o.status, 'no_orders') AS lifecycle_stage ... GROUP BY o.status` — `NULL` values from `LEFT JOIN` naturally form their own group in SQL, and `coalesce` in `SELECT` formats the output label while keeping the query **100% cacheable**.
6. **Deterministic Tie-Breakers in `ORDER BY` and `GROUP BY` on Multi-Table Joins**:
   - Every `LIMIT` query MUST end its `ORDER BY` clause with unique tie-breaker columns (e.g., `ORDER BY gross_revenue DESC, p.id ASC` or `ORDER BY o.created_at DESC, oi.id DESC`) so Origin and PgCache always return identical row orderings.
   - Including `GROUP BY` on the entity key (e.g., `GROUP BY o.id, ..., oi.id` with `coalesce(max(r.rating), 0)` for `LEFT JOIN review`) instructs PgCache to populate the complete tenant relation set before grouping and paginating, guaranteeing 100% byte-for-byte differential identity.

## 3. Running the Verification Gate

Whenever adding or modifying a workload query, execute:

```bash
DOCKER=1 ./scripts/verify-correctness.sh
```

This tests all 12 complex queries across 3 passes (`Pass 1` miss/populate, `Pass 2` base-table hit + MV build, `Pass 3` warm MV hit). Do not proceed to benchmark sweeps unless `Uncacheable delta: 0`, `MV Gate Admitted: 12 (Rejected: 0)`, `MV Hits delta: 12`, `Cache Errors delta: 0`, and all 12 differential row comparisons report `[PASS]`.
