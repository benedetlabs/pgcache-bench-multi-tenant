#!/usr/bin/env bash
# ============================================================================
# SWEEP 9 -- 5 GB (SCALE=10) Memory-Constrained Materialized View Stress Test:
#            Standard SSD (s-4vcpu-8gb) vs. Local NVMe SSD (s-4vcpu-8gb-intel)
#
# Addresses the "in-memory working set" limitation of Sweep 8 (SCALE=1) by:
#   1. Seeding ~5.0 GB of data on Origin (SCALE=10: 5M orders, 20M order_items,
#      1.5M reviews, 1M products, 1M customers across 1,000 tenants -> 20,000
#      order_items & 5,000 orders per tenant).
#   2. Constraining memory on both Origin and PgCache so the working set cannot
#      fit in RAM:
#      - Origin: shared_buffers=384MB (~7.5% of the 5 GB DB), PREWARM_ORIGIN=0,
#        stored on local node disk (emptyDir: Regular SSD vs Local NVMe SSD).
#      - PgCache: cgroup memory limit=2600Mi (embedded PG shared_buffers=650MB),
#        MEMORY_LIMIT=1610612736 (1.5 GiB), MEMO_CACHE_SIZE=67108864 (64 MiB).
#      - Linux kernel page caches flushed (vm.drop_caches=3) before each trial.
#   3. Doubling client concurrency (CLIENTS=16, THREADS=4) and using wide
#      500-row Materialized Views (workload/complex-mv-heavy.sql, 80 kB per MV)
#      plus 1,000-tenant Zipfian churn and 90/10 live CDC write invalidations.
#   4. Capturing physical disk I/O telemetry (pg_stat_database blks_read vs
#      blks_hit, temp_bytes, and pg_database_size) on both Origin and PgCache.
# ============================================================================

set -uo pipefail
export PREWARM_ORIGIN=0
export RECREATE_PODS_MODE="pgcache"
export TRIALS="${TRIALS:-3}"
export CLIENTS="${CLIENTS:-8}"
export THREADS="${THREADS:-4}"
export DURATION="${DURATION:-20}"
export MAX_WARM_PASSES="${MAX_WARM_PASSES:-4}"
source "$(dirname "$0")/lib.sh"

SEED_TENANTS="${SEED_TENANTS:-1000}"
ACTIVE_TENANTS="${ACTIVE_TENANTS:-15}"
DISK_TIER="${DISK_TIER:-unknown}"

flush_os_page_cache() {
  if [ "$BENCH_ENV" = "k8s" ]; then
    ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c 'CHECKPOINT;' >/dev/null 2>&1" || true
    kubectl -n "$NS" exec statefulset/origin -- sh -c "sync && echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1 || true
    kubectl -n "$NS" exec deploy/pgcache -- sh -c "sync && echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1 || true
  fi
}

print_pg_io_telemetry() {
  local phase_lbl="$1"
  if [ "$BENCH_ENV" = "k8s" ]; then
    echo "  --- [I/O Audit: $phase_lbl] Origin (:5432) & PgCache Embedded PG (:5433) ---" >&2
    ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAc \"
      SELECT 'ORIGIN_DB   | size=' || pg_size_pretty(pg_database_size(current_database())) ||
             ' | blks_read(disk)=' || blks_read ||
             ' | blks_hit(ram)=' || blks_hit ||
             ' | hit_ratio=' || round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) || '%' ||
             ' | temp_bytes=' || pg_size_pretty(temp_bytes)
        FROM pg_stat_database WHERE datname = current_database();
    \"" >&2 || true

    kubectl -n "$NS" exec deploy/pgcache -- psql -h 127.0.0.1 -p 5433 -U postgres -d pgcache_cache -tAc "
      SELECT 'PGCACHE_PG  | size=' || pg_size_pretty(pg_database_size('pgcache_cache')) ||
             ' | blks_read(disk)=' || blks_read ||
             ' | blks_hit(ram)=' || blks_hit ||
             ' | hit_ratio=' || round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) || '%' ||
             ' | temp_bytes=' || pg_size_pretty(temp_bytes)
        FROM pg_stat_database WHERE datname = 'pgcache_cache';
      SELECT 'PGCACHE_TBL | public_tables=' || count(*) FILTER (WHERE schemaname='public') ||
             ' (' || pg_size_pretty(coalesce(sum(pg_total_relation_size(relid)) FILTER (WHERE schemaname='public'), 0)) || ')' ||
             ' | mv_tables=' || count(*) FILTER (WHERE schemaname='pgcache_mv') ||
             ' (' || pg_size_pretty(coalesce(sum(pg_total_relation_size(relid)) FILTER (WHERE schemaname='pgcache_mv'), 0)) || ')'
        FROM pg_stat_user_tables;
    " >&2 || true
  fi
}

