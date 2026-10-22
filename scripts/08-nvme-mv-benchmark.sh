#!/usr/bin/env bash
# ============================================================================
# SWEEP 8 -- Materialized View Storage Benchmark:
#            Standard SSD (s-4vcpu-8gb) vs. Local NVMe SSD (s-4vcpu-8gb-intel)
#
# Evaluates how disk I/O latency, IOPS, and CPU generation affect PgCache's
# internal PostgreSQL 17 instance (127.0.0.1:5433, /var/lib/postgresql/data),
# which stores and queries Materialized Views for heavy multi-table screens.
#
# Measures (TRIALS=3 by default):
#   0. Storage & CPU Telemetry inside the PgCache pod (/var/lib/postgresql/data):
#      - CPU model & clock (/proc/cpuinfo)
#      - Sequential write throughput with fdatasync (512 MB dd)
#      - PostgreSQL 8kB WAL/Page sync IOPS & latency (pg_test_fsync)
#   1. MV Creation Storm (Cold Start 0s & Warm-Up 30s on complex-dashboard.sql)
#   2. MV Steady-State Scans:
#      - mv_joins     (complex-joins.sql: 4-to-6 table INNER/LEFT JOINs)
#      - mv_analytics (complex-analytics.sql: GROUP BY / FILTER / CASE / HAVING)
#      - mv_dash      (complex-dashboard.sql: 8-query unified enterprise screen)
#   3. MV High-Cardinality & Dynamic Filters:
#      - mv_zipf_1000t (complex-dashboard-zipfian.sql across 1,000 tenants)
#      - mv_dyn_t2     (complex-dashboard-dynamic.sql with ADMISSION_THRESHOLD=2)
# ============================================================================

set -uo pipefail
export PREWARM_ORIGIN=1
export RECREATE_PODS_MODE="pgcache"
export TRIALS="${TRIALS:-3}"
source "$(dirname "$0")/lib.sh"

TENANTS="${TENANTS:-200}"
DISK_TIER="${DISK_TIER:-unknown}"

set_admission_threshold() {
  local thresh="$1"
  if [ "$BENCH_ENV" = "k8s" ]; then
    echo "--> Setting PgCache ADMISSION_THRESHOLD=$thresh ..." >&2
    kubectl -n "$NS" set env deploy/pgcache ADMISSION_THRESHOLD="$thresh" >&2
    kubectl -n "$NS" rollout status deploy/pgcache --timeout=5m >&2
  fi
}

measure_fixed_warmup() {
  ensure_workload_scripts
  local label="$1"; shift
  local warm_sec="$1"; shift
  local num_trials="${TRIALS:-3}"
  local t a b h0 m0 f0 u0 e0 h1 m1 f1 u1 e1
  local a_lat a_rps a_s1 a_s2 b_lat b_rps b_s1 b_s2 hit_pct gain_pct
  local trials_data=""

  for t in $(seq 1 "$num_trials"); do
    reset_pgcache

    echo ">>> [$label] Trial $t/$num_trials -- Path A (Origin)" >&2
    a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")

    echo ">>> [$label] Trial $t/$num_trials -- Path B (PgCache fixed warmup=${warm_sec}s)" >&2
    if [ "$warm_sec" -gt 0 ]; then
      run '$PGCACHE_HOST' '$PGCACHE_PORT' "$warm_sec" "$@" >/dev/null
    fi

    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    b=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" "$@")
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"

    read -r a_lat a_rps a_s1 a_s2 <<<"$a"
    read -r b_lat b_rps b_s1 b_s2 <<<"$b"

    hit_pct=$(awk -v dh="$((h1-h0))" -v dm="$((m1-m0))" -v du="$((u1-u0))" \
      'BEGIN { d = dh + dm + du; printf "%.2f", (d > 0 ? 100.0 * dh / d : 0) }')
    gain_pct=$(awk -v ar="$a_rps" -v br="$b_rps" \
      'BEGIN { printf "%+.1f%%", (ar > 0 ? 100.0 * (br - ar) / ar : 0) }')

    printf "  [trial %d/%d] %-12s | A: %7.2f ms (%4d rps) | B: %7.2f ms (%4d rps) | hit: %6.2f%% (w%d) | gain: %s\n" \
      "$t" "$num_trials" "$label" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$hit_pct" "$warm_sec" "$gain_pct" >&2

    trials_data+="$a_lat $a_rps $b_lat $b_rps $hit_pct $warm_sec"$'\n'
  done

  awk -v lbl="$label" '
  NF == 6 {
    n++
    a_lat[n] = $1; a_rps[n] = $2
    b_lat[n] = $3; b_rps[n] = $4
    hit[n]   = $5; w[n]     = $6
    sa_lat += $1; sa_rps += $2
    sb_lat += $3; sb_rps += $4
    shit   += $5; sw     += $6
  }
  END {
    if (n == 0) exit
    ma_lat = sa_lat / n; ma_rps = sa_rps / n
    mb_lat = sb_lat / n; mb_rps = sb_rps / n
    mhit   = shit / n;   mw     = sw / n
    mina_r = a_rps[1]; maxa_r = a_rps[1]
    minb_r = b_rps[1]; maxb_r = b_rps[1]
    for (i = 1; i <= n; i++) {
      if (a_rps[i] < mina_r) mina_r = a_rps[i]
      if (a_rps[i] > maxa_r) maxa_r = a_rps[i]
      if (b_rps[i] < minb_r) minb_r = b_rps[i]
      if (b_rps[i] > maxb_r) maxb_r = b_rps[i]
      v_a += (a_rps[i] - ma_rps)^2
      v_b += (b_rps[i] - mb_rps)^2
    }
    sda_r = sqrt(v_a / n)
    sdb_r = sqrt(v_b / n)
    mgain = (ma_rps > 0) ? 100.0 * (mb_rps - ma_rps) / ma_rps : 0
    min_gain = (maxa_r > 0) ? 100.0 * (minb_r - maxa_r) / maxa_r : 0
    max_gain = (mina_r > 0) ? 100.0 * (maxb_r - mina_r) / mina_r : 0
    a_str = sprintf("%.0f (-%.0f/+%.0f, sd=%.1f)", ma_rps, ma_rps - mina_r, maxa_r - ma_rps, sda_r)
    b_str = sprintf("%.0f (-%.0f/+%.0f, sd=%.1f)", mb_rps, mb_rps - minb_r, maxb_r - mb_rps, sdb_r)
    g_str = sprintf("%+.0f%% (%.0f%%/%.0f%%)", mgain, min_gain - mgain, max_gain - mgain)
    printf "%-14s | %9.2f ms | %-25s | %9.2f ms | %-25s | %5.1f%% | %-22s | %.1f\n",
      lbl, ma_lat, a_str, mb_lat, b_str, mhit, g_str, mw
  }' <<<"$trials_data"
}

