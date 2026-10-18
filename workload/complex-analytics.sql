-- ============================================================================
-- Complex Scenario 3: Heavy Analytical Aggregations & Multi-Dimensional Rollups
--
--   pgbench -f complex-analytics.sql -D tenants=200 ...
--
-- Evaluates analytical OLAP-style aggregations over multi-tenant operational
-- data: conditional aggregates (FILTER WHERE), CASE WHEN margin buckets,
-- HAVING clauses, COUNT(DISTINCT ...), and multi-dimensional GROUP BY rollups.
--
-- Why this stresses Origin:
--   Aggregating across all orders and line items of a tenant (and joining
--   products, categories, sellers, customers, and reviews) cannot be satisfied
--   by an index top-N scan. Origin must visit every qualifying tuple, compute
--   hash/group aggregates, evaluate FILTER/CASE expressions, apply HAVING
--   predicates, and sort the final rollup.
--
-- Protocol Invariants:
--   - Simple query protocol (-M simple), NO explicit BEGIN...COMMIT.
--   - All literals are interpolated directly by pgbench so 100% of queries
--     pass both PgCache's cacheability check and MV admission gate.
-- ============================================================================

\set t random(1, :tenants)

-- 1. Category & product revenue funnel with conditional FILTER (WHERE ...) aggregates.
--    Computes total orders, completed orders, new orders, settled revenue, and
--    average line value across 4 joined tables (200 distinct groups per tenant).
SELECT cat.id AS category_id, cat.name AS category_name,
       p.id AS product_id, p.name AS product_name,
       count(DISTINCT o.id) AS total_orders,
       count(DISTINCT o.id) FILTER (WHERE o.status = 'done') AS done_orders,
       count(DISTINCT o.id) FILTER (WHERE o.status = 'new') AS pending_orders,
       coalesce(sum(oi.qty * oi.price) FILTER (WHERE o.status IN ('paid', 'shipped', 'done')), 0) AS settled_revenue,
       round(avg(oi.qty * oi.price), 2) AS avg_item_revenue
  FROM order_item oi
  JOIN orders o     ON o.id = oi.order_id
  JOIN product p    ON p.id = oi.product_id
  JOIN category cat ON cat.id = p.category_id
 WHERE oi.tenant_id = :t
   AND o.tenant_id = :t
 GROUP BY cat.id, cat.name, p.id, p.name
 ORDER BY settled_revenue DESC, cat.id ASC, p.id ASC
 LIMIT 20;

-- 2. Seller & product performance rollup with CASE WHEN ticket-size buckets and HAVING.
SELECT s.id AS seller_id, s.name AS seller_name, s.rating AS seller_rating,
       p.id AS product_id, p.name AS product_name,
       count(DISTINCT o.id) AS order_cnt,
       count(DISTINCT o.customer_id) AS unique_buyers,
       sum(CASE WHEN oi.price >= 200 THEN oi.qty * oi.price ELSE 0 END) AS high_ticket_revenue,
       sum(CASE WHEN oi.price < 200 THEN oi.qty * oi.price ELSE 0 END) AS standard_ticket_revenue,
       sum(oi.qty * oi.price) AS total_revenue
  FROM order_item oi
  JOIN orders o  ON o.id = oi.order_id
  JOIN product p ON p.id = oi.product_id
  JOIN seller s  ON s.id = p.seller_id
 WHERE oi.tenant_id = :t
   AND o.tenant_id = :t
 GROUP BY s.id, s.name, s.rating, p.id, p.name
HAVING sum(oi.qty * oi.price) >= 400
 ORDER BY total_revenue DESC, s.id ASC, p.id ASC
 LIMIT 20;

-- 3. Customer lifecycle & order status cohort rollup including zero-order accounts.
--    Uses customer LEFT JOIN orders LEFT JOIN order_item with FILTER (WHERE ...)
--    so inactive customers (0 orders) are preserved alongside active cohorts.
SELECT c.id AS customer_id, c.name AS customer_name, c.email,
       count(DISTINCT o.id) AS total_orders,
       count(DISTINCT o.id) FILTER (WHERE o.status = 'done') AS done_orders,
       count(DISTINCT o.id) FILTER (WHERE o.status IN ('new', 'paid', 'shipped')) AS active_orders,
       coalesce(sum(oi.qty * oi.price), 0) AS lifetime_revenue,
       coalesce(max(o.total), 0) AS max_order_value
  FROM customer c
  LEFT JOIN orders o      ON o.customer_id = c.id AND o.tenant_id = :t
  LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = :t
 WHERE c.tenant_id = :t
 GROUP BY c.id, c.name, c.email
 ORDER BY lifetime_revenue DESC, c.id ASC
 LIMIT 15;

-- 4. Category x Seller x Product cross-tabulation with review quality score and HAVING.
--    6-table join + LEFT JOIN review + multi-column GROUP BY + HAVING.
SELECT cat.name AS category_name,
       s.name AS seller_name,
       p.id AS product_id, p.name AS product_name,
       count(DISTINCT o.id) AS orders_cnt,
       sum(oi.qty) AS total_units,
       sum(oi.qty * oi.price) AS gross_revenue,
       round(avg(oi.price), 2) AS avg_unit_price,
       count(r.id) AS review_cnt,
       coalesce(round(avg(r.rating), 2), 0) AS avg_review_rating
  FROM order_item oi
  JOIN orders o      ON o.id = oi.order_id
  JOIN product p     ON p.id = oi.product_id
  JOIN category cat  ON cat.id = p.category_id
  JOIN seller s      ON s.id = p.seller_id
  LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id
 WHERE oi.tenant_id = :t
   AND o.tenant_id = :t
 GROUP BY cat.name, s.name, p.id, p.name
HAVING count(oi.id) >= 3
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT 20;
