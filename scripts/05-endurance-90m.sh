#!/usr/bin/env bash
# ============================================================================
# SWEEP 5 -- 1h30m (90-Minute) Endurance & Resource Offload Benchmark
#
# Designed for DigitalOcean Kubernetes (DOKS) + Grafana Cloud observability:
#   - Block 1 (60m + warm-up):
#       * Phase 1 (30m): 100% Read on Origin PostgreSQL (Path A)
#       * Phase 2 (Warm-up): Dynamic warm_until_settled on PgCache
#       * Phase 3 (30m): 100% Read on PgCache Proxy (Path B)
#   - Block 2 (30m + warm-up):
#       * Phase 4 (15m): Mixed Read + Write on Origin PostgreSQL (Path A)
#       * Phase 5 (Warm-up): Dynamic warm_until_settled on PgCache
#       * Phase 6 (15m): Mixed Read + Write on PgCache Proxy (Path B)
#
# Configurable environment variables:
#   SCALE=20               Database scale factor (20 -> ~11 GB; 30 -> ~17 GB)
#   TOTAL_TENANTS=1000     Total tenants seeded in the database
#   ACTIVE_TENANTS=100     Active tenants queried during the benchmark
#   CLIENTS=16             Concurrent pgbench clients
#   THREADS=4              pgbench worker threads
#   WORKLOAD=complex-dashboard.sql
#   READ_DURATION=1800     Seconds per path for Read block (default: 1800 = 30m)
#   WRITE_DURATION=900     Seconds per path for Read/Write block (default: 900 = 15m)
#   WRITE_PCT=5            Write percentage in Read/Write block (default: 5%)
#   SKIP_SETUP=0           Set to 1 to skip 00-setup.sh check
# ============================================================================

set -uo pipefail
source "$(dirname "$0")/lib.sh"

SCALE="${SCALE:-20}"
TOTAL_TENANTS="${TOTAL_TENANTS:-1000}"
ACTIVE_TENANTS="${ACTIVE_TENANTS:-100}"
CLIENTS="${CLIENTS:-16}"
THREADS="${THREADS:-4}"
WORKLOAD="${WORKLOAD:-complex-dashboard.sql}"
READ_DURATION="${READ_DURATION:-1800}"
WRITE_DURATION="${WRITE_DURATION:-900}"
WRITE_PCT="${WRITE_PCT:-5}"
READ_PCT=$((100 - WRITE_PCT))
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-10}"
MON_NS="${MON_NS:-monitoring}"

echo "========================================================================"
echo " PgCache vs Origin -- 1h30m Endurance & Resource Offload Campaign"
echo " Environment:      $BENCH_ENV"
echo " Database Scale:   SCALE=$SCALE ($TOTAL_TENANTS total tenants)"
echo " Active Tenants:   $ACTIVE_TENANTS active tenants"
echo " Concurrency:      $CLIENTS clients ($THREADS threads)"
echo " Read Workload:    $WORKLOAD"
echo " Block 1 (Read):   ${READ_DURATION}s Origin + Warm-up + ${READ_DURATION}s PgCache"
echo " Block 2 (Write):  ${WRITE_DURATION}s Origin + Warm-up + ${WRITE_DURATION}s PgCache (${WRITE_PCT}% writes)"
echo "========================================================================"

# 1. Seed / verify database scale if needed
if [ "${SKIP_SETUP:-0}" != "1" ]; then
  echo ""
  echo "--> Step 1: Verifying / Seeding Database (SCALE=$SCALE, TENANTS=$TOTAL_TENANTS)..."
  SCALE="$SCALE" TENANTS="$TOTAL_TENANTS" "$SCRIPTS_DIR/00-setup.sh"
fi

ensure_workload_scripts