echo "========================================================================"
echo " SWEEP 8: Materialized View Storage Benchmark (TRIALS=$TRIALS)"
echo " Disk Tier: $DISK_TIER"
echo "========================================================================"

if [ "$BENCH_ENV" = "k8s" ]; then
  kubectl -n "$NS" rollout status statefulset/origin --timeout=5m
  kubectl -n "$NS" rollout status deploy/loadgen --timeout=3m
  "$REPO_ROOT/scripts/tune-network.sh" >/dev/null 2>&1 || true
  kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m

  echo "--> Node Hardware & Topology:"
  kubectl get nodes -o wide
  echo ""
  echo "--> Running Storage & CPU Micro-Benchmark inside PgCache Pod (Local Node Disk):"
  kubectl -n "$NS" exec deploy/pgcache -- bash -c '
    export PATH="/usr/lib/postgresql/17/bin:/usr/lib/postgresql/16/bin:$PATH"
    TEST_DIR="/var/lib/postgresql"
    [ -d "$TEST_DIR" ] || TEST_DIR="/tmp"
    echo "--- CPU Model ---"
    grep -E -m2 "model name|cpu MHz|cache size" /proc/cpuinfo || true
    echo "--- Sequential Sync Write 256MB ($TEST_DIR) ---"
    dd if=/dev/zero of="$TEST_DIR/bench_io_test" bs=1M count=256 conv=fsync 2>&1 || true
    rm -f "$TEST_DIR/bench_io_test"
    echo "--- PostgreSQL pg_test_fsync (3s per method on $TEST_DIR) ---"
    pg_test_fsync -s 3 -f "$TEST_DIR/pg_fsync_test"
    rm -f "$TEST_DIR/pg_fsync_test"
  '
  echo ""
  echo "--> Applying Fair-Tuning Profile to PostgreSQL Origin (sql/03-fair-tuning.sql)..."
  for _ in 1 2 3 4 5; do
    kubectl -n "$NS" exec -i -c bench deploy/loadgen -- bash -c "cat > /tmp/03-fair-tuning.sql && [ -s /tmp/03-fair-tuning.sql ]" < "$REPO_ROOT/sql/03-fair-tuning.sql" 2>/dev/null && break
    sleep 2
  done
  ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -f /tmp/03-fair-tuning.sql"
fi

WORKLOAD_SCRIPTS_READY=0
ensure_workload_scripts

echo ""
echo "========================================================================"
echo " Phase 1 & 2: Materialized View Cold Creation & Settled Scans (ADMISSION_THRESHOLD=1)"
echo "========================================================================"
set_admission_threshold 1
header mv_tier_t1

# 1. MV Creation Storm: Cold Start (0s) & Early Warm-Up (30s)
DURATION=15 measure_fixed_warmup "mv_cold0s"  0  -c 8 -j 4 -D tenants="$TENANTS" -f /tmp/mt/complex-dashboard.sql
DURATION=15 measure_fixed_warmup "mv_warm30s" 30 -c 8 -j 4 -D tenants="$TENANTS" -f /tmp/mt/complex-dashboard.sql

# 2. MV Steady-State Scans (100% Materialized View Hit Workloads)
cell "mv_joins"     -c 8 -j 4 -D tenants="$TENANTS" -f /tmp/mt/complex-joins.sql
cell "mv_analytics" -c 8 -j 4 -D tenants="$TENANTS" -f /tmp/mt/complex-analytics.sql
cell "mv_dash"      -c 8 -j 4 -D tenants="$TENANTS" -f /tmp/mt/complex-dashboard.sql

# 3. High-Cardinality MV Working Set (1,000 Tenants Zipfian 80/20)
MAX_WARM_PASSES=4 cell "mv_zipf1000"  -c 8 -j 4 -D tenants=1000       -f /tmp/mt/complex-dashboard-zipfian.sql

echo ""
echo "========================================================================"
echo " Phase 3: Dynamic Filter Materialized Views (ADMISSION_THRESHOLD=2)"
echo "========================================================================"
set_admission_threshold 2
header mv_tier_t2
MAX_WARM_PASSES=4 cell "mv_dyn_t2"    -c 8 -j 4 -D tenants="$TENANTS" -f /tmp/mt/complex-dashboard-dynamic.sql

# Restore default ADMISSION_THRESHOLD=1
set_admission_threshold 1
