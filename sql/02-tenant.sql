-- ============================================================================
-- Multi-tenant campaign (mt1) -- step 2 of 2: denormalise the tenant.
--
--   psql -h $ORIGIN_HOST -U $PGUSER -d $PGDATABASE -q -f 02-tenant.sql
--
-- Takes about 45 s: two UPDATEs, one over 500,000 rows and one over 2,000,000.
--
-- WHY DENORMALISE
--
-- After step 1, only `customer` carries tenant_id. An order's tenant is
-- reachable only by joining back through customer, and a line item's by joining
-- twice. Real multi-tenant applications do not do that -- they copy tenant_id
-- onto every table precisely so that every query can filter on it directly,
-- with one index, without a join.
--
-- This matters for the experiment and not just for realism: if the tenant
-- filter required a join, we would be measuring the cost of that join instead
-- of the cost of tenant-scoped access, and the "does tenant count explode the
-- query space" question would be confounded by it.
--
-- The value is COMPUTED, not joined: customer_id determines tenant_id by
-- construction in step 1 (tenant_id = 1 + (id % 200)), so the arithmetic below
-- reproduces it exactly and the second UPDATE only needs the order's own row.
-- ============================================================================

ALTER TABLE orders     ADD COLUMN IF NOT EXISTS tenant_id int;
ALTER TABLE order_item ADD COLUMN IF NOT EXISTS tenant_id int;

UPDATE orders
   SET tenant_id = 1 + ((customer_id - 1) % 200)
 WHERE tenant_id IS NULL;

UPDATE order_item oi
   SET tenant_id = o.tenant_id
  FROM orders o
 WHERE o.id = oi.order_id
   AND oi.tenant_id IS NULL;

ALTER TABLE orders     ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE order_item ALTER COLUMN tenant_id SET NOT NULL;

-- Composite indexes, leading with tenant_id.
--
-- The dashboard's most expensive statement is "the tenant's most recent orders,
-- newest first". A plain index on tenant_id would find the tenant's 2,500 rows
-- and then sort them. Leading with tenant_id and following with created_at DESC
-- lets the planner walk the index in order and stop at LIMIT 20.
--
-- This is a decision that favours the ORIGIN. Without it the origin would be
-- slower and PgCache would look better, which is exactly the kind of accidental
-- advantage a benchmark has to refuse.
CREATE INDEX IF NOT EXISTS orders_tenant_created ON orders(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_tenant_status  ON orders(tenant_id, status);
CREATE INDEX IF NOT EXISTS oitem_tenant_product  ON order_item(tenant_id, product_id);

ANALYZE orders;
ANALYZE order_item;

-- Sanity check. Expect: 200 tenants, 2500 orders each.
SELECT count(DISTINCT tenant_id) AS tenants,
       count(*) / count(DISTINCT tenant_id) AS orders_per_tenant
  FROM orders;