# 2. Helper to push live pgbench metrics to pgbench-exporter (:9105/metrics)
push_live_metrics() {
  local phase_id="$1"
  local is_pgcache="$2"
  local write_pct="$3"
  local tps="$4"
  local lat="$5"
  local stddev="$6"

  if [ "$BENCH_ENV" = "k8s" ]; then
    kubectl -n "$MON_NS" exec deploy/pgbench-exporter -- sh -c "cat <<'EOF' > /www/metrics.tmp && mv /www/metrics.tmp /www/metrics
# HELP pgbench_live_tps Current live transactions per second from pgbench
# TYPE pgbench_live_tps gauge
pgbench_live_tps ${tps:-0}
# HELP pgbench_live_latency_ms Current live average transaction latency in milliseconds
# TYPE pgbench_live_latency_ms gauge
pgbench_live_latency_ms ${lat:-0}
# HELP pgbench_live_latency_stddev_ms Current live latency standard deviation in milliseconds
# TYPE pgbench_live_latency_stddev_ms gauge
pgbench_live_latency_stddev_ms ${stddev:-0}
# HELP pgbench_phase_id Current benchmark phase (0=idle, 1=read_origin_30m, 2=read_warmup, 3=read_pgcache_30m, 4=rw_origin_15m, 5=rw_warmup, 6=rw_pgcache_15m)
# TYPE pgbench_phase_id gauge
pgbench_phase_id ${phase_id:-0}
# HELP pgbench_target_is_pgcache Target under test (0=Origin PostgreSQL, 1=PgCache Proxy)
# TYPE pgbench_target_is_pgcache gauge
pgbench_target_is_pgcache ${is_pgcache:-0}
# HELP pgbench_write_ratio_pct Percentage of write transactions in current workload
# TYPE pgbench_write_ratio_pct gauge
pgbench_write_ratio_pct ${write_pct:-0}
# HELP pgbench_active_clients Number of concurrent pgbench clients
# TYPE pgbench_active_clients gauge
pgbench_active_clients ${CLIENTS}
# HELP pgbench_active_tenants Number of active tenants in the workload
# TYPE pgbench_active_tenants gauge
pgbench_active_tenants ${ACTIVE_TENANTS}
EOF" >/dev/null 2>&1 || true
  fi
}

# 3. Run pgbench with live progress (-P) streaming to both terminal and Grafana Cloud
#    Usage: run_streamed <phase_id> <is_pgcache> <write_pct> <label> <host> <port> <secs> <pgbench_args...>
#    Sets global: LAST_LAT_MS, LAST_TPS
run_streamed() {
  local phase_id="$1" is_pgcache="$2" write_pct="$3" label="$4"
  local host="$5" port="$6" secs="$7"
  shift 7

  local threads=$THREADS
  [ "$threads" -gt "$CLIENTS" ] && threads="$CLIENTS"

  push_live_metrics "$phase_id" "$is_pgcache" "$write_pct" 0 0 0

  local tmp_out="/tmp/pgbench_endurance.$$"
  rm -f "$tmp_out"

  echo ""
  echo "------------------------------------------------------------------------"
  echo " [$(date -u '+%Y-%m-%d %H:%M:%S UTC')] STARTING: $label (${secs}s)"
  echo "------------------------------------------------------------------------"

  if [ "$BENCH_ENV" = "docker" ]; then
    docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
      bash -c "pgbench -h $host -p $port -U \$PGUSER -n -P $PROGRESS_INTERVAL -c $CLIENTS -j $threads -T $secs $* \$PGDATABASE" 2>&1 | tee "$tmp_out"
  else
    kubectl -n "$NS" exec -c bench deploy/loadgen -- \
      bash -c "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; pgbench -h $host -p $port -U \$PGUSER -n -P $PROGRESS_INTERVAL -c $CLIENTS -j $threads -T $secs $* \$PGDATABASE" 2>&1 | \
      while IFS= read -r line; do
        echo "$line"
        echo "$line" >> "$tmp_out"
        if [[ "$line" == progress:* ]]; then
          # Example: progress: 10.0 s, 1420.5 tps, lat 5.621 ms stddev 1.210, 0 failed
          read -r p_tps p_lat p_std <<<"$(echo "$line" | awk '{
            tps=0; lat=0; std=0;
            for(i=1;i<=NF;i++){
              if($i=="tps,") tps=$(i-1);
              if($i=="lat") lat=$(i+1);
              if($i=="stddev") { sub(/,/, "", $(i+1)); std=$(i+1); }
            }
            print tps+0, lat+0, std+0
          }')"
          push_live_metrics "$phase_id" "$is_pgcache" "$write_pct" "$p_tps" "$p_lat" "$p_std" &
        fi
      done
  fi

  wait 2>/dev/null || true

  read -r LAST_LAT_MS LAST_TPS <<<"$(awk '
    BEGIN { l="0.000"; t=0 }
    /^latency average/ { if($4!="" && $4!="NaN") l=$4 }
    /^tps/             { if($3!="" && $3!="NaN") t=$3 }
    END { if (t+0 > 0 && t+0 < 10) printf "%s %.2f\n", l, t; else printf "%s %.0f\n", l, t }
  ' "$tmp_out")"
  rm -f "$tmp_out"

  echo "--> Completed $label: avg_latency=${LAST_LAT_MS} ms, avg_tps=${LAST_TPS}"
}

