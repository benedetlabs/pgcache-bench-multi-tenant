#!/usr/bin/env bash
# ============================================================================
# Differential Result Correctness, Cacheability, MV Admission & Post-CDC Gate
#
# Verifies four mandatory invariants across all multi-tenant workloads:
#   1. Baseline Cacheability & Correctness (8 queries from dashboard.sql):
#      100% cacheable (pgcache_queries_uncacheable == 0) and byte-for-byte
#      identical rows between Origin and PgCache.
#   2. Complex Cacheability & MV Admission Gate (12 queries from complex-*.sql):
#      100% cacheable (pgcache_queries_uncacheable == 0), 100% admitted by
#      PgCache's Materialized View gate (pgcache_cache_mv_gate{outcome="admit"} == 12,
#      reject == 0), and 100% served from MVs on Pass 3 (pgcache_cache_mv_hits == 12).
#   3. Static Differential Correctness (Pass 1, Pass 2, Pass 3):
#      Every query returns byte-for-byte identical rows from Origin and PgCache
#      on initial miss, base-table hit, and warm Materialized View hit.
#   4. Post-CDC Live Mutation Differential Correctness (Pass 4):
#      Applies live UPDATE mutations to `orders` and `order_item` on Origin for
#      tenant 13, waits for logical replication CDC propagation, and verifies
#      that all 12 complex queries (both in-place INNER JOIN MVs and invalidated/
#      rebuilt LEFT JOIN MVs) remain 100% byte-for-byte identical to Origin
#      with zero stale reads, before restoring Origin state.
# ============================================================================

set -euo pipefail
source "$(dirname "$0")/lib.sh"

ensure_workload_scripts
reset_pgcache

echo "========================================================================"
echo " Running Differential Correctness, Cacheability & Post-CDC Gate ($BENCH_ENV)"
echo "========================================================================"

read_counters() {
  if [ "$BENCH_ENV" = "docker" ]; then
    curl -sf --connect-timeout 5 http://127.0.0.1:59090/metrics | awk '
      /^pgcache_queries_cacheable /                  {c=$2}
      /^pgcache_queries_uncacheable /                {u=$2}
      /^pgcache_queries_cache_hit /                  {h=$2}
      /^pgcache_queries_cache_miss /                 {m=$2}
      /^pgcache_queries_cache_error /                {e=$2}
      /^pgcache_cache_mv_gate\{outcome="admit"\}/    {a=$2}
      /^pgcache_cache_mv_gate\{outcome="reject"\}/   {r=$2}
      /^pgcache_cache_mv_hits /                      {mvh=$2}
      /^pgcache_cdc_events_processed /               {cdc=$2}
      END { printf "%d %d %d %d %d %d %d %d %d\n", c+0, u+0, h+0, m+0, e+0, a+0, r+0, mvh+0, cdc+0 }'
  else
    local ip; ip="$(pgcache_ip)"
    local mport="${PGCACHE_METRICS_PORT:-${CACHED_PGCACHE_MPORT:-}}"
    if [ -z "$mport" ]; then
      mport=$(kubectl -n "$NS" get svc pgcache -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "9091")
      [ -z "$mport" ] && mport="9091"
    fi
    kubectl -n "$NS" exec deploy/metrics-reader -- \
      sh -c "wget -qO- --timeout=20 http://$ip:$mport/metrics" 2>/dev/null | awk '
      /^pgcache_queries_cacheable /                  {c=$2}
      /^pgcache_queries_uncacheable /                {u=$2}
      /^pgcache_queries_cache_hit /                  {h=$2}
      /^pgcache_queries_cache_miss /                 {m=$2}
      /^pgcache_queries_cache_error /                {e=$2}
      /^pgcache_cache_mv_gate\{outcome="admit"\}/    {a=$2}
      /^pgcache_cache_mv_gate\{outcome="reject"\}/   {r=$2}
      /^pgcache_cache_mv_hits /                      {mvh=$2}
      /^pgcache_cdc_events_processed /               {cdc=$2}
      END { printf "%d %d %d %d %d %d %d %d %d\n", c+0, u+0, h+0, m+0, e+0, a+0, r+0, mvh+0, cdc+0 }'
  fi
}