measure_fixed_warmup_5g() {
  ensure_workload_scripts
  local label="$1"; shift
  local warm_sec="$1"; shift
  local num_trials="${TRIALS:-3}"
  local t a b h0 m0 f0 u0 e0 h1 m1 f1 u1 e1
  local a_lat a_rps a_s1 a_s2 b_lat b_rps b_s1 b_s2 hit_pct gain_pct
  local trials_data=""

  for t in $(seq 1 "$num_trials"); do
    reset_pgcache
    flush_os_page_cache

    echo ">>> [$label] Trial $t/$num_trials -- Path A (Origin 5GB, cold OS cache)" >&2
    a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")

    flush_os_page_cache
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
      'BEGIN { printf "%.1f", (ar > 0 ? 100.0 * (br - ar) / ar : 0) }')

    printf "  [Trial %d/%d] %-12s | A: %s ms (%s rps) | B: %s ms (%s rps) | hit: %s%% | gain: %+0.1f%% | warm: %ds\n" \
      "$t" "$num_trials" "$label" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$hit_pct" "$gain_pct" "$warm_sec" >&2

    if [ "$t" -eq "$num_trials" ]; then
      print_pg_io_telemetry "$label (Trial $t)"
    fi

    trials_data+="$a_lat $a_rps $b_lat $b_rps $hit_pct $gain_pct $warm_sec"$'\n'
  done

  echo "$trials_data" | awk -v lbl="$label" '
    NF >= 7 {
      n++
      al[n]=$1; ar[n]=$2; bl[n]=$3; br[n]=$4; ht[n]=$5; gn[n]=$6; wm[n]=$7
      s_al+=$1; s_ar+=$2; s_bl+=$3; s_br+=$4; s_ht+=$5; s_gn+=$6; s_wm+=$7
      if(n==1 || $2<min_ar) min_ar=$2; if(n==1 || $2>max_ar) max_ar=$2
      if(n==1 || $4<min_br) min_br=$4; if(n==1 || $4>max_br) max_br=$4
      if(n==1 || $6<min_gn) min_gn=$6; if(n==1 || $6>max_gn) max_gn=$6
    }
    END {
      if (n == 0) exit
      m_al=s_al/n; m_ar=s_ar/n; m_bl=s_bl/n; m_br=s_br/n; m_ht=s_ht/n; m_gn=s_gn/n; m_wm=s_wm/n
      for(i=1;i<=n;i++) {
        v_ar += (ar[i] - m_ar)^2
        v_br += (br[i] - m_br)^2
      }
      sd_ar = (n>1) ? sqrt(v_ar/(n-1)) : 0
      sd_br = (n>1) ? sqrt(v_br/(n-1)) : 0
      printf "%-12s %9.3f %6.0f %10.3f %6.0f %7.1f%% %+7.0f%% %5.1f  | A_rps_dev: %+.0f/%+.0f (sd %.1f) | B_rps_dev: %+.0f/%+.0f (sd %.1f) | gain_dev: %+.0f%%/%+.0f%%\n",
        lbl, m_al, m_ar, m_bl, m_br, m_ht, m_gn, m_wm, min_ar-m_ar, max_ar-m_ar, sd_ar, min_br-m_br, max_br-m_br, sd_br, min_gn-m_gn, max_gn-m_gn
    }
  '
}

