-- ============================================================================
-- Fair Scenario 1: Trigram-Indexable Multi-Tenant Text Search (3+ Char Terms)
--
--   pgbench -f complex-search-fair.sql -D tenants=200 ...
--
-- Why this is a fairer test for PostgreSQL:
--   In complex-search.sql, predicates like ILIKE '%1%' have only 1 character,
--   which prevents PostgreSQL's pg_trgm GIN index from extracting 3-character
--   trigrams and matches ~50% of all rows.
--   Here, every ILIKE predicate uses realistic 5-to-9 character search terms
--   ('%cust12%', '%product 12%', '%number 12%', '%c12%') so PostgreSQL's
--   GIN (gin_trgm_ops) index can perform fast bitmap trigram lookups.
-- ============================================================================

\set t random(1, :tenants)

-- 1. Customer directory search using 6-char trigram term ('%cust12%' / '%c12%').
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
 LIMIT 15;

-- 2. Product catalog search using 10-char trigram term ('%product 12%').
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
   AND p.price >= 50
 GROUP BY p.id, p.name, cat.name, s.name
 ORDER BY gross_revenue DESC, p.id ASC
 LIMIT 15;

-- 3. Review body text search using 9-char trigram term ('%number 12%').
SELECT r.id, r.rating, r.body,
       p.name AS product_name,
       cat.name AS category_name,
       c.name AS customer_name,
       count(o.id) AS customer_done_orders
  FROM review r
  JOIN customer c    ON c.id = r.customer_id
  JOIN product p     ON p.id = r.product_id
  JOIN category cat  ON cat.id = p.category_id
  LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = :t AND o.status = 'done'
 WHERE c.tenant_id = :t
   AND r.body ILIKE '%number 12%'
   AND r.rating >= 2
 GROUP BY r.id, r.rating, r.body, p.name, cat.name, c.name
 ORDER BY r.rating DESC, customer_done_orders DESC, r.id ASC
 LIMIT 15;

-- 4. Cross-entity order fulfilment search with trigram terms.
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
   AND oi.tenant_id = :t
   AND c.tenant_id = :t
   AND (p.name ILIKE '%product 25%' OR c.email ILIKE '%c25%')
   AND o.total >= 50
 GROUP BY o.id, o.status, o.created_at, c.name, p.name, cat.name
 ORDER BY o.created_at DESC, o.id DESC, p.name ASC
 LIMIT 15;
