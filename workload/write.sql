-- ============================================================================
-- The write side of the mix.
--
--   pgbench -f dashboard.sql@90 -f write.sql@10 -D tenants=200 -D wtenants=200
--
-- `@weight` is what makes the mix: pgbench picks a script per transaction with
-- the given probability. @90 / @10 is a 10% write ratio.
--
-- ── Why this statement and not something simpler ───────────────────────────
--
-- The obvious write is `UPDATE orders SET ... WHERE id = :random_id`. It was
-- rejected because it does not respect the tenant: a random id belongs to a
-- random tenant, so :wtenants would have no effect and the concentration sweep
-- would measure nothing.
--
-- The subquery picks a row that genuinely belongs to tenant :t, using the
-- (tenant_id, ...) index and an OFFSET to vary which one. It is also the shape
-- an ORM actually produces -- find the record, then update it.
--
-- ── :wtenants is the second independent variable ───────────────────────────
--
-- Reads draw tenants from 1..:tenants (200). Writes draw from 1..:wtenants.
-- Setting wtenants=1 concentrates every write on a single tenant while reads
-- span all 200; wtenants=200 spreads writes across the same range the reads
-- cover.
--
-- The hypothesis this was built to test: campaign s4 had reads and writes over
-- the SAME 1,000 keys -- the worst possible case for invalidation -- and the
-- cache's advantage vanished there. Real applications write to a small subset
-- and read from a large one. If concentration were the explanation, wtenants=1
-- should look much better than wtenants=200.
--
-- It did not. The two differ by 29 percentage points on a gain of ~950%, which
-- is barely above this campaign's measured run-to-run noise. The hypothesis was
-- wrong, and the real variable turned out to be the ratio of read cost to write
-- cost. See the article for the arithmetic.
--
-- NO BEGIN/COMMIT here either, for the same reason as the read script.
-- ============================================================================

\set t random(1, :wtenants)
\set n random(0, 2000)

UPDATE orders SET total = total + 1
 WHERE id IN (
   SELECT id FROM orders WHERE tenant_id = :t ORDER BY id OFFSET :n LIMIT 1
 );
