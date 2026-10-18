-- ============================================================================
-- Complex Scenario 1: Multi-Tenant Text Search & Substring Matching
--
--   pgbench -f complex-search.sql -D tenants=200 ...
--
-- Evaluates substring text search (ILIKE '%...%') combined with multi-table
-- JOINs, LEFT JOINs, and aggregations scoped per tenant_id.
--
-- Why this stresses Origin:
--   Leading-wildcard ILIKE predicates ('%...%') cannot use standard B-tree
--   indexes for prefix range scans. Origin must scan all qualifying tenant
--   rows, evaluate case-insensitive substring matching across text columns
--   (customer.name, customer.email, product.name, category.name, review.body),
--   join related relations, and sort the aggregated results.
--
-- Protocol Invariants:
--   - Simple query protocol (-M simple), NO explicit BEGIN...COMMIT.
--   - All literals are interpolated directly by pgbench so 100% of queries
--     pass both PgCache's cacheability check and MV admission gate.
-- ============================================================================

\set t random(1, :tenants)

-- 1. Customer directory search with lifetime order count and item spend.
--    Uses multi-hop LEFT JOIN (customer -> orders -> order_item) so matching
--    customers with zero orders are still returned with 0 spend.
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

-- 2. Product catalog search across tenant line items with category, seller,
--    and optional customer review aggregations (6-table JOIN + LEFT JOIN + ILIKE).
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

-- 3. Review body text search scoped to tenant customers, enriched with product
--    category and customer completed-order count (JOIN + LEFT JOIN + ILIKE).
SELECT r.id, r.rating, r.body,
       p.name AS product_name,
       cat.name AS category_name,
       c.name AS customer_name,
       count(o.id) AS customer_done_orders
  FROM review r
  JOIN customer c    ON c.id = r.customer_id
  JOIN product p     ON p.id = r.product_id
  JOIN category cat  ON cat.id = p.category_id
  LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = c.tenant_id AND o.status = 'done'
 WHERE c.tenant_id = :t
   AND r.body ILIKE '%1%'
   AND r.rating >= 2
 GROUP BY r.id, r.rating, r.body, p.name, cat.name, c.name
 ORDER BY r.rating DESC, customer_done_orders DESC, r.id ASC
 LIMIT 15;

-- 4. Cross-entity order fulfilment search matching product or customer emails
--    across 5 joined tables with line-item aggregation.
SELECT o.id AS order_id, o.status, o.created_at,
       c.name AS customer_name,
       p.name AS product_name,
       cat.name AS category_name,
       sum(oi.qty) AS total_qty,
       sum(oi.qty * oi.price) AS line_total
  FROM orders o
  JOIN customer c    ON c.id = o.customer_id
  JOIN order_item oi ON oi.order_id = o.id
  JOIN product p     ON p.id = oi.product_id
  JOIN category cat  ON cat.id = p.category_id
 WHERE o.tenant_id = :t
   AND (p.name ILIKE '%2%' OR c.email ILIKE '%2%')
   AND o.total >= 50
 GROUP BY o.id, o.status, o.created_at, c.name, p.name, cat.name
 ORDER BY o.created_at DESC, o.id DESC, p.name ASC
 LIMIT 15;