cell_5g() {
  ensure_workload_scripts
  local label="$1"; shift
  local num_trials="${TRIALS:-3}"
  local t a b h0 m0 f0 u0 e0 h1 m1 f1 u1 e1 warm
  local a_lat a_rps a_s1 a_s2 b_lat b_rps b_s1 b_s2 hit_pct gain_pct u_delta e_delta
  local trials_data=""

  for t in $(seq 1 "$num_trials"); do
    reset_pgcache
    flush_os_page_cache

    a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")
    flush_os_page_cache
    warm=$(warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' "$@")
    kubectl -n "$NS" exec deploy/pgcache -- psql -h 127.0.0.1 -p 5433 -U postgres -d pgcache_cache -q -c "CHECKPOINT;" >/dev/null 2>&1 || true
    kubectl -n "$NS" exec deploy/pgcache -- sh -c "sync && echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1 || true

    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    b=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" "$@")
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"

    read -r a_lat a_rps a_s1 a_s2 <<<"$a"
    read -r b_lat b_rps b_s1 b_s2 <<<"$b"

    u_delta=$((u1 - u0))
    e_delta=$((e1 - e0))
    hit_pct=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) -v u="$u_delta" 'BEGIN{tot=h+m+u; printf "%.2f", tot?100*h/tot:0}')
    gain_pct=$(awk -v x="${a_rps:-0}" -v y="${b_rps:-0}" 'BEGIN{printf "%.1f", (x+0>0)?100*((y+0)/(x+0)-1):0}')

    printf "  [Trial %d/%d] %-12s | A: %s ms (%s rps) | B: %s ms (%s rps) | hit: %s%% | gain: %+0.1f%% | warm: %s\n" \
      "$t" "$num_trials" "$label" "${a_lat:-0.000}" "${a_rps:-0}" "${b_lat:-0.000}" "${b_rps:-0}" "$hit_pct" "$gain_pct" "$warm" >&2

    if [ "$t" -eq "$num_trials" ]; then
      print_pg_io_telemetry "$label (Trial $t)"
    fi

    trials_data="${trials_data}${a_lat:-0.000} ${a_rps:-0} ${b_lat:-0.000} ${b_rps:-0} ${hit_pct} ${gain_pct} ${warm}"$'\n'
  done

  echo "$trials_data" | awk -v lbl="$label" '
    NF >= 7 {
      n++
      al[n]=$1; ar[n]=$2; bl[n]=$3; br[n]=$4; ht[n]=$5; gn[n]=$6; wm[n]=$7
      s_al+=$1; s_ar+=$2; s_bl+=$3; s_br+=$4; s_ht+=$5; s_gn+=$6; s_wm+=$7
      if(n==1 || $2<min_ar) min_ar=$2; if(n==1 || $2>max_ar) max_ar=$2
      if(n==1 || $4<min_br) min_br=$4; if(n==1 || $4>max_br) max_br=$4
      if(n==1 || $6<min_gn) min_gn=$6; if(n==1 || $6>max_gn) max_gn=$6
    }
    END {
      if (n == 0) exit
      m_al=s_al/n; m_ar=s_ar/n; m_bl=s_bl/n; m_br=s_br/n; m_ht=s_ht/n; m_gn=s_gn/n; m_wm=s_wm/n
      for(i=1;i<=n;i++) {
        v_ar += (ar[i] - m_ar)^2
        v_br += (br[i] - m_br)^2
      }
      sd_ar = (n>1) ? sqrt(v_ar/(n-1)) : 0
      sd_br = (n>1) ? sqrt(v_br/(n-1)) : 0
      printf "%-12s %9.3f %6.0f %10.3f %6.0f %7.1f%% %+7.0f%% %5.1f  | A_rps_dev: %+.0f/%+.0f (sd %.1f) | B_rps_dev: %+.0f/%+.0f (sd %.1f) | gain_dev: %+.0f%%/%+.0f%%\n",
        lbl, m_al, m_ar, m_bl, m_br, m_ht, m_gn, m_wm, min_ar-m_ar, max_ar-m_ar, sd_ar, min_br-m_br, max_br-m_br, sd_br, min_gn-m_gn, max_gn-m_gn
    }
  '
}