# ── Part 1: Baseline Operational Queries (workload/dashboard.sql) ──────────
BASELINE_QUERIES=(
  # 1. [dashboard #1] Order counts by status
  "SELECT status, count(*) FROM orders WHERE tenant_id = 13 GROUP BY status ORDER BY status ASC;"
  # 2. [dashboard #2] Revenue and order count
  "SELECT sum(total), count(*) FROM orders WHERE tenant_id = 13;"
  # 3. [dashboard #3] Customer count
  "SELECT count(*) FROM customer WHERE tenant_id = 13;"
  # 4. [dashboard #4] Recent orders page (with pre-computed literal OFFSET)
  "SELECT id, status, total, created_at FROM orders WHERE tenant_id = 13 ORDER BY created_at DESC, id DESC LIMIT 20 OFFSET 20;"
  # 5. [dashboard #5] Filtered status & tier count badge
  "SELECT count(*) FROM orders WHERE tenant_id = 13 AND status = 'done' AND total >= 100;"
  # 6. [dashboard #6] Recent orders with customer name
  "SELECT o.id, o.total, c.name FROM orders o JOIN customer c ON c.id = o.customer_id WHERE o.tenant_id = 13 AND c.tenant_id = 13 ORDER BY o.created_at DESC, o.id DESC LIMIT 10;"
  # 7. [dashboard #7] Top products for the tenant
  "SELECT p.id, p.name, sum(oi.qty) AS total_qty FROM order_item oi JOIN product p ON p.id = oi.product_id WHERE oi.tenant_id = 13 GROUP BY p.id, p.name ORDER BY total_qty DESC, p.id ASC LIMIT 10;"
  # 8. [dashboard #8] Line items page with product names
  "SELECT oi.id, oi.qty, oi.price, p.name FROM order_item oi JOIN product p ON p.id = oi.product_id WHERE oi.tenant_id = 13 ORDER BY oi.id DESC LIMIT 20 OFFSET 20;"
)

echo "--> [Stage 1/3] Checking 8 Baseline Queries (workload/dashboard.sql)..."
read -r bc0 bu0 bh0 bm0 be0 ba0 br0 bmvh0 bcdc0 <<<"$(read_counters)"

