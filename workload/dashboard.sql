-- ============================================================================
-- The request under test: one multi-tenant SaaS dashboard render.
--
--   pgbench -f dashboard.sql -D tenants=200 ...
--
-- READ THIS FIRST, because it is the whole trick of this campaign:
--
-- A pgbench `-f` script IS a transaction, and pgbench reports its latency as
-- one number. So a script containing eight statements is a REQUEST containing
-- eight statements, and pgbench measures per-request latency.
--
-- That is what let a tool built for single-statement benchmarks measure an
-- application-shaped workload. Query amplification -- eight database round
-- trips to paint one screen -- stops being a property of some application we
-- had to go find, and becomes a parameter we write down.
--
-- NO EXPLICIT TRANSACTION. pgbench is invoked with -M simple and there is no
-- BEGIN here, so every statement is its own implicit transaction. This is not
-- an aesthetic choice: PgCache passes through everything inside BEGIN...COMMIT,
-- so a script wrapped in a transaction would measure nothing at all. It is the
-- same property that disqualified BenchBase as a tool.
--
-- ── The variables ──────────────────────────────────────────────────────────
--
-- :tenants  the sweep's independent variable -- how many DISTINCT tenants the
--           workload touches. This is the whole hypothesis under test: if the
--           tenant filter explodes the query space, raising this should sink
--           the hit ratio.
--
-- :off, :st the variability a real application has beyond the tenant. A user
--           pages through results and filters by status, and each combination
--           is a different SQL text under simple protocol, hence a different
--           cache entry. Without these the query space would be 200 entries per
--           statement and the test would be trivially easy for the cache.
--           With them it is 200 x 10 x 4 across eight statements.
-- ============================================================================

\set t    random(1, :tenants)
\set off  random(0, 9)
\set st   random(1, 4)
\set cust random(1, 100000)

-- 1. Order counts by status. GROUP BY over the tenant's 2,500 orders.
--    The "cards at the top of the dashboard" query.
SELECT status, count(*) FROM orders WHERE tenant_id = :t GROUP BY status;

-- 2. Revenue and order count. Two aggregates over the same 2,500 rows.
SELECT sum(total), count(*) FROM orders WHERE tenant_id = :t;

-- 3. Customer count. Hits a different table through a different index, so the
--    request is not entirely satisfied out of one relation's cached pages.
SELECT count(*) FROM customer WHERE tenant_id = :t;

-- 4. The recent-orders page. This is the statement the composite index
--    (tenant_id, created_at DESC) exists for: index order matches sort order,
--    so the origin can stop at 20 rows instead of sorting 2,500.
--    OFFSET makes each page a distinct cache entry.
SELECT id, status, total, created_at
  FROM orders WHERE tenant_id = :t
 ORDER BY created_at DESC LIMIT 20 OFFSET :off * 20;

-- 5. A filtered count -- the number badge next to a status tab.
--    COUNT(*) is the classic cache target: expensive to compute, tiny to store.
SELECT count(*) FROM orders
 WHERE tenant_id = :t AND status = (ARRAY['new','paid','shipped','done'])[:st];

-- 6. Recent orders with the customer name. A two-table join, which is what an
--    ORM emits when a list view shows a field from a related record.
SELECT o.id, o.total, c.name
  FROM orders o JOIN customer c ON c.id = o.customer_id
 WHERE o.tenant_id = :t
 ORDER BY o.created_at DESC LIMIT 10;

-- 7. Top products for the tenant. The most expensive statement in the request:
--    a join across ~10,000 line items, a GROUP BY, and a sort on the aggregate.
--    No index can serve this by walking -- the origin has to do the work.
SELECT p.name, sum(oi.qty)
  FROM order_item oi JOIN product p ON p.id = oi.product_id
 WHERE oi.tenant_id = :t
 GROUP BY p.name ORDER BY 2 DESC LIMIT 10;

-- 8. A page of line items with product names. Join plus pagination, the two
--    shapes combined, closing the request.
SELECT oi.id, oi.qty, oi.price, p.name
  FROM order_item oi JOIN product p ON p.id = oi.product_id
 WHERE oi.tenant_id = :t
 ORDER BY oi.id DESC LIMIT 20 OFFSET :off * 20;
