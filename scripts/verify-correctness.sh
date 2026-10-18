#!/usr/bin/env bash
# ============================================================================
# Differential Result Correctness & Cacheability Gate
#
# Verifies three mandatory invariants across all complex multi-tenant queries:
#   1. Cacheability Gate: Every SQL query in complex-search, complex-joins,
#      complex-analytics, and complex-dashboard must be classified as
#      cacheable by PgCache (pgcache_queries_uncacheable delta == 0 and
#      pgcache_queries_cache_error delta == 0).
#   2. MV Admission Gate: Every complex query must be admitted by PgCache's
#      Materialized View gate (pgcache_cache_mv_gate{outcome="reject"} delta == 0).
#   3. Differential Correctness Gate: Every query must return byte-for-byte
#      identical rows from PgCache (both on initial miss/populate and on
#      subsequent cache hit) as it does directly from PostgreSQL Origin.
# ============================================================================

set -euo pipefail
source "$(dirname "$0")/lib.sh"

ensure_workload_scripts
reset_pgcache

echo "========================================================================"
echo " Running Differential Correctness & Cacheability Gate ($BENCH_ENV)"
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
      END { printf "%d %d %d %d %d %d %d %d\n", c+0, u+0, h+0, m+0, e+0, a+0, r+0, mvh+0 }'
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
      END { printf "%d %d %d %d %d %d %d %d\n", c+0, u+0, h+0, m+0, e+0, a+0, r+0, mvh+0 }'
  fi
}

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

read -r c0 u0 h0 m0 e0 a0 r0 mvh0 <<<"$(read_counters)"

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
    printf "  [PASS] Query #%-2d: Origin == PgCache (pass 1, 2 & 3 identical, %s rows)\n" "$IDX" "$rows"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] Query #%-2d: Output divergence detected!\n" "$IDX" >&2
    diff -u <(printf "%s\n" "$orig_out") <(printf "%s\n" "$cache_out3") >&2 || true
    FAIL=$((FAIL + 1))
  fi
done

read -r c1 u1 h1 m1 e1 a1 r1 mvh1 <<<"$(read_counters)"
c_delta=$((c1 - c0))
u_delta=$((u1 - u0))
h_delta=$((h1 - h0))
e_delta=$((e1 - e0))
a_delta=$((a1 - a0))
r_delta=$((r1 - r0))
mvh_delta=$((mvh1 - mvh0))

echo "------------------------------------------------------------------------"
printf "  Queries checked:     %d (Passed: %d, Failed: %d)\n" "$IDX" "$PASS" "$FAIL"
printf "  Cacheable delta:     %d (expected %d)\n" "$c_delta" "$((IDX * 3))"
printf "  Uncacheable delta:   %d (expected 0)\n" "$u_delta"
printf "  Cache Hits delta:    %d\n" "$h_delta"
printf "  MV Gate Admitted:    %d (expected %d, Rejected: %d)\n" "$a_delta" "$IDX" "$r_delta"
printf "  MV Hits delta:       %d (expected %d)\n" "$mvh_delta" "$IDX"
printf "  Cache Errors delta:  %d (expected 0)\n" "$e_delta"
echo "========================================================================"

if [ "$FAIL" -ne 0 ] || [ "$u_delta" -ne 0 ] || [ "$e_delta" -ne 0 ] || [ "$r_delta" -ne 0 ] || [ "$a_delta" -ne "$IDX" ] || [ "$mvh_delta" -ne "$IDX" ]; then
  die "Differential correctness, cacheability, MV admission, or MV hit gate failed!"
fi