cell_mixed_cdc_5g() {
  ensure_workload_scripts
  local label="$1"
  local num_trials="${TRIALS:-3}"
  local read_clients=7
  local write_clients=1
  local t a b h0 m0 f0 u0 e0 h1 m1 f1 u1 e1 warm
  local a_lat a_rps a_s1 a_s2 b_lat b_rps b_s1 b_s2 hit_pct gain_pct
  local trials_data=""

  for t in $(seq 1 "$num_trials"); do
    ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c 'DELETE FROM order_item WHERE id >= 100000000; DELETE FROM orders WHERE id >= 100000000;' >/dev/null 2>&1" || true
    reset_pgcache
    flush_os_page_cache

    # Path A: 7 read clients + 1 write client on Origin
    a=$(CLIENTS=8 THREADS=4 run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" \
      -D tenants="$ACTIVE_TENANTS" -D wtenants="$ACTIVE_TENANTS" \
      -f /tmp/mt/complex-mv-heavy.sql@90 -f /tmp/mt/write.sql@10)

    ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c 'DELETE FROM order_item WHERE id >= 100000000; DELETE FROM orders WHERE id >= 100000000;' >/dev/null 2>&1" || true
    reset_pgcache
    flush_os_page_cache

    # Warm Path B reads first
    warm=$(CLIENTS=7 THREADS=4 warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' \
      -D tenants="$ACTIVE_TENANTS" -f /tmp/mt/complex-mv-heavy.sql)
    kubectl -n "$NS" exec deploy/pgcache -- psql -h 127.0.0.1 -p 5433 -U postgres -d pgcache_cache -q -c "CHECKPOINT;" >/dev/null 2>&1 || true
    kubectl -n "$NS" exec deploy/pgcache -- sh -c "sync && echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1 || true

    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    # Run concurrent background writer against Origin (1 client) while 7 clients read PgCache
    ex "pgbench -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -n -M simple -c $write_clients -j 1 -T $DURATION -D tenants=$ACTIVE_TENANTS -D wtenants=$ACTIVE_TENANTS -f /tmp/mt/write.sql \$PGDATABASE >/dev/null 2>&1" &
    local bg_pid=$!
    b=$(CLIENTS="$read_clients" THREADS=4 run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" \
      -D tenants="$ACTIVE_TENANTS" -f /tmp/mt/complex-mv-heavy.sql)
    wait "$bg_pid" 2>/dev/null || true
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"

    read -r a_lat a_rps a_s1 a_s2 <<<"$a"
    read -r b_lat b_rps b_s1 b_s2 <<<"$b"

    hit_pct=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) -v u=$((u1-u0)) 'BEGIN{tot=h+m+u; printf "%.2f", tot?100*h/tot:0}')
    gain_pct=$(awk -v x="${a_rps:-0}" -v y="${b_rps:-0}" 'BEGIN{printf "%.1f", (x+0>0)?100*((y+0)/(x+0)-1):0}')

    printf "  [Trial %d/%d] %-12s | A: %s ms (%s rps) | B: %s ms (%s rps) | hit: %s%% | gain: %+0.1f%% | warm: %s\n" \
      "$t" "$num_trials" "$label" "${a_lat:-0.000}" "${a_rps:-0}" "${b_lat:-0.000}" "${b_rps:-0}" "$hit_pct" "$gain_pct" "$warm" >&2

    if [ "$t" -eq "$num_trials" ]; then
      print_pg_io_telemetry "$label (Trial $t)"
    fi

    trials_data="${trials_data}${a_lat:-0.000} ${a_rps:-0} ${b_lat:-0.000} ${b_rps:-0} ${hit_pct} ${gain_pct} ${warm}"$'\n'
  done

  echo "$trials_data" | awk -v lbl="$label" '
    NF >= 7 {
      n++
      al[n]=$1; ar[n]=$2; bl[n]=$3; br[n]=$4; ht[n]=$5; gn[n]=$6; wm[n]=$7
      s_al+=$1; s_ar+=$2; s_bl+=$3; s_br+=$4; s_ht+=$5; s_gn+=$6; s_wm+=$7
      if(n==1 || $2<min_ar) min_ar=$2; if(n==1 || $2>max_ar) max_ar=$2
      if(n==1 || $4<min_br) min_br=$4; if(n==1 || $4>max_br) max_br=$4
      if(n==1 || $6<min_gn) min_gn=$6; if(n==1 || $6>max_gn) max_gn=$6
    }
    END {
      if (n == 0) exit
      m_al=s_al/n; m_ar=s_ar/n; m_bl=s_bl/n; m_br=s_br/n; m_ht=s_ht/n; m_gn=s_gn/n; m_wm=s_wm/n
      for(i=1;i<=n;i++) {
        v_ar += (ar[i] - m_ar)^2
        v_br += (br[i] - m_br)^2
      }
      sd_ar = (n>1) ? sqrt(v_ar/(n-1)) : 0
      sd_br = (n>1) ? sqrt(v_br/(n-1)) : 0
      printf "%-12s %9.3f %6.0f %10.3f %6.0f %7.1f%% %+7.0f%% %5.1f  | A_rps_dev: %+.0f/%+.0f (sd %.1f) | B_rps_dev: %+.0f/%+.0f (sd %.1f) | gain_dev: %+.0f%%/%+.0f%%\n",
        lbl, m_al, m_ar, m_bl, m_br, m_ht, m_gn, m_wm, min_ar-m_ar, max_ar-m_ar, sd_ar, min_br-m_br, max_br-m_br, sd_br, min_gn-m_gn, max_gn-m_gn
    }
  '
}

if [ "${ONLY_CDC:-0}" = "1" ]; then
  WORKLOAD_SCRIPTS_READY=0
  ensure_workload_scripts
  cell_mixed_cdc_5g "mv5g_cdc9010"
  exit 0
fi

echo "========================================================================"
echo " SWEEP 9: 5 GB (SCALE=10) Memory-Constrained NVMe vs SSD Study (TRIALS=$TRIALS)"
echo " Disk Tier: $DISK_TIER | Concurrency: c=$CLIENTS, j=$THREADS | Duration: ${DURATION}s"
echo "========================================================================"

if [ "$BENCH_ENV" = "k8s" ]; then
  kubectl -n "$NS" rollout status statefulset/origin --timeout=5m
  kubectl -n "$NS" rollout status deploy/loadgen --timeout=3m
  "$REPO_ROOT/scripts/tune-network.sh" >/dev/null 2>&1 || true
  kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m

  echo "--> Node Hardware & Topology:"
  kubectl get nodes -o wide
  echo ""
  echo "--> Running Storage & CPU Micro-Benchmark inside PgCache Pod (/var/lib/postgresql/data):"
  kubectl -n "$NS" exec deploy/pgcache -- bash -c '
    export PATH="/usr/lib/postgresql/17/bin:/usr/lib/postgresql/16/bin:$PATH"
    TEST_DIR="/var/lib/postgresql/data"
    [ -d "$TEST_DIR" ] || TEST_DIR="/var/lib/postgresql"
    echo "--- Mount & Filesystem ($TEST_DIR) ---"
    df -Th "$TEST_DIR" || true
    echo "--- CPU Model ---"
    grep -E -m2 "model name|cpu MHz|cache size" /proc/cpuinfo || true
    echo "--- Memory & Cgroup Limits (PgCache Pod) ---"
    echo "cgroup memory.max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo unknown)"
    psql -h 127.0.0.1 -p 5433 -U postgres -d postgres -tAc \
      "SELECT name, setting, unit FROM pg_settings WHERE name ~ \$\$^(max_connections|shared_buffers|effective_cache_size|work_mem|maintenance_work_mem|fsync)\$\$;" || true
    echo "--- Sequential Sync Write 256MB ($TEST_DIR) ---"
    dd if=/dev/zero of="$TEST_DIR/bench_io_test" bs=1M count=256 conv=fsync 2>&1 || true
    rm -f "$TEST_DIR/bench_io_test"
    echo "--- PostgreSQL pg_test_fsync (3s per method on $TEST_DIR) ---"
    pg_test_fsync -s 3 -f "$TEST_DIR/pg_fsync_test"
    rm -f "$TEST_DIR/pg_fsync_test"
  '
  echo ""
  echo "--> Origin Database Size & Memory Settings (SCALE=10, ~5 GB Dataset):"
  ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c 'ALTER DATABASE bench SET random_page_cost = 0.2;' -c 'ALTER SYSTEM SET random_page_cost = 0.2;' -c 'SELECT pg_reload_conf();'" >/dev/null 2>&1 || true
  ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -tAc \"
    SELECT 'Origin DB Size: ' || pg_size_pretty(pg_database_size(current_database()));
    SELECT name || '=' || setting || coalesce(unit, '') FROM pg_settings WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'max_wal_size', 'fsync', 'random_page_cost');
  \""
