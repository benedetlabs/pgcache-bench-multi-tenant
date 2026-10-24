#!/usr/bin/env bash
# ============================================================================
# SWEEP 11 -- Progressive 5-Execution Complex Dashboard Benchmark (No Reset Between Executions)
#
# Purpose:
#   In Sweep 04 (`04-complex-sweep.sh`), `cell()` called `reset_pgcache` before
#   EVERY trial (`Trial 1..3`) and capped `warm_until_settled` at 8 passes
#   (120s). At 500, 1,000, and 2,000 tenants on `complex-dashboard-zipfian.sql`
#   (4,000 to 16,000 heavy 4-to-6 table Materialized Views), 120s of Zipfian
#   80/20 traffic only warmed the hot 20% of tenants (leaving 7% to 28% cold-tail
#   misses during measurement) and then wiped the cache before the next trial.
#
#   This benchmark tests what happens when PgCache starts cold (once per tenant
#   count `T`) and runs 5 consecutive executions (`Exec 1..5`) WITHOUT resetting
#   PgCache between the 5 executions — tracking how latency, RPS, hit ratio,
#   registered queries (`pgcache_cache_queries_registered`), and memory usage
#   (`pgcache_cache_memory_used_bytes`) evolve across the 5 executions.
#
# Modes (pass as $1, default: progressive):
#   progressive : Start cold at each tenant count T (100..2000), run 0 separate
#                 pre-warm passes, and measure 5 consecutive executions of
#                 EXEC_DURATION seconds (default: 60s each = 300s cumulative)
#                 without resetting PgCache between Exec 1..5.
#   cumulative  : Start cold at each tenant count T (100..2000) and run 5
#                 consecutive trials (`warm_until_settled` + measured window)
#                 WITHOUT resetting PgCache between Trial 1..5, so each trial
#                 continues warming from the previous trial's cache state.
#   prewarmed   : Deterministically pre-warm all tenants (1..T) once, then
#                 measure 5 consecutive executions (`Exec 1..5`) on the already
#                 warmed cache without resetting between them.
#   all         : Run progressive and prewarmed sequentially.
# ============================================================================

set -uo pipefail
source "$(dirname "$0")/lib.sh"

MODE="${1:-progressive}"
ZIPF_TENANTS_LIST="${ZIPF_TENANTS_LIST:-100 200 500 1000 2000}"
NUM_EXECS="${NUM_EXECS:-5}"
EXEC_DURATION="${EXEC_DURATION:-60}"
WORKLOAD_FILE="${WORKLOAD_FILE:-/tmp/mt/complex-dashboard-zipfian.sql}"

ensure_workload_scripts