B_PASS=0
B_FAIL=0
B_IDX=0
for q in "${BASELINE_QUERIES[@]}"; do
  B_IDX=$((B_IDX + 1))
  orig_out=$(ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  cache_out1=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  cache_out2=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  if [ "$orig_out" = "$cache_out1" ] && [ "$orig_out" = "$cache_out2" ]; then
    rows=$(printf "%s\n" "$orig_out" | sed '/^$/d' | wc -l | tr -d ' ')
    printf "  [PASS] Baseline Query #%-2d: Origin == PgCache (pass 1 & 2 identical, %s rows)\n" "$B_IDX" "$rows"
    B_PASS=$((B_PASS + 1))
  else
    printf "  [FAIL] Baseline Query #%-2d: Output divergence detected!\n" "$B_IDX" >&2
    diff -u <(printf "%s\n" "$orig_out") <(printf "%s\n" "$cache_out2") >&2 || true
    B_FAIL=$((B_FAIL + 1))
  fi
done

read -r bc1 bu1 bh1 bm1 be1 ba1 br1 bmvh1 bcdc1 <<<"$(read_counters)"
bu_delta=$((bu1 - bu0))
be_delta=$((be1 - be0))
printf "  Baseline Summary: %d/%d passed | Uncacheable delta: %d | Errors delta: %d\n" \
  "$B_PASS" "$B_IDX" "$bu_delta" "$be_delta"

if [ "$B_FAIL" -ne 0 ] || [ "$bu_delta" -ne 0 ] || [ "$be_delta" -ne 0 ]; then
  die "Baseline dashboard correctness or cacheability check failed!"
fi

# ── Part 2: Complex Multi-Tenant Queries (workload/complex-*.sql) ──────────
reset_pgcache
echo ""
echo "--> [Stage 2/3] Checking 12 Complex Queries (Pass 1 Miss -> Pass 2 Base Hit/MV Build -> Pass 3 Warm MV Hit)..."

QUERIES=(
  # 1. [complex-search #1 / complex-dashboard #7] Text search + multi-hop LEFT JOIN (customer directory search)
  "SELECT c.id, c.name, c.email, count(DISTINCT o.id) AS order_cnt, coalesce(sum(oi.qty * oi.price), 0) AS lifetime_spend FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = 13 LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = 13 WHERE c.tenant_id = 13 AND (c.name ILIKE '%1%' OR c.email ILIKE '%1%') GROUP BY c.id, c.name, c.email ORDER BY lifetime_spend DESC, c.id ASC LIMIT 15;"
  # 2. [complex-search #2 / complex-dashboard #8] Text search + 6-table JOIN + LEFT JOIN (product catalog search)
  "SELECT p.id, p.name, cat.name AS category_name, s.name AS seller_name, sum(oi.qty) AS total_units, sum(oi.qty * oi.price) AS gross_revenue, count(r.id) AS review_cnt, coalesce(round(avg(r.rating), 2), 0) AS avg_rating FROM order_item oi JOIN orders o ON o.id = oi.order_id JOIN product p ON p.id = oi.product_id JOIN category cat ON cat.id = p.category_id JOIN seller s ON s.id = p.seller_id LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id WHERE oi.tenant_id = 13 AND o.tenant_id = 13 AND p.name ILIKE '%1%' AND p.price >= 50 GROUP BY p.id, p.name, cat.name, s.name ORDER BY gross_revenue DESC, p.id ASC LIMIT 15;"
  # 3. [complex-search #3] Text search + review body + LEFT JOIN completed orders
  "SELECT r.id, r.rating, r.body, p.name AS product_name, cat.name AS category_name, c.name AS customer_name, count(o.id) AS customer_done_orders FROM review r JOIN customer c ON c.id = r.customer_id JOIN product p ON p.id = r.product_id JOIN category cat ON cat.id = p.category_id LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = 13 AND o.status = 'done' WHERE c.tenant_id = 13 AND r.body ILIKE '%1%' AND r.rating >= 2 GROUP BY r.id, r.rating, r.body, p.name, cat.name, c.name ORDER BY r.rating DESC, customer_done_orders DESC, r.id ASC LIMIT 15;"
  # 4. [complex-search #4] Cross-entity order fulfilment text search across 5 joined tables
  "SELECT o.id AS order_id, o.status, o.created_at, c.name AS customer_name, p.name AS product_name, cat.name AS category_name, sum(oi.qty) AS total_qty, sum(oi.qty * oi.price) AS line_total FROM orders o JOIN customer c ON c.id = o.customer_id JOIN order_item oi ON oi.order_id = o.id JOIN product p ON p.id = oi.product_id JOIN category cat ON cat.id = p.category_id WHERE o.tenant_id = 13 AND oi.tenant_id = 13 AND c.tenant_id = 13 AND (p.name ILIKE '%2%' OR c.email ILIKE '%2%') AND o.total >= 50 GROUP BY o.id, o.status, o.created_at, c.name, p.name, cat.name ORDER BY o.created_at DESC, o.id DESC, p.name ASC LIMIT 15;"
  # 5. [complex-joins #1 / complex-dashboard #4] 6-table JOIN + LEFT JOIN enriched order lines
  "SELECT o.id AS order_id, o.status, o.created_at, c.name AS customer_name, p.name AS product_name, cat.name AS category_name, s.name AS seller_name, oi.id AS item_id, oi.qty, oi.price, coalesce(max(r.rating), 0) AS customer_rating FROM orders o JOIN customer c ON c.id = o.customer_id JOIN order_item oi ON oi.order_id = o.id JOIN product p ON p.id = oi.product_id JOIN category cat ON cat.id = p.category_id JOIN seller s ON s.id = p.seller_id LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = c.id WHERE o.tenant_id = 13 AND oi.tenant_id = 13 AND c.tenant_id = 13 GROUP BY o.id, o.status, o.created_at, c.name, p.name, cat.name, s.name, oi.id, oi.qty, oi.price ORDER BY o.created_at DESC, oi.id DESC LIMIT 20;"
  # 6. [complex-joins #2 / complex-dashboard #5] Multi-hop LEFT JOIN customer retention (preserving 0-order accounts)
  "SELECT c.id, c.name, c.email, count(DISTINCT o.id) AS completed_orders, coalesce(sum(oi.qty), 0) AS total_items_bought, coalesce(sum(oi.qty * oi.price), 0) AS completed_spend FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = 13 AND o.status = 'done' LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = 13 WHERE c.tenant_id = 13 GROUP BY c.id, c.name, c.email ORDER BY completed_spend DESC, c.id ASC LIMIT 10;"
  # 7. [complex-joins #3] Purchased product coverage with unreviewed inventory detection (6 tables)
  "SELECT p.id, p.name AS product_name, cat.name AS category_name, s.name AS seller_name, count(DISTINCT o.customer_id) AS unique_buyers, sum(oi.qty) AS units_sold, sum(oi.qty * oi.price) AS gross_revenue, count(r.id) AS tenant_reviews, coalesce(round(avg(r.rating), 2), 0) AS avg_tenant_rating FROM order_item oi JOIN orders o ON o.id = oi.order_id JOIN product p ON p.id = oi.product_id JOIN category cat ON cat.id = p.category_id JOIN seller s ON s.id = p.seller_id LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id WHERE oi.tenant_id = 13 AND o.tenant_id = 13 GROUP BY p.id, p.name, cat.name, s.name ORDER BY units_sold DESC, gross_revenue DESC, p.id ASC LIMIT 20;"
  # 8. [complex-joins #4] Seller-to-category product fulfilment & customer feedback matrix (6 tables)
  "SELECT s.id AS seller_id, s.name AS seller_name, s.rating AS seller_rating, cat.name AS category_name, p.id AS product_id, p.name AS product_name, count(DISTINCT o.id) AS order_count, sum(oi.qty * oi.price) AS gross_sales, count(r.id) AS feedback_count, coalesce(round(avg(r.rating), 2), 0) AS avg_feedback_score FROM seller s JOIN product p ON p.seller_id = s.id JOIN category cat ON cat.id = p.category_id JOIN order_item oi ON oi.product_id = p.id JOIN orders o ON o.id = oi.order_id LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id WHERE oi.tenant_id = 13 AND o.tenant_id = 13 AND s.rating >= 3 GROUP BY s.id, s.name, s.rating, cat.name, p.id, p.name ORDER BY gross_sales DESC, s.id ASC, p.id ASC LIMIT 20;"
  # 9. [complex-analytics #1 / complex-dashboard #1] Conditional aggregation with FILTER (WHERE ...)
  "SELECT cat.id AS category_id, cat.name AS category_name, p.id AS product_id, p.name AS product_name, count(DISTINCT o.id) AS total_orders, count(DISTINCT o.id) FILTER (WHERE o.status = 'done') AS done_orders, count(DISTINCT o.id) FILTER (WHERE o.status = 'new') AS pending_orders, coalesce(sum(oi.qty * oi.price) FILTER (WHERE o.status IN ('paid', 'shipped', 'done')), 0) AS settled_revenue, round(avg(oi.qty * oi.price), 2) AS avg_item_revenue FROM order_item oi JOIN orders o ON o.id = oi.order_id JOIN product p ON p.id = oi.product_id JOIN category cat ON cat.id = p.category_id WHERE oi.tenant_id = 13 AND o.tenant_id = 13 GROUP BY cat.id, cat.name, p.id, p.name ORDER BY settled_revenue DESC, cat.id ASC, p.id ASC LIMIT 20;"
  # 10. [complex-analytics #2 / complex-dashboard #2] Seller & product rollup with CASE WHEN ticket buckets and HAVING
  "SELECT s.id AS seller_id, s.name AS seller_name, s.rating AS seller_rating, p.id AS product_id, p.name AS product_name, count(DISTINCT o.id) AS order_cnt, count(DISTINCT o.customer_id) AS unique_buyers, sum(CASE WHEN oi.price >= 200 THEN oi.qty * oi.price ELSE 0 END) AS high_ticket_revenue, sum(CASE WHEN oi.price < 200 THEN oi.qty * oi.price ELSE 0 END) AS standard_ticket_revenue, sum(oi.qty * oi.price) AS total_revenue FROM order_item oi JOIN orders o ON o.id = oi.order_id JOIN product p ON p.id = oi.product_id JOIN seller s ON s.id = p.seller_id WHERE oi.tenant_id = 13 AND o.tenant_id = 13 GROUP BY s.id, s.name, s.rating, p.id, p.name HAVING sum(oi.qty * oi.price) >= 400 ORDER BY total_revenue DESC, s.id ASC, p.id ASC LIMIT 20;"
  # 11. [complex-analytics #3 / complex-dashboard #3] Customer lifecycle cohort with multi-hop LEFT JOIN + FILTER (preserving 0-order accounts)
  "SELECT c.id AS customer_id, c.name AS customer_name, c.email, count(DISTINCT o.id) AS total_orders, count(DISTINCT o.id) FILTER (WHERE o.status = 'done') AS done_orders, count(DISTINCT o.id) FILTER (WHERE o.status IN ('new', 'paid', 'shipped')) AS active_orders, coalesce(sum(oi.qty * oi.price), 0) AS lifetime_revenue, coalesce(max(o.total), 0) AS max_order_value FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = 13 LEFT JOIN order_item oi ON oi.order_id = o.id AND oi.tenant_id = 13 WHERE c.tenant_id = 13 GROUP BY c.id, c.name, c.email ORDER BY lifetime_revenue DESC, c.id ASC LIMIT 15;"
  # 12. [complex-analytics #4 / complex-dashboard #6] Category x Seller x Product cross-tabulation with review quality score and HAVING
  "SELECT cat.name AS category_name, s.name AS seller_name, p.id AS product_id, p.name AS product_name, count(DISTINCT o.id) AS orders_cnt, sum(oi.qty) AS total_units, sum(oi.qty * oi.price) AS gross_revenue, round(avg(oi.price), 2) AS avg_unit_price, count(r.id) AS review_cnt, coalesce(round(avg(r.rating), 2), 0) AS avg_review_rating FROM order_item oi JOIN orders o ON o.id = oi.order_id JOIN product p ON p.id = oi.product_id JOIN category cat ON cat.id = p.category_id JOIN seller s ON s.id = p.seller_id LEFT JOIN review r ON r.product_id = p.id AND r.customer_id = o.customer_id WHERE oi.tenant_id = 13 AND o.tenant_id = 13 GROUP BY cat.name, s.name, p.id, p.name HAVING count(oi.id) >= 3 ORDER BY gross_revenue DESC, p.id ASC LIMIT 20;"
)

read -r c0 u0 h0 m0 e0 a0 r0 mvh0 cdc0 <<<"$(read_counters)"

PASS=0
FAIL=0
IDX=0
for q in "${QUERIES[@]}"; do
  IDX=$((IDX + 1))
  orig_out=$(ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  # Pass 1 against PgCache (initial miss -> base-table population)
  cache_out1=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  sleep 1
  # Pass 2 against PgCache (base-table subsumption hit -> triggers MV admission & build)
  cache_out2=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  sleep 1
  # Pass 3 against PgCache (warm Materialized View hit -> served directly from MV)
  cache_out3=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")

  if [ "$orig_out" = "$cache_out1" ] && [ "$orig_out" = "$cache_out2" ] && [ "$orig_out" = "$cache_out3" ]; then
    rows=$(printf "%s\n" "$orig_out" | sed '/^$/d' | wc -l | tr -d ' ')
    printf "  [PASS] Complex Query #%-2d: Origin == PgCache (pass 1, 2 & 3 identical, %s rows)\n" "$IDX" "$rows"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] Complex Query #%-2d: Output divergence detected!\n" "$IDX" >&2
    diff -u <(printf "%s\n" "$orig_out") <(printf "%s\n" "$cache_out3") >&2 || true
    FAIL=$((FAIL + 1))
  fi
done

read -r c1 u1 h1 m1 e1 a1 r1 mvh1 cdc1 <<<"$(read_counters)"
c_delta=$((c1 - c0))
u_delta=$((u1 - u0))
h_delta=$((h1 - h0))
e_delta=$((e1 - e0))
a_delta=$((a1 - a0))
r_delta=$((r1 - r0))
mvh_delta=$((mvh1 - mvh0))

# ── Part 3: Post-CDC Live Mutation Differential Correctness (Pass 4) ───────
echo ""
echo "--> [Stage 3/3] Checking Post-CDC Live Mutation Correctness (Pass 4 after Origin UPDATE + INSERT)..."

# Pick a deterministic 'done' order and one of its order_items for tenant_id = 13
TARGET_ORDER_ID=$(ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAc \"SELECT o.id FROM orders o WHERE o.tenant_id = 13 AND o.status = 'done' AND EXISTS (SELECT 1 FROM order_item oi WHERE oi.order_id = o.id AND oi.tenant_id = 13) ORDER BY o.id ASC LIMIT 1;\"" | tr -d '[:space:]')
TARGET_ITEM_ID=$(ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAc \"SELECT oi.id FROM order_item oi WHERE oi.order_id = $TARGET_ORDER_ID AND oi.tenant_id = 13 ORDER BY oi.id ASC LIMIT 1;\"" | tr -d '[:space:]')
TARGET_PRODUCT_ID=$(ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAc \"SELECT oi.product_id FROM order_item oi WHERE oi.id = $TARGET_ITEM_ID;\"" | tr -d '[:space:]')

if [ -z "$TARGET_ORDER_ID" ] || [ -z "$TARGET_ITEM_ID" ] || [ -z "$TARGET_PRODUCT_ID" ]; then
  die "Could not locate target order/order_item for tenant 13 Post-CDC check"
fi

# Ensure sequences exist and apply live UPDATE + INSERT directly on Origin
ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c \"
  CREATE SEQUENCE IF NOT EXISTS orders_id_seq START WITH 100000000;
  CREATE SEQUENCE IF NOT EXISTS order_item_id_seq START WITH 100000000;
  ALTER TABLE orders ALTER COLUMN id SET DEFAULT nextval('orders_id_seq');
  ALTER TABLE order_item ALTER COLUMN id SET DEFAULT nextval('order_item_id_seq');
  UPDATE orders SET total = total + 500 WHERE id = $TARGET_ORDER_ID AND tenant_id = 13;
  UPDATE order_item SET qty = qty + 5 WHERE id = $TARGET_ITEM_ID AND tenant_id = 13;
  INSERT INTO order_item (id, order_id, product_id, qty, price, tenant_id)
  VALUES (99999999, $TARGET_ORDER_ID, $TARGET_PRODUCT_ID, 4, 250.00, 13);
\""

# Wait for PgCache logical replication CDC to apply the mutation events
CDC_WAIT=0
while [ $CDC_WAIT -lt 20 ]; do
  read -r _ _ _ _ _ _ _ _ cdc_now <<<"$(read_counters)"
  if [ $((cdc_now - cdc1)) -ge 3 ]; then
    break
  fi
  sleep 0.5
  CDC_WAIT=$((CDC_WAIT + 1))
done
sleep 1

CDC_PASS=0
CDC_FAIL=0
CDC_IDX=0
for q in "${QUERIES[@]}"; do
  CDC_IDX=$((CDC_IDX + 1))
  orig_post=$(ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  # First post-CDC read triggers rebuild for any invalidated outer-join MVs
  cache_post1=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")
  sleep 0.5
  # Second post-CDC read verifies warm MV state after CDC apply/rebuild
  cache_post2=$(ex "psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -tAF '|' -c \"$q\"")

  if [ "$orig_post" = "$cache_post1" ] && [ "$orig_post" = "$cache_post2" ]; then
    printf "  [PASS] Post-CDC Query #%-2d: Origin == PgCache after live CDC UPDATE + INSERT\n" "$CDC_IDX"
    CDC_PASS=$((CDC_PASS + 1))
  else
    printf "  [FAIL] Post-CDC Query #%-2d: Stale or divergent rows after CDC UPDATE + INSERT!\n" "$CDC_IDX" >&2
    diff -u <(printf "%s\n" "$orig_post") <(printf "%s\n" "$cache_post2") >&2 || true
    CDC_FAIL=$((CDC_FAIL + 1))
  fi
done

# Restore mutated and inserted rows on Origin so dataset returns to exact initial state
ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c \"
  DELETE FROM order_item WHERE id = 99999999 AND tenant_id = 13;
  UPDATE orders SET total = total - 500 WHERE id = $TARGET_ORDER_ID AND tenant_id = 13;
  UPDATE order_item SET qty = qty - 5 WHERE id = $TARGET_ITEM_ID AND tenant_id = 13;
\""

read -r c2 u2 h2 m2 e2 a2 r2 mvh2 cdc2 <<<"$(read_counters)"
cdc_delta=$((cdc2 - cdc1))
u_total=$((bu_delta + (u2 - u0)))
e_total=$((be_delta + (e2 - e0)))

echo "------------------------------------------------------------------------"
printf "  Baseline Queries:    %d/%d passed\n" "$B_PASS" "$B_IDX"
printf "  Complex Static:      %d/%d passed (Cacheable delta: %d/%d)\n" "$PASS" "$IDX" "$c_delta" "$((IDX * 3))"
printf "  Complex Post-CDC:    %d/%d passed (CDC Events Processed: %d)\n" "$CDC_PASS" "$CDC_IDX" "$cdc_delta"
printf "  Uncacheable delta:   %d (expected 0)\n" "$u_total"
printf "  MV Gate Admitted:    %d (expected %d, Rejected: %d)\n" "$a_delta" "$IDX" "$r_delta"
printf "  MV Hits delta:       %d (expected %d)\n" "$mvh_delta" "$IDX"
printf "  Cache Errors delta:  %d (expected 0)\n" "$e_total"
echo "========================================================================"

if [ "$FAIL" -ne 0 ] || [ "$CDC_FAIL" -ne 0 ] || [ "$u_total" -ne 0 ] || [ "$e_total" -ne 0 ] || [ "$r_delta" -ne 0 ] || [ "$a_delta" -ne "$IDX" ] || [ "$mvh_delta" -ne "$IDX" ]; then
  die "Differential correctness, cacheability, MV admission, or Post-CDC gate failed!"
fi
