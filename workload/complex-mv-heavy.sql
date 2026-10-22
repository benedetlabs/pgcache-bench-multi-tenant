-- ============================================================================
-- Complex Scenario 7: High-Volume / Wide Materialized View Workload (LIMIT 500)
--
--   pgbench -f complex-mv-heavy.sql -D tenants=100 ...
--
-- Designed for the 5 GB (SCALE=10) Memory-Constrained NVMe vs. SSD Study:
--   - Unlike complex-dashboard.sql (which caps each MV at LIMIT 10..20 rows,
--     producing ~16-24 kB tables that fit easily in shared_buffers), each
--     statement here materializes up to 500 rows (25x wider MVs) across
--     4-to-6 joined tables (orders, order_item, customer, product, category,
--     seller, review).
--   - Combined with SCALE=10 (~5 GB Origin DB, 20M order_items, 5M orders)
--     and constrained shared_buffers (512 MB), this forces heavy disk I/O
--     during both MV population/refresh and multi-tenant MV scans.
--
-- Protocol Invariants:
--   - Simple query protocol (-M simple), NO explicit BEGIN...COMMIT.
--   - All literals are interpolated directly by pgbench so 100% of queries
--     pass both PgCache's cacheability check and MV admission gate.
-- ============================================================================

\set t random(1, :tenants)

-- 1. [Wide 4-Table Aggregation + FILTER] Category & product revenue funnel (up to 500 products per tenant).
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
 LIMIT 500;

-- 2. [Wide 6-Table JOIN + LEFT JOIN] Purchased product coverage with unreviewed inventory detection (500 rows).
SELECT p.id, p.name AS product_name,
       cat.name AS category_name,
       s.name AS seller_name,
       count(DISTINCT o.customer_id) AS unique_buyers,
       sum(oi.qty) AS units_sold,
       sum(oi.qty * oi.price) AS gross_revenue,
       count(r.id) AS tenant_reviews,
       coalesce(round(avg(r.rating), 2), 0) AS avg_tenant_rating
  FROM order_item oi
  JOIN orders o      ON o.id = oi.order_id
  JOIN product p     ON p.id = oi.product_id
  JOIN category cat  ON cat.id = p.category_id
  JOIN seller s      ON s.id = p.seller_id
  LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id
 WHERE oi.tenant_id = :t
   AND o.tenant_id = :t
 GROUP BY p.id, p.name, cat.name, s.name
 ORDER BY units_sold DESC, gross_revenue DESC, p.id ASC
 LIMIT 500;

-- 3. [Wide Multi-Hop LEFT JOIN Cohort] Full customer lifecycle & order status cohort (500 customers per tenant).
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
 LIMIT 500;

-- 4. [Wide 6-Table JOIN + LEFT JOIN + HAVING] Category x Seller x Product fulfilment & review matrix (500 rows).
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
HAVING count(oi.id) >= 2
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT 500;
