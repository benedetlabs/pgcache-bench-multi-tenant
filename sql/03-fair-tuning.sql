-- ============================================================================
-- Multi-tenant campaign -- step 3 (Fair-Tuning Profile):
-- Production-grade GIN trigram indexes (`pg_trgm`) and buffer prewarming for
-- PostgreSQL Origin.
--
-- Run against the ORIGIN, not through PgCache:
--   psql -h $ORIGIN_HOST -U $PGUSER -d $PGDATABASE -q -f 03-fair-tuning.sql
--
-- Architectural Note (Why Only GIN Trigram Indexes Are Added Here):
--   1. Adding wide B-tree INCLUDE covering indexes + random_page_cost=0.1
--      causes PostgreSQL's planner to replace fast Hash Joins with 10,000-row
--      Nested Loops on 6-table joins (slowing Origin down by 3x).
--   2. Furthermore, PgCache clones all B-tree indexes from Origin into its
--      internal `pgcache_cache` database (`cache_table_create_from_metadata`).
--      Adding 6 wide B-tree INCLUDE indexes bloats PgCache's internal index
--      maintenance during population (see results/0.7.1/06-fair-overindexed-k8s.txt).
--   3. By contrast, GIN `pg_trgm` indexes accelerate 3+ character `ILIKE`
--      substring searches on Origin by ~2x without altering Hash Join plans or
--      bloating PgCache's internal B-tree indexes.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;

-- Set in-memory planner random_page_cost (0.2) since 100% of the 371 MB dataset
-- is prewarmed in 2 GiB shared_buffers, ensuring Index Scans on category_pkey
-- and seller_pkey are chosen over 10,000-iteration Nested Loop Seq Scans.
ALTER DATABASE bench SET random_page_cost = 0.2;
ALTER SYSTEM SET random_page_cost = 0.2;
SELECT pg_reload_conf();

-- Remove wide B-tree INCLUDE indexes that degrade Hash Join plans and bloat PgCache population
DROP INDEX IF EXISTS
  idx_product_id_cov,
  idx_product_id_name_cov,
  idx_oitem_tenant_order_cov,
  idx_oitem_tenant_prod_order_cov,
  idx_oitem_tenant_order_prod_cov,
  idx_oitem_tenant_id_desc,
  idx_oitem_tenant_prod_cov,
  idx_orders_tenant_cust_status_cov,
  idx_orders_tenant_cov,
  idx_customer_tenant_id_cov,
  idx_customer_tenant_cov,
  idx_review_prod_cust_cov,
  idx_oitem_tenant_cov;

-- 1. GIN Trigram Indexes for Substring Text Search (ILIKE '%...%')
CREATE INDEX IF NOT EXISTS idx_customer_name_trgm  ON customer USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_customer_email_trgm ON customer USING gin (email gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_product_name_trgm   ON product  USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_review_body_trgm    ON review   USING gin (body gin_trgm_ops);

ANALYZE customer;
ANALYZE product;
ANALYZE orders;
ANALYZE order_item;
ANALYZE review;
ANALYZE seller;
ANALYZE category;

-- Prewarm all public tables and indexes into PostgreSQL shared_buffers
SELECT count(pg_prewarm(oid)) AS prewarmed_relations
  FROM pg_class
 WHERE relnamespace = 'public'::regnamespace
   AND relkind IN ('r', 'i');