# 4. Dynamic warm-up with live telemetry updates
warm_with_telemetry() {
  local phase_id="$1" write_pct="$2" label="$3"
  shift 3
  local prev=-1 cur h0 m0 f0 h1 m1 f1 p
  local max_passes="${MAX_WARM_PASSES:-8}"
  local warm_secs="${WARM_PASS_DURATION:-30}"

  echo ""
  echo "------------------------------------------------------------------------"
  echo " [$(date -u '+%Y-%m-%d %H:%M:%S UTC')] WARM-UP: $label (warm_until_settled)"
  echo "------------------------------------------------------------------------"

  for p in $(seq 1 "$max_passes"); do
    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    run_streamed "$phase_id" 1 "$write_pct" "$label (Pass $p/$max_passes)" '$PGCACHE_HOST' '$PGCACHE_PORT' "$warm_secs" "$@"
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"
    cur=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) -v f=$((f1-f0)) -v u=$((u1-u0)) 'BEGIN{eh=h-f; if(eh<0)eh=0; tot=h+m+u; printf "%.4f", tot?eh/tot:0}')
    echo "--> Warm-up Pass $p effective hit ratio: $(awk -v c="$cur" 'BEGIN{printf "%.2f%%", c*100}')"
    if awk -v c="$cur" -v q="$prev" 'BEGIN{exit !(q >= 0 && c > 0.05 && c-q < 0.01 && c-q > -0.01)}'; then
      echo "--> Cache settled after $p passes!"
      WARM_PASSES_TAKEN="$p"
      return 0
    fi
    prev="$cur"
  done
  WARM_PASSES_TAKEN="$max_passes"
}

# ============================================================================
# BLOCK 1: 100% READ (30m Origin vs 30m PgCache)
# ============================================================================

# Phase 1: 30m Pure Read on Origin (Path A)
run_streamed 1 0 0 "Phase 1/6: Origin Direct -- 100% Read" \
  '$ORIGIN_HOST' '$ORIGIN_PORT' "$READ_DURATION" \
  -f "/tmp/mt/$WORKLOAD" -D tenants="$ACTIVE_TENANTS"
READ_A_LAT="$LAST_LAT_MS"
READ_A_TPS="$LAST_TPS"

# Phase 2: Reset PgCache & Dynamic Warm-up for Pure Read
reset_pgcache
warm_with_telemetry 2 0 "Phase 2/6: PgCache Warm-up -- 100% Read" \
  -f "/tmp/mt/$WORKLOAD" -D tenants="$ACTIVE_TENANTS"
READ_WARM_PASSES="$WARM_PASSES_TAKEN"

# Phase 3: 30m Pure Read on PgCache (Path B)
read -r rh0 rm0 rf0 ru0 re0 <<<"$(scrape)"
run_streamed 3 1 0 "Phase 3/6: PgCache Proxy -- 100% Read" \
  '$PGCACHE_HOST' '$PGCACHE_PORT' "$READ_DURATION" \
  -f "/tmp/mt/$WORKLOAD" -D tenants="$ACTIVE_TENANTS"
read -r rh1 rm1 rf1 ru1 re1 <<<"$(scrape)"
READ_B_LAT="$LAST_LAT_MS"
READ_B_TPS="$LAST_TPS"
READ_HIT_PCT=$(awk -v h=$((rh1-rh0)) -v m=$((rm1-rm0)) -v u=$((ru1-ru0)) 'BEGIN{tot=h+m+u; printf "%.1f", tot?100*h/tot:0}')
READ_GAIN_PCT=$(awk -v x="${READ_A_TPS:-0}" -v y="${READ_B_TPS:-0}" 'BEGIN{printf "%+.0f", (x+0>0)?100*((y+0)/(x+0)-1):0}')

# ============================================================================
# BLOCK 2: MIXED READ + WRITE (15m Origin vs 15m PgCache)
# ============================================================================

