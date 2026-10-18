-- ============================================================================
-- Complex Scenario 2: Deep Multi-Table JOIN & LEFT JOIN Workload (4-6 Tables)
--
--   pgbench -f complex-joins.sql -D tenants=200 ...
--
-- Evaluates deep relational join chains (4 to 6 tables) combining INNER JOIN
-- and LEFT JOIN patterns typical of normalized SaaS schemas.
--
-- Why this stresses Origin:
--   1. Multi-hop foreign key joins across orders, customer, order_item,
--      product, category, seller, and review require nested loop / hash join
--      execution across multiple relations per request.
--   2. Outer joins (LEFT JOIN) preserve parent rows with zero matching child
--      records (e.g., customers with no completed orders, purchased products
--      with no customer reviews), preventing join-elimination shortcuts.
--
-- Protocol Invariants:
--   - Simple query protocol (-M simple), NO explicit BEGIN...COMMIT.
--   - All literals are interpolated directly by pgbench so 100% of queries
--     pass both PgCache's cacheability check and MV admission gate.
-- ============================================================================

\set t random(1, :tenants)

-- 1. 6-table enriched order line view with optional customer product review.
--    Joins orders -> customer -> order_item -> product -> category -> seller
--    and LEFT JOINs review (matching both product_id and customer_id).
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

-- 2. Customer retention & dormancy view (customer LEFT JOIN orders LEFT JOIN order_item).
--    Preserves customers who have zero completed ('done') orders so account
--    managers can inspect both active and dormant accounts in the tenant.
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

-- 3. Purchased product coverage with unreviewed inventory detection.
--    5-table INNER JOIN + LEFT JOIN review scoped to tenant purchases.
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
 GROUP BY p.id, p.name, cat.name, s.name
 ORDER BY units_sold DESC, gross_revenue DESC, p.id ASC
 LIMIT 20;

-- 4. Seller-to-category product fulfilment & customer feedback matrix (6 tables).
--    Joins seller, product, category, order_item, orders, and LEFT JOIN review.
SELECT s.id AS seller_id, s.name AS seller_name, s.rating AS seller_rating,
       cat.name AS category_name,
       p.id AS product_id, p.name AS product_name,
       count(DISTINCT o.id) AS order_count,
       sum(oi.qty * oi.price) AS gross_sales,
       count(r.id) AS feedback_count,
       coalesce(round(avg(r.rating), 2), 0) AS avg_feedback_score
  FROM seller s
  JOIN product p     ON p.seller_id = s.id
  JOIN category cat  ON cat.id = p.category_id
  JOIN order_item oi ON oi.product_id = p.id
  JOIN orders o      ON o.id = oi.order_id
  LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id
 WHERE oi.tenant_id = :t
   AND s.rating >= 3
 GROUP BY s.id, s.name, s.rating, cat.name, p.id, p.name
 ORDER BY gross_sales DESC, s.id ASC, p.id ASC
 LIMIT 20;
