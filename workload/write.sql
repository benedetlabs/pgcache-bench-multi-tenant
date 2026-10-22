-- ============================================================================
-- The write side of the mix (UPDATE + INSERT).
--
--   pgbench -f dashboard.sql@90 -f write.sql@10 -D tenants=200 -D wtenants=200
--
-- `@weight` is what makes the mix: pgbench picks a script per transaction with
-- the given probability. @90 / @10 is a 10% write ratio.
--
-- ── Why both UPDATE and INSERT ─────────────────────────────────────────────
--
-- 1. `UPDATE orders`: Modifies an existing order belonging to tenant `:t`
--    (`1..:wtenants`), exercising PgCache's logical replication `cdc_update`
--    path on `orders`.
-- 2. `INSERT INTO order_item`: Appends a new line item to an existing order
--    of tenant `:t` (using `order_item_id_seq` starting at 100,000,000),
--    exercising `cdc_insert` on child relations and mutating join cardinality
--    (`COUNT`), item quantities (`SUM(oi.qty)`), and gross revenue
--    (`SUM(oi.qty * oi.price)`).
--
-- Between benchmark trials (`reset_all_pods`), inserted rows (`id >= 100000000`)
-- are cleaned up on Origin so every trial starts from the exact same dataset.
--
-- NO BEGIN/COMMIT here either, for the same reason as the read script.
-- ============================================================================

\set t random(1, :wtenants)
\set n random(0, 200)
\set p random(1, 1000)
\set q random(1, 5)

-- 1. UPDATE existing order total for tenant :t
UPDATE orders SET total = total + 1
 WHERE id IN (
   SELECT id FROM orders WHERE tenant_id = :t ORDER BY id OFFSET :n LIMIT 1
 );

-- 2. INSERT new order_item for an existing order of tenant :t
INSERT INTO order_item (order_id, product_id, qty, price, tenant_id)
SELECT o.id, :p, :q, 49.90, :t
  FROM orders o
 WHERE o.tenant_id = :t
 ORDER BY o.id ASC
OFFSET :n LIMIT 1;
