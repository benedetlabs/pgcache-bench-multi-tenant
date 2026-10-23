#!/usr/bin/env bash
# ============================================================================
# SWEEP 7 -- Admission Threshold Sweep (ADMISSION_THRESHOLD = 1 vs 2 vs 4)
#
# Evaluates PgCache developer feedback (James):
#   "I'm curious what happens to warm up and cold start if the
#    admission_threshold is set higher than 1, maybe 2 or 4. It controls how
#    many times a query has to be seen before it'll be admitted to the cache.
#    A setting of 2 will avoid populating and invalidating many queries that
#    are seen once or rarely. Setting it to 4 is a more extreme version."
#
# Measures for each ADMISSION_THRESHOLD in (1, 2, 4):
#   1. Cold Start (0s warm-up, first 30s window) on cplx_dash (200 tenants)
#   2. Warm-up after 30s on cplx_dash (200 tenants)
#   3. Settled steady-state on cplx_dash (200 tenants)
#   4. Settled steady-state on zipf_1000t (80/20 Zipfian across 1,000 tenants)
#   5. Settled steady-state on cplx_dyn (Dynamic intra-tenant filters)
# ============================================================================

set -uo pipefail
export PREWARM_ORIGIN=1
export RECREATE_PODS_MODE="pgcache"
source "$(dirname "$0")/lib.sh"

TENANTS="${TENANTS:-200}"

measure_fixed_warmup() {
  ensure_workload_scripts
  local label="$1"; shift
  local warm_sec="$1"; shift
  local num_trials="${TRIALS:-5}"
  local t a b h0 m0 f0 u0 e0 h1 m1 f1 u1 e1
  local a_lat a_rps a_s1 a_s2 b_lat b_rps b_s1 b_s2 hit_pct gain_pct
  local trials_data=""

  for t in $(seq 1 "$num_trials"); do
    if [ "$RECREATE_PODS_MODE" = "all" ]; then
      reset_all_pods
    else
      reset_pgcache
    fi

    a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")
    read -r a_lat a_rps a_s1 a_s2 <<<"$a"

    if [ "$warm_sec" -gt 0 ]; then
      run '$PGCACHE_HOST' '$PGCACHE_PORT' "$warm_sec" "$@" >/dev/null
    fi

    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    b=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" "$@")
    read -r b_lat b_rps b_s1 b_s2 <<<"$b"
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"

    hit_pct=$(awk -v h0="$h0" -v m0="$m0" -v u0="$u0" -v h1="$h1" -v m1="$m1" -v u1="$u1" 'BEGIN {
      dh = h1 - h0; dm = m1 - m0; du = u1 - u0;
      tot = dh + dm + du;
      printf "%.2f", (tot > 0 ? (dh * 100.0) / tot : 0.0)
    }')
    gain_pct=$(awk -v a="$a_rps" -v b="$b_rps" 'BEGIN {
      printf "%+.1f%%", (a > 0 ? ((b - a) * 100.0) / a : 0.0)
    }')

    if [ "$num_trials" -gt 1 ]; then
      printf "  [Trial %d/%d] %-10s | A: %s ms (%s rps) | B: %s ms (%s rps) | hit: %s%% | gain: %s | warm: %ds\n" \
        "$t" "$num_trials" "$label" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$hit_pct" "$gain_pct" "$warm_sec" >&2
    fi
    trials_data+="${a_lat} ${a_rps} ${b_lat} ${b_rps} ${hit_pct} ${warm_sec}"$'\n'
  done

  awk -v label="$label" -v n="$num_trials" -v w_fixed="${warm_sec}s" '
  BEGIN { count = 0 }
  NF >= 5 {
    count++
    al[count] = $1 + 0.0; ar[count] = $2 + 0.0
    bl[count] = $3 + 0.0; br[count] = $4 + 0.0
    hp[count] = $5 + 0.0
    sum_al += al[count]; sum_ar += ar[count]
    sum_bl += bl[count]; sum_br += br[count]
    sum_hp += hp[count]
  }
  function stats(arr, c, mean,   i, min, max, s2, std) {
    min = arr[1]; max = arr[1]; s2 = 0
    for (i = 1; i <= c; i++) {
      if (arr[i] < min) min = arr[i]
      if (arr[i] > max) max = arr[i]
      s2 += (arr[i] - mean) * (arr[i] - mean)
    }
    std = (c > 1) ? sqrt(s2 / (c - 1)) : 0.0
    return sprintf("-%.1f/+%.1f (sd %.1f)", mean - min, max - mean, std)
  }
  END {
    if (count == 0) exit 1
    m_al = sum_al / count; m_ar = sum_ar / count
    m_bl = sum_bl / count; m_br = sum_br / count
    m_hp = sum_hp / count
    gain = (m_ar > 0) ? ((m_br - m_ar) * 100.0 / m_ar) : 0.0
    ar_sp = stats(ar, count, m_ar)
    br_sp = stats(br, count, m_br)
    bl_sp = stats(bl, count, m_bl)
    printf "%-10s %8.2f  %6.0f  %8.2f  %6.0f  %6.2f%%  %+6.1f%%  %-12s | A_rps %s | B_rps %s | B_lat %s ms\n",
      label, m_al, m_ar, m_bl, m_br, m_hp, gain, w_fixed, ar_sp, br_sp, bl_sp
  }' <<<"$trials_data"
}

for thresh in 1 2 4; do
  echo ""
  echo "========================================================================"
  echo " Setting PgCache ADMISSION_THRESHOLD=$thresh (TRIALS=$TRIALS)"
  echo "========================================================================"
  if [ "$BENCH_ENV" = "k8s" ]; then
    kubectl -n "$NS" set env deploy/pgcache ADMISSION_THRESHOLD="$thresh"
    kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m
  fi

  header "adm_t=${thresh}"
  measure_fixed_warmup "t${thresh}_cold0s" 0  -f /tmp/mt/complex-dashboard.sql -D tenants="$TENANTS"
  measure_fixed_warmup "t${thresh}_w30s"   30 -f /tmp/mt/complex-dashboard.sql -D tenants="$TENANTS"
  if [ "$thresh" -gt 1 ]; then
    cell "t${thresh}_settle" -f /tmp/mt/complex-dashboard.sql           -D tenants="$TENANTS"
    cell "t${thresh}_dyn"    -f /tmp/mt/complex-dashboard-dynamic.sql   -D tenants="$TENANTS"
  fi
done

