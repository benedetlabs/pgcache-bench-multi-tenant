#!/usr/bin/env bash
# ============================================================================
# SWEEP 10 -- Subsumption Warm-up Curve: PgCache 0.8.0 vs. 0.7.1 (3-Node DOKS)
#
# Evaluates PgCache developer feedback (James):
#   "there is a metric: pgcache.cache.subsumptions - might be interesting to
#    get a count or graph of it during warmup and if you are motivated get a
#    run with 0.7.1 to compare it against"
#
# Tracks step-by-step warm-up progression (every 15s from 0s to 120s) for both
# pgcache/pgcache:0.8.0 and pgcache/pgcache:0.7.1 across:
#   1. dashboard.sql (200 tenants)          -- single-table & 2-table join pagination/filter subsumption
#   2. dashboard.sql (1000 tenants)         -- high-cardinality tenant warm-up subsumption rate
#   3. complex-joins + dashboard (200t)     -- LEFT JOIN + single-table preserved-relation subsumption
#   4. complex-dashboard-dynamic.sql (200t) -- dynamic intra-tenant filters & limits on 4-6 table MVs
# ============================================================================

set -uo pipefail
export RECREATE_PODS_MODE="pgcache"
source "$(dirname "$0")/lib.sh"

ensure_workload_scripts

scrape_subsumption() {
  local raw hits misses uncacheable subs sub_checks mv_hits
  if [ "$BENCH_ENV" = "docker" ]; then
    raw=$(curl -sf http://127.0.0.1:59090/metrics 2>/dev/null || true)
  else
    local ip mport
    ip="$(pgcache_ip)"
    mport="${PGCACHE_METRICS_PORT:-9091}"
    raw=$(kubectl -n "$NS" exec deploy/metrics-reader -- sh -c "wget -qO- --timeout=5 http://$ip:$mport/metrics" 2>/dev/null || true)
  fi
  echo "$raw" | awk '
    /^pgcache_queries_cache_hit /   { h = $2 }
    /^pgcache_queries_cache_miss /  { m = $2 }
    /^pgcache_queries_uncacheable / { u = $2 }
    /^pgcache_cache_subsumptions /  { s = $2 }
    /^pgcache_cache_writer_register_subsumption_check_seconds_count / { sc = $2 }
    /^pgcache_cache_mv_hits /       { mvh = $2 }
    END { printf "%d %d %d %d %d %d\n", h+0, m+0, u+0, s+0, sc+0, mvh+0 }
  '
}

run_warmup_curve() {
  local ver="$1"
  local scenario_label="$2"
  shift 2
  local step_sec=15
  local steps=8

  reset_pgcache

  echo ""
  echo "------------------------------------------------------------------------------------------------------------------------"
  echo " Version: PgCache ${ver} | Scenario: ${scenario_label} (8 steps x ${step_sec}s = 120s Warm-up Curve)"
  echo "------------------------------------------------------------------------------------------------------------------------"
  printf "%-8s | %8s | %7s | %8s | %12s | %10s | %11s | %10s | %10s\n" \
    "Window" "Lat_ms" "RPS" "Hit_%" "Subsumptions" "Sub_Delta" "Sub_Checks" "Hits_Delta" "Miss_Delta"
  echo "---------+----------+---------+----------+--------------+------------+-------------+------------+-----------"

  local h0 m0 u0 s0 sc0 mvh0
  local h1 m1 u1 s1 sc1 mvh1
  read -r h0 m0 u0 s0 sc0 mvh0 <<<"$(scrape_subsumption)"

  for step in $(seq 1 "$steps"); do
    local t_start=$(((step - 1) * step_sec))
    local t_end=$((step * step_sec))
    local win_label="${t_start}-${t_end}s"

    local res lat rps s_a s_b
    res=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$step_sec" "$@")
    read -r lat rps s_a s_b <<<"$res"

    read -r h1 m1 u1 s1 sc1 mvh1 <<<"$(scrape_subsumption)"

    local dh=$((h1 - h0))
    local dm=$((m1 - m0))
    local du=$((u1 - u0))
    local ds=$((s1 - s0))
    local tot=$((dh + dm + du))
    local hit_pct
    hit_pct=$(awk -v h="$dh" -v t="$tot" 'BEGIN { printf "%.2f", (t > 0 ? (h * 100.0) / t : 0.0) }')

    printf "%-8s | %8s | %7s | %7s%% | %12d | %+10d | %11d | %10d | %10d\n" \
      "$win_label" "${lat:-0.000}" "${rps:-0}" "$hit_pct" "$s1" "$ds" "$sc1" "$dh" "$dm"

    h0=$h1; m0=$m1; u0=$u1; s0=$s1; sc0=$sc1; mvh0=$mvh1
  done
}

echo "========================================================================================================================"
echo " SWEEP 10: Subsumption Warm-up Curve & Telemetry Comparison (PgCache 0.8.0 vs. 0.7.1 on 3-Node DOKS)"
echo "========================================================================================================================"

for ver in "0.8.0" "0.7.1"; do
  echo ""
  echo "########################################################################################################################"
  echo " Switching PgCache deployment to image: pgcache/pgcache:${ver} (ADMISSION_THRESHOLD=1)"
  echo "########################################################################################################################"
  if [ "$BENCH_ENV" = "k8s" ]; then
    kubectl -n "$NS" set image deploy/pgcache pgcache="pgcache/pgcache:${ver}"
    kubectl -n "$NS" set env deploy/pgcache ADMISSION_THRESHOLD="1"
    kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m
  fi

  run_warmup_curve "$ver" "dashboard_200t (Operational Dashboard, 200 Tenants)" \
    -f /tmp/mt/dashboard.sql -D tenants=200

  run_warmup_curve "$ver" "dashboard_1000t (Operational Dashboard, 1,000 Tenants)" \
    -f /tmp/mt/dashboard.sql -D tenants=1000

  run_warmup_curve "$ver" "outer_join_plus_base_200t (LEFT JOIN + Single-Table Preserved Relation, 200 Tenants)" \
    -f /tmp/mt/complex-joins.sql@50 -f /tmp/mt/dashboard.sql@50 -D tenants=200

  run_warmup_curve "$ver" "cplx_dyn_200t (Dynamic Intra-Tenant Filters & Limits, 200 Tenants)" \
    -f /tmp/mt/complex-dashboard-dynamic.sql -D tenants=200
done

# Restore 0.8.0 image before exiting
if [ "$BENCH_ENV" = "k8s" ]; then
  kubectl -n "$NS" set image deploy/pgcache pgcache="pgcache/pgcache:0.8.0" >/dev/null 2>&1 || true
fi
