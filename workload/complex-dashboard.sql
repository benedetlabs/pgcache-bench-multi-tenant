-- ============================================================================
-- Complex Scenario 4: Unified Complex Multi-Tenant SaaS Screen (8 Statements)
--
--   pgbench -f complex-dashboard.sql -D tenants=200 ...
--
-- While dashboard.sql models a lightweight operational overview (dominated by
-- single-table index scans and 2-table joins), complex-dashboard.sql models a
-- heavy enterprise analytics & search screen that issues 8 expensive SQL
-- statements per page render:
--   - Statements 1-3: Heavy multi-dimensional aggregations (FILTER WHERE,
--     CASE WHEN ticket buckets, HAVING, and customer lifecycle LEFT JOIN rollup)
--   - Statements 4-6: Deep 4-to-6 table JOIN and LEFT JOIN queries (enriched
--     order lines with optional reviews, dormant/active customer retention,
--     and purchased product review coverage)
--   - Statements 7-8: Multi-column substring text searches (ILIKE '%...%')
--     across customers, products, categories, sellers, and reviews
--
-- Protocol Invariants:
--   - Simple query protocol (-M simple), NO explicit BEGIN...COMMIT.
--   - All literals are interpolated directly by pgbench so 100% of queries
--     pass both PgCache's cacheability check and MV admission gate.
-- ============================================================================

\set t random(1, :tenants)

-- 1. [Aggregation + FILTER] Category & product revenue funnel across 4 tables.
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
 GROUP BY cat.id, cat.name, p.id, p.name
 ORDER BY settled_revenue DESC, cat.id ASC, p.id ASC
 LIMIT 20;

-- 2. [Aggregation + CASE WHEN + HAVING] Seller & product tier performance across 4 tables.
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
 GROUP BY s.id, s.name, s.rating, p.id, p.name
HAVING sum(oi.qty * oi.price) >= 400
 ORDER BY total_revenue DESC, s.id ASC, p.id ASC
 LIMIT 20;

-- 3. [LEFT JOIN + Cohort Aggregation] Customer lifecycle & zero-order cohort.
SELECT c.id AS customer_id, c.name AS customer_name, c.email,
       count(DISTINCT o.id) AS total_orders,
       count(DISTINCT o.id) FILTER (WHERE o.status = 'done') AS done_orders,
       count(DISTINCT o.id) FILTER (WHERE o.status IN ('new', 'paid', 'shipped')) AS active_orders,
       coalesce(sum(oi.qty * oi.price), 0) AS lifetime_revenue,
       coalesce(max(o.total), 0) AS max_order_value
  FROM customer c
  LEFT JOIN orders o      ON o.customer_id = c.id AND o.tenant_id = c.tenant_id
  LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = c.tenant_id
 WHERE c.tenant_id = :t
 GROUP BY c.id, c.name, c.email
 ORDER BY lifetime_revenue DESC, c.id ASC
 LIMIT 15;

-- 4. [6-Table JOIN + LEFT JOIN] Enriched order line items with optional review.
SELECT o.id AS order_id, o.status, o.created_at,
       c.name AS customer_name,
       p.name AS product_name,
       cat.name AS category_name,
       s.name AS seller_name,
       oi.id AS item_id, oi.qty, oi.price,
       coalesce(max(r.rating), 0) AS customer_rating
  FROM orders o
  JOIN customer c    ON c.id = o.customer_id
  JOIN order_item oi ON oi.order_id = o.id
  JOIN product p     ON p.id = oi.product_id
  JOIN category cat  ON cat.id = p.category_id
  JOIN seller s      ON s.id = p.seller_id
  LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = c.id
 WHERE o.tenant_id = :t
 GROUP BY o.id, o.status, o.created_at, c.name, p.name, cat.name, s.name, oi.id, oi.qty, oi.price
 ORDER BY o.created_at DESC, oi.id DESC
 LIMIT 20;

-- 5. [Multi-Hop LEFT JOIN] Customer retention & completed order spend (including 0-order accounts).
SELECT c.id, c.name, c.email,
       count(DISTINCT o.id) AS completed_orders,
       coalesce(sum(oi.qty), 0) AS total_items_bought,
       coalesce(sum(oi.qty * oi.price), 0) AS completed_spend
  FROM customer c
  LEFT JOIN orders o      ON o.customer_id = c.id AND o.tenant_id = c.tenant_id AND o.status = 'done'
  LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = c.tenant_id
 WHERE c.tenant_id = :t
 GROUP BY c.id, c.name, c.email
 ORDER BY completed_spend DESC, c.id ASC
 LIMIT 10;

-- 6. [6-Table JOIN + LEFT JOIN + HAVING] Category x Seller x Product cross-tab with review scores.
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
 GROUP BY cat.name, s.name, p.id, p.name
HAVING count(oi.id) >= 3
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT 20;

-- 7. [Text Search + Multi-Hop LEFT JOIN] Customer directory ILIKE search with lifetime spend.
SELECT c.id, c.name, c.email,
       count(DISTINCT o.id) AS order_cnt,
       coalesce(sum(oi.qty * oi.price), 0) AS lifetime_spend
  FROM customer c
  LEFT JOIN orders o      ON o.customer_id = c.id AND o.tenant_id = c.tenant_id
  LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = c.tenant_id
 WHERE c.tenant_id = :t
   AND (c.name ILIKE '%1%' OR c.email ILIKE '%1%')
 GROUP BY c.id, c.name, c.email
 ORDER BY lifetime_spend DESC, c.id ASC
 LIMIT 15;

-- 8. [Text Search + 6-Table JOIN + LEFT JOIN] Product catalog ILIKE search with review metrics.
SELECT p.id, p.name, cat.name AS category_name, s.name AS seller_name,
       sum(oi.qty) AS total_units,
       sum(oi.qty * oi.price) AS gross_revenue,
       count(r.id) AS review_cnt,
       coalesce(round(avg(r.rating), 2), 0) AS avg_rating
  FROM order_item oi
  JOIN orders o      ON o.id = oi.order_id
  JOIN product p     ON p.id = oi.product_id
  JOIN category cat  ON cat.id = p.category_id
  JOIN seller s      ON s.id = p.seller_id
  LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id
 WHERE oi.tenant_id = :t
   AND p.name ILIKE '%1%'
   AND p.price >= 50
 GROUP BY p.id, p.name, cat.name, s.name
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT 15;
