-- ============================================================================
-- Multi-tenant campaign (mt1) -- step 2 of 2: denormalise the tenant.
--
--   psql -h $ORIGIN_HOST -U $PGUSER -d $PGDATABASE -q -f 02-tenant.sql
--
-- Variables:
--   -v tenants=200 (default: 200 tenants)
--
-- Takes about 45 s on Scale 1: two UPDATEs, one over 500,000 rows and one over 2,000,000.
-- ============================================================================

\if :{?tenants}
\else
  \set tenants 200
\endif

ALTER TABLE orders     ADD COLUMN IF NOT EXISTS tenant_id int;
ALTER TABLE order_item ADD COLUMN IF NOT EXISTS tenant_id int;

UPDATE orders
   SET tenant_id = 1 + (customer_id % :tenants)
 WHERE tenant_id IS NULL;

UPDATE order_item oi
   SET tenant_id = o.tenant_id
  FROM orders o
 WHERE o.id = oi.order_id
   AND oi.tenant_id IS NULL;

ALTER TABLE orders     ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE order_item ALTER COLUMN tenant_id SET NOT NULL;

-- Composite indexes, leading with tenant_id.
CREATE INDEX IF NOT EXISTS orders_tenant_created ON orders(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_tenant_status  ON orders(tenant_id, status);
CREATE INDEX IF NOT EXISTS oitem_tenant_product  ON order_item(tenant_id, product_id);

-- Ensure sequences for live INSERT workloads are attached
CREATE SEQUENCE IF NOT EXISTS orders_id_seq START WITH 100000000;
CREATE SEQUENCE IF NOT EXISTS order_item_id_seq START WITH 100000000;
ALTER TABLE orders ALTER COLUMN id SET DEFAULT nextval('orders_id_seq');
ALTER TABLE order_item ALTER COLUMN id SET DEFAULT nextval('order_item_id_seq');

ANALYZE orders;
ANALYZE order_item;

-- Sanity check
SELECT count(DISTINCT tenant_id) AS tenants,
       count(*) / count(DISTINCT tenant_id) AS orders_per_tenant
  FROM orders;
