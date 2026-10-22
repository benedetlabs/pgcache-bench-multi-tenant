-- ============================================================================
-- Fair Scenario 2: Dynamic Multi-Filter Enterprise Screen (8 Statements)
--
--   pgbench -f complex-dashboard-dynamic.sql -D tenants=200 ...
--
-- Why this tests real-world multi-tenant cache behavior:
--   In complex-dashboard.sql, only :t (tenant_id) changes between requests, so
--   every tenant has only 1 static query variant per widget (200 tenants =
--   200 cache keys per query).
--   Here, users within each tenant also vary their filters across requests:
--     - :min_rev    (4 revenue thresholds: 200, 400, 600, 800)
--     - :min_price  (5 price thresholds: 20, 40, 60, 80, 100)
--     - :min_rating (3 rating thresholds: 2, 3, 4)
--     - :min_cnt    (4 item-count thresholds: 2, 3, 4, 5)
--     - :lim        (3 page-size limits: 10, 15, 20)
--   All queries remain 100% compliant with PgCache's simple protocol and
--   Materialized View admission gate, while testing whether PgCache's MV
--   engine can serve parameterized filter variations or must populate per-filter keys.
-- ============================================================================

\set t random(1, :tenants)
\set rev_idx random(1, 4)
\set min_rev (200 * :rev_idx)
\set p_idx random(1, 5)
\set min_price (20 * :p_idx)
\set min_rating random(2, 4)
\set min_cnt random(2, 5)
\set l_idx random(2, 4)
\set lim (5 * :l_idx)

-- 1. [Aggregation + FILTER] Category & product revenue funnel with dynamic limit (:lim).
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
   AND p.price >= :min_price
 GROUP BY cat.id, cat.name, p.id, p.name
 ORDER BY settled_revenue DESC, cat.id ASC, p.id ASC
 LIMIT :lim;

-- 2. [Aggregation + CASE WHEN + HAVING] Seller & product tier performance with dynamic HAVING (:min_rev).
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
   AND s.rating >= :min_rating
 GROUP BY s.id, s.name, s.rating, p.id, p.name
HAVING sum(oi.qty * oi.price) >= :min_rev
 ORDER BY total_revenue DESC, s.id ASC, p.id ASC
 LIMIT :lim;

-- 3. [LEFT JOIN + Cohort Aggregation] Customer lifecycle & zero-order cohort with dynamic limit (:lim).
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
 LIMIT :lim;

-- 4. [6-Table JOIN + LEFT JOIN] Enriched order line items filtered by dynamic item price (:min_price).
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
   AND oi.tenant_id = :t
   AND c.tenant_id = :t
   AND oi.price >= :min_price
 GROUP BY o.id, o.status, o.created_at, c.name, p.name, cat.name, s.name, oi.id, oi.qty, oi.price
 ORDER BY o.created_at DESC, oi.id DESC
 LIMIT :lim;

-- 5. [Multi-Hop LEFT JOIN] Customer retention & completed order spend.
SELECT c.id, c.name, c.email,
       count(DISTINCT o.id) AS completed_orders,
       coalesce(sum(oi.qty), 0) AS total_items_bought,
       coalesce(sum(oi.qty * oi.price), 0) AS completed_spend
  FROM customer c
  LEFT JOIN orders o      ON o.customer_id = c.id AND o.tenant_id = :t AND o.status = 'done'
  LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = :t
 WHERE c.tenant_id = :t
 GROUP BY c.id, c.name, c.email
 ORDER BY completed_spend DESC, c.id ASC
 LIMIT :lim;

-- 6. [6-Table JOIN + LEFT JOIN + HAVING] Category x Seller x Product cross-tab with dynamic HAVING (:min_cnt).
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
HAVING count(oi.id) >= :min_cnt
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT :lim;

-- 7. [Trigram Text Search + Multi-Hop LEFT JOIN] Customer directory search with 6-char trigram term.
SELECT c.id, c.name, c.email,
       count(DISTINCT o.id) AS order_cnt,
       coalesce(sum(oi.qty * oi.price), 0) AS lifetime_spend
  FROM customer c
  LEFT JOIN orders o      ON o.customer_id = c.id AND o.tenant_id = :t
  LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = :t
 WHERE c.tenant_id = :t
   AND (c.name ILIKE '%cust12%' OR c.email ILIKE '%c12%')
 GROUP BY c.id, c.name, c.email
 ORDER BY lifetime_spend DESC, c.id ASC
 LIMIT :lim;

-- 8. [Trigram Text Search + 6-Table JOIN + Dynamic Price] Product catalog search with trigram term & :min_price.
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
   AND o.tenant_id = :t
   AND p.name ILIKE '%product 12%'
   AND p.price >= :min_price
 GROUP BY p.id, p.name, cat.name, s.name
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT :lim;