fi

WORKLOAD_SCRIPTS_READY=0
ensure_workload_scripts

if [ "${ONLY_CDC:-0}" = "1" ]; then
  cell_mixed_cdc_5g "mv5g_cdc9010"
  exit 0
fi

echo ""
echo "========================================================================"
echo " Phase 1: 5 GB Dataset — Cold Creation, Wide MVs (LIMIT 500), Zipfian & CDC (c=16)"
echo "========================================================================"
header mv5g_stress

# 1. Cold & 30s Warm-Up MV Creation Storm on Wide MVs (LIMIT 500, c=16)
if [ "${SKIP_TO_DASH:-0}" != "1" ]; then
  DURATION=15 measure_fixed_warmup_5g "mv5g_cold0s"  0  -D tenants="$ACTIVE_TENANTS" -f /tmp/mt/complex-mv-heavy.sql
  DURATION=15 measure_fixed_warmup_5g "mv5g_warm30s" 30 -D tenants="$ACTIVE_TENANTS" -f /tmp/mt/complex-mv-heavy.sql

  # 2. Settled Wide MVs (LIMIT 500 rows per MV, 4-to-6 table JOINs & aggregations, c=16)
  cell_5g "mv5g_heavy"    -D tenants="$ACTIVE_TENANTS" -f /tmp/mt/complex-mv-heavy.sql
fi

# 3. Settled 8-Query Enterprise Dashboard on 5 GB Dataset (c=16)
cell_5g "mv5g_dash"     -D tenants="$ACTIVE_TENANTS" -f /tmp/mt/complex-dashboard.sql

# 4. 1,000-Tenant Zipfian Pareto 80/20 Across the Full 5 GB Dataset (c=16)
MAX_WARM_PASSES=3 cell_5g "mv5g_zipf1000" -D tenants="$SEED_TENANTS" -f /tmp/mt/complex-dashboard-zipfian.sql

# 5. Live 90/10 Read/Write CDC Invalidation & MV Re-materialization Storm on 5 GB Dataset (c=16)
cell_mixed_cdc_5g "mv5g_cdc9010"