# Scrape extended Prometheus telemetry from PgCache:
# Prints: <hits> <misses> <mv_fallthrough> <uncacheable> <cache_error> <queries_registered> <mv_hits> <mem_bytes> <evictions>
scrape_extended() {
  local raw
  if [ "$BENCH_ENV" = "docker" ]; then
    raw=$(curl -sf --connect-timeout 5 http://127.0.0.1:59090/metrics 2>/dev/null || true)
    if [ -z "$raw" ]; then
      raw=$(docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T metrics-reader \
        sh -c "wget -qO- --timeout=20 http://pgcache:9090/metrics" 2>/dev/null || true)
    fi
  else
    local ip mport
    ip="$(pgcache_ip)"
    mport="${PGCACHE_METRICS_PORT:-${CACHED_PGCACHE_MPORT:-9091}}"
    raw=$(kubectl -n "$NS" exec deploy/metrics-reader -- \
      sh -c "wget -qO- --timeout=20 http://$ip:$mport/metrics" 2>/dev/null || true)
  fi

  echo "$raw" | awk '
    /^pgcache_queries_cache_hit /        { h = $2 }
    /^pgcache_queries_cache_miss /       { m = $2 }
    /^pgcache_cache_mv_fallthrough /     { f = $2 }
    /^pgcache_queries_uncacheable /      { u = $2 }
    /^pgcache_queries_cache_error /      { e = $2 }
    /^pgcache_cache_queries_registered / { qr = $2 }
    /^pgcache_cache_mv_hits /            { mvh = $2 }
    /^pgcache_cache_memory_used_bytes /  { mem = $2 }
    /^pgcache_cache_evictions /          { ev = $2 }
    END {
      printf "%d %d %d %d %d %d %d %.0f %d\n", h+0, m+0, f+0, u+0, e+0, qr+0, mvh+0, mem+0, ev+0
    }
  '
}

# Deterministic sequential pre-warm for tenants 1..T using parallel psql workers
prewarm_all_tenants() {
  local max_t="$1"
  local parallel_workers="${PREWARM_WORKERS:-8}"
  echo "  [prewarm] Deterministically warming all tenants 1..${max_t} (${parallel_workers} parallel workers)..." >&2
  local t_start t_end
  t_start=$(date +%s)
  ex "seq 1 $max_t | xargs -n 1 -P $parallel_workers -I {} bash -c 'sed \"s/:t/{}/g; /^\\\\set/d\" $WORKLOAD_FILE | psql -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE -q >/dev/null 2>&1'" || true
  t_end=$(date +%s)
  echo "  [prewarm] Completed sequential pass over ${max_t} tenants in $((t_end - t_start))s." >&2
}

run_progressive_mode() {
  local submode="$1" # "progressive" | "cumulative" | "prewarmed"
  echo "=========================================================================================================================================="
  echo " SWEEP 11 (${submode}): 5 Consecutive Executions on PgCache WITHOUT Reset Between Executions"
  echo " Workload: ${WORKLOAD_FILE} | Tenants: ${ZIPF_TENANTS_LIST} | Executions: ${NUM_EXECS} | Duration/Exec: ${EXEC_DURATION}s | Clients: ${CLIENTS}"
  echo "=========================================================================================================================================="
  printf "%-9s | %-8s | %9s | %6s | %10s | %6s | %7s | %8s | %6s | %13s | %9s | %8s\n" \
    "Tenants" "Exec" "A_lat_ms" "A_rps" "B_lat_ms" "B_rps" "Hit_%" "Gain_%" "Mult" "Queries_Reg" "MV_Hits_Δ" "Mem_MiB"
  echo "----------+----------+-----------+--------+------------+--------+---------+----------+--------+---------------+-----------+---------"

  for T in $ZIPF_TENANTS_LIST; do
    local expected_queries=$((T * 8))

    # Reset PgCache ONCE at the start of this tenant count T
    reset_pgcache

    # Measure Origin (Path A) baseline for this tenant count T
    local a_out a_lat a_rps a_s1 a_s2
    a_out=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" -f "$WORKLOAD_FILE" -D tenants="$T")
    read -r a_lat a_rps a_s1 a_s2 <<<"$a_out"

    if [ "$submode" = "prewarmed" ]; then
      prewarm_all_tenants "$T"
      # Run 1 quick settling pass so async MV creation finishes
      run '$PGCACHE_HOST' '$PGCACHE_PORT' 15 -f "$WORKLOAD_FILE" -D tenants="$T" >/dev/null
    fi

    local exec_data=""
    for ex_idx in $(seq 1 "$NUM_EXECS"); do
      local warm_passes=0
      local win_sec="$EXEC_DURATION"

      if [ "$submode" = "cumulative" ]; then
        warm_passes=$(warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' -f "$WORKLOAD_FILE" -D tenants="$T")
        win_sec="$DURATION"
      fi

      local h0 m0 f0 u0 e0 qr0 mvh0 mem0 ev0
      local h1 m1 f1 u1 e1 qr1 mvh1 mem1 ev1
      read -r h0 m0 f0 u0 e0 qr0 mvh0 mem0 ev0 <<<"$(scrape_extended)"

      local b_out b_lat b_rps b_s1 b_s2
      b_out=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$win_sec" -f "$WORKLOAD_FILE" -D tenants="$T")
      read -r b_lat b_rps b_s1 b_s2 <<<"$b_out"

      read -r h1 m1 f1 u1 e1 qr1 mvh1 mem1 ev1 <<<"$(scrape_extended)"

      local dh=$((h1 - h0))
      local dm=$((m1 - m0))
      local du=$((u1 - u0))
      local dmvh=$((mvh1 - mvh0))
      local tot=$((dh + dm + du))

      local hit_pct gain_pct mult_str mem_mib reg_str
      hit_pct=$(awk -v h="$dh" -v t="$tot" 'BEGIN { printf "%.2f", (t > 0 ? (100.0 * h) / t : 0.0) }')
      gain_pct=$(awk -v x="${a_rps:-0}" -v y="${b_rps:-0}" 'BEGIN { printf "%+.1f", (x+0 > 0 ? 100.0 * ((y+0)/(x+0) - 1.0) : 0.0) }')
      mult_str=$(awk -v x="${a_rps:-0}" -v y="${b_rps:-0}" 'BEGIN { printf "%.1fx", (x+0 > 0 ? (y+0)/(x+0) : 0.0) }')
      mem_mib=$(awk -v b="${mem1:-0}" 'BEGIN { printf "%.1f", b / (1024.0 * 1024.0) }')
      reg_str="${qr1}/${expected_queries}"

      printf "%-9s | Exec %d/%d | %9s | %6s | %10s | %6s | %6s%% | %7s%% | %6s | %13s | %9d | %7sM\n" \
        "$T" "$ex_idx" "$NUM_EXECS" "${a_lat:-0.000}" "${a_rps:-0}" "${b_lat:-0.000}" "${b_rps:-0}" \
        "$hit_pct" "$gain_pct" "$mult_str" "$reg_str" "$dmvh" "$mem_mib"

      exec_data="${exec_data}${a_lat:-0.000} ${a_rps:-0} ${b_lat:-0.000} ${b_rps:-0} ${hit_pct} ${gain_pct} ${warm_passes}"$'\n'
    done

    # Print summary across all 5 executions AND final settled execution (Exec 5)
    echo "$exec_data" | awk -v lbl="$T" '
      NF >= 6 {
        n++
        al[n]=$1; ar[n]=$2; bl[n]=$3; br[n]=$4; ht[n]=$5; gn[n]=$6
        s_al+=$1; s_ar+=$2; s_bl+=$3; s_br+=$4; s_ht+=$5; s_gn+=$6
        if(n==1 || $4<min_br) min_br=$4; if(n==1 || $4>max_br) max_br=$4
      }
      END {
        if (n == 0) exit
        m_al=s_al/n; m_ar=s_ar/n; m_bl=s_bl/n; m_br=s_br/n; m_ht=s_ht/n; m_gn=s_gn/n
        mult_avg = (m_ar > 0) ? m_br / m_ar : 0
        mult_last = (ar[n] > 0) ? br[n] / ar[n] : 0
        printf "  --> [Summary %-4s] Mean(1..%d): B=%5.0f rps (%5.1fx, hit=%5.1f%%, min..max=%d..%d rps) | Final(Exec %d): B=%5.0f rps (%5.1fx, hit=%5.1f%%)\n",
          lbl, n, m_br, mult_avg, m_ht, min_br, max_br, n, br[n], mult_last, ht[n]
      }
    '
    echo "----------+----------+-----------+--------+------------+--------+---------+----------+--------+---------------+-----------+---------"
  done
}

case "$MODE" in
  progressive) run_progressive_mode "progressive" ;;
  cumulative)  run_progressive_mode "cumulative" ;;
  prewarmed)   run_progressive_mode "prewarmed" ;;
  all)
    run_progressive_mode "progressive"
    echo ""
    run_progressive_mode "prewarmed"
    ;;
  *)
    die "Unknown mode: $MODE (expected: progressive|cumulative|prewarmed|all)"
    ;;
esac