# Phase 4: 15m Mixed Read/Write on Origin (Path A)
run_streamed 4 0 "$WRITE_PCT" "Phase 4/6: Origin Direct -- ${READ_PCT}% Read / ${WRITE_PCT}% Write" \
  '$ORIGIN_HOST' '$ORIGIN_PORT' "$WRITE_DURATION" \
  -f "/tmp/mt/$WORKLOAD@$READ_PCT" -f "/tmp/mt/write.sql@$WRITE_PCT" \
  -D tenants="$ACTIVE_TENANTS" -D wtenants="$ACTIVE_TENANTS"
RW_A_LAT="$LAST_LAT_MS"
RW_A_TPS="$LAST_TPS"

# Phase 5: Dynamic Warm-up / CDC stabilization on PgCache
MAX_WARM_PASSES=4 warm_with_telemetry 5 "$WRITE_PCT" "Phase 5/6: PgCache Warm-up -- ${READ_PCT}% Read / ${WRITE_PCT}% Write" \
  -f "/tmp/mt/$WORKLOAD@$READ_PCT" -f "/tmp/mt/write.sql@$WRITE_PCT" \
  -D tenants="$ACTIVE_TENANTS" -D wtenants="$ACTIVE_TENANTS"
RW_WARM_PASSES="$WARM_PASSES_TAKEN"

# Phase 6: 15m Mixed Read/Write on PgCache (Path B)
read -r wh0 wm0 wf0 wu0 we0 <<<"$(scrape)"
run_streamed 6 1 "$WRITE_PCT" "Phase 6/6: PgCache Proxy -- ${READ_PCT}% Read / ${WRITE_PCT}% Write" \
  '$PGCACHE_HOST' '$PGCACHE_PORT' "$WRITE_DURATION" \
  -f "/tmp/mt/$WORKLOAD@$READ_PCT" -f "/tmp/mt/write.sql@$WRITE_PCT" \
  -D tenants="$ACTIVE_TENANTS" -D wtenants="$ACTIVE_TENANTS"
read -r wh1 wm1 wf1 wu1 we1 <<<"$(scrape)"
RW_B_LAT="$LAST_LAT_MS"
RW_B_TPS="$LAST_TPS"
RW_HIT_PCT=$(awk -v h=$((wh1-wh0)) -v m=$((wm1-wm0)) -v u=$((wu1-wu0)) 'BEGIN{tot=h+m+u; printf "%.1f", tot?100*h/tot:0}')
RW_GAIN_PCT=$(awk -v x="${RW_A_TPS:-0}" -v y="${RW_B_TPS:-0}" 'BEGIN{printf "%+.0f", (x+0>0)?100*((y+0)/(x+0)-1):0}')

# Reset live exporter to idle (phase 0)
push_live_metrics 0 0 0 0 0 0

# ============================================================================
# Final Summary Table
# ============================================================================
mkdir -p "$REPO_ROOT/data"
SUMMARY_FILE="$REPO_ROOT/data/run-endurance-90m.txt"

{
  echo "========================================================================"
  echo " ENDURANCE BENCHMARK SUMMARY ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))"
  echo " Scale: SCALE=$SCALE ($TOTAL_TENANTS total tenants, $ACTIVE_TENANTS active)"
  echo " Clients: $CLIENTS | Workload: $WORKLOAD"
  echo "========================================================================"
  printf '%-18s %9s %8s %10s %8s %8s %8s %5s\n' \
    "block" "A_lat_ms" "A_tps" "B_lat_ms" "B_tps" "hit" "gain" "warm"
  printf '%-18s %9s %8s %10s %8s %7s%% %7s%% %5s\n' \
    "read_${READ_DURATION}s" "$READ_A_LAT" "$READ_A_TPS" "$READ_B_LAT" "$READ_B_TPS" "$READ_HIT_PCT" "$READ_GAIN_PCT" "$READ_WARM_PASSES"
  printf '%-18s %9s %8s %10s %8s %7s%% %7s%% %5s\n' \
    "rw_${WRITE_PCT}pct_${WRITE_DURATION}s" "$RW_A_LAT" "$RW_A_TPS" "$RW_B_LAT" "$RW_B_TPS" "$RW_HIT_PCT" "$RW_GAIN_PCT" "$RW_WARM_PASSES"
  echo "========================================================================"
} | tee "$SUMMARY_FILE"
