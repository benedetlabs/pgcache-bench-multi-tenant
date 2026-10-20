#!/usr/bin/env bash
# ============================================================================
# Shared helpers for the multi-tenant sweeps.
#
#   source lib.sh
#
# Key Capabilities:
#   - True Hit Ratio Denominator: Includes `pgcache_queries_uncacheable` in the
#     denominator (`hit / (hit + miss + uncacheable)`) so uncacheable queries
#     never masquerade as 100% cache hit ratios.
#   - Multi-Trial Statistical Execution (`TRIALS=1..N`, e.g. 3 or 5):
#     Runs each cell N times, optionally recreating pods (`reset_all_pods` or
#     `reset_pgcache`) between trials, and computes Mean, Negative/Positive
#     Deviation (`-Δ/+Δ` min/max spread), and Standard Deviation (`stddev`).
#   - Per-Script Read vs. Write Breakdown: When mixed read/write workloads run
#     (`-f read.sql@95 -f write.sql@5`), captures both combined and separate
#     read/write latencies.
#   - Environment Policy: Official benchmark numbers MUST be collected on the
#     3-node Kubernetes cluster (`BENCH_ENV=k8s`). Local Docker (`DOCKER=1`)
#     is exclusively for environment setup and functional/correctness testing.
# ============================================================================

set -uo pipefail

NS="${NS:-pgcache-mt}"
CLIENTS="${CLIENTS:-8}"
THREADS="${THREADS:-4}"
DURATION="${DURATION:-30}"
TRIALS="${TRIALS:-5}"
RECREATE_PODS_MODE="${RECREATE_PODS_MODE:-all}" # "all" (origin+pgcache+loadgen) or "pgcache"

BENCH_ENV="${BENCH_ENV:-${TARGET_ENV:-}}"
if [ -z "$BENCH_ENV" ]; then
  if [ "${DOCKER:-0}" = "1" ] || [ "${USE_DOCKER:-0}" = "1" ]; then
    BENCH_ENV="docker"
  else
    BENCH_ENV="k8s"
  fi
fi

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Fail loudly rather than silently producing a table of zeroes.
die() { echo "FATAL: $*" >&2; exit 1; }

# Run a command inside the loadgen pod or client container.
ex() {
  if [ "$BENCH_ENV" = "docker" ]; then
    docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client bash -c "$1"
  else
    local tries=0 out=""
    while [ $tries -lt 3 ]; do
      if out=$(kubectl -n "$NS" exec -c bench deploy/loadgen -- bash -c "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; $1" 2>&1); then
        echo "$out"
        return 0
      fi
      tries=$((tries + 1))
      sleep 1
    done
    echo "$out" >&2
    return 1
  fi
}

# ── Metrics ────────────────────────────────────────────────────────────────
#
# Scraped through the metrics-reader pod, NOT the loadgen pod. The loadgen image
# is postgres:17, which ships neither curl nor wget.
pgcache_ip() {
  if [ -n "${CACHED_PGCACHE_IP:-}" ]; then
    echo "$CACHED_PGCACHE_IP"
    return 0
  fi
  local ip="" tries=0
  while [ $tries -lt 5 ]; do
    ip=$(kubectl -n "$NS" get pod -l app=pgcache -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
    if [ -n "$ip" ]; then
      CACHED_PGCACHE_IP="$ip"
      echo "$ip"
      return 0
    fi
    tries=$((tries + 1))
    sleep 2
  done
  return 1
}

# Prints: <hits> <misses> <mv_fallthrough> <uncacheable> <cache_error>
# Counters are cumulative since the PgCache process started, so callers take a
# DELTA around the measured window rather than reading them absolutely.
scrape() {
  local awk_prog='
    /^pgcache_queries_cache_hit /     {h=$2}
    /^pgcache_queries_cache_miss /    {m=$2}
    /^pgcache_cache_mv_fallthrough /  {f=$2}
    /^pgcache_queries_uncacheable /   {u=$2}
    /^pgcache_queries_cache_error /   {e=$2}
    END { printf "%d %d %d %d %d\n", h+0, m+0, f+0, u+0, e+0 }
  '
  if [ "$BENCH_ENV" = "docker" ]; then
    if curl -sf --connect-timeout 5 http://127.0.0.1:59090/metrics >/tmp/metrics.scrape.$$ 2>/dev/null && grep -q "pgcache_queries_" /tmp/metrics.scrape.$$; then
      awk "$awk_prog" /tmp/metrics.scrape.$$
      rm -f /tmp/metrics.scrape.$$
    else
      local out
      out=$(docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T metrics-reader \
        sh -c "wget -qO- --timeout=20 http://pgcache:9090/metrics" 2>/dev/null || true)
      if [ -n "$out" ] && echo "$out" | grep -q "pgcache_queries_"; then
        echo "$out" | awk "$awk_prog"
      else
        die "could not scrape pgcache metrics in docker"
      fi
    fi
  else
    local ip; ip="$(pgcache_ip)"
    [ -n "$ip" ] || die "could not resolve the pgcache pod IP"
    local mport="${PGCACHE_METRICS_PORT:-${CACHED_PGCACHE_MPORT:-}}"
    if [ -z "$mport" ]; then
      mport=$(kubectl -n "$NS" get svc pgcache -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "9091")
      [ -z "$mport" ] && mport="9091"
      CACHED_PGCACHE_MPORT="$mport"
    fi
    local out="" tries=0
    while [ $tries -lt 5 ]; do
      out=$(kubectl -n "$NS" exec deploy/metrics-reader -- \
        sh -c "wget -qO- --timeout=20 http://$ip:$mport/metrics" 2>/dev/null || true)
      if [ -n "$out" ] && echo "$out" | grep -q "pgcache_queries_"; then
        break
      fi
      tries=$((tries + 1))
      sleep 2
    done
    [ -n "$out" ] || die "failed to scrape pgcache metrics from metrics-reader (port $mport)"
    echo "$out" | awk "$awk_prog"
  fi
}

# ── Load ───────────────────────────────────────────────────────────────────
#
# $1 host-var  $2 port-var  $3 seconds  $4.. extra pgbench args
# Prints: <latency_ms> <tps> <read_lat_ms> <write_lat_ms>
run() {
  local host="$1" port="$2" secs="$3"; shift 3
  local threads=$THREADS
  [ "$threads" -gt "$CLIENTS" ] && threads="$CLIENTS"
  local out
  out=$(ex "pgbench -h $host -p $port -U \$PGUSER -n -c $CLIENTS -j $threads -T $secs $* \$PGDATABASE" 2>&1) \
    || die "pgbench failed: $(echo "$out" | tail -3)"
  echo "$out" | awk '
    BEGIN { l="0.000"; t=0; s1_lat="-"; s2_lat="-"; cur_s=0 }
    /^latency average/ { if($4!="" && $4!="NaN") l=$4 }
    /^tps/             { if($3!="" && $3!="NaN") t=$3 }
    /^SQL script 1:/   { cur_s=1 }
    /^SQL script 2:/   { cur_s=2 }
    /latency average =/ && cur_s==1 { for(i=1;i<=NF;i++) if($i=="average") s1_lat=$(i+2) }
    /latency average =/ && cur_s==2 { for(i=1;i<=NF;i++) if($i=="average") s2_lat=$(i+2) }
    END { printf "%s %.0f %s %s\n", l, t, s1_lat, s2_lat }
  '
}

# ── Warm-up ────────────────────────────────────────────────────────────────
#
# Repeats passes until the effective hit ratio stops climbing (< 1% delta),
# including `pgcache_queries_uncacheable` in the total query denominator so
# uncacheable queries never inflate the reported hit ratio.
warm_until_settled() {
  local host="$1" port="$2"; shift 2
  local prev=-1 cur h0 m0 f0 u0 e0 h1 m1 f1 u1 e1 p
  local max_passes="${MAX_WARM_PASSES:-8}"
  for p in $(seq 1 "$max_passes"); do
    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    run "$host" "$port" "$DURATION" "$@" >/dev/null
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"
    cur=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) -v f=$((f1-f0)) -v u=$((u1-u0)) \
      'BEGIN{eh=h-f; if(eh<0)eh=0; tot=h+m+u; printf "%.4f", tot?eh/tot:0}')
    if awk -v c="$cur" -v q="$prev" 'BEGIN{exit !(q >= 0 && c > 0.05 && c-q < 0.01 && c-q > -0.01)}'; then
      echo "$p"; return 0
    fi
    prev="$cur"
  done
  echo "$max_passes"
}

# ── Reset PgCache Pod / Container ──────────────────────────────────────────
#
# Cleanly recreates the pgcache pod/container so that SysV shared memory
# segments (pgcache_pgrx DSA) and registered MVs are released.
reset_pgcache() {
  if [ "$BENCH_ENV" = "docker" ]; then
    docker compose -f "$REPO_ROOT/infra/docker-compose.yml" up -d --force-recreate --renew-anon-volumes pgcache >/dev/null 2>&1
    local tries=0
    while [ $tries -lt 30 ]; do
      if curl -sf --connect-timeout 2 http://127.0.0.1:59090/metrics >/dev/null 2>&1 && \
         ex "pg_isready -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE >/dev/null 2>&1"; then
        sleep 1
        return 0
      fi
      tries=$((tries + 1))
      sleep 1
    done
  else
    kubectl -n "$NS" rollout restart deploy/pgcache >/dev/null 2>&1 || true
    kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m >/dev/null 2>&1 || true
    unset CACHED_PGCACHE_IP
    local ip mport tries=0
    ip="$(pgcache_ip)"
    mport="${PGCACHE_METRICS_PORT:-${CACHED_PGCACHE_MPORT:-}}"
    if [ -z "$mport" ]; then
      mport=$(kubectl -n "$NS" get svc pgcache -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "9091")
      [ -z "$mport" ] && mport="9091"
    fi
    while [ $tries -lt 30 ]; do
      ip="$(pgcache_ip)"
      if [ -n "$ip" ] && \
         kubectl -n "$NS" exec deploy/metrics-reader -- sh -c "wget -qO- --timeout=5 http://$ip:$mport/metrics" 2>/dev/null | grep -q "pgcache_queries_" && \
         ex "pg_isready -h \$PGCACHE_HOST -p \$PGCACHE_PORT -U \$PGUSER -d \$PGDATABASE >/dev/null 2>&1"; then
        sleep 1
        return 0
      fi
      tries=$((tries + 1))
      sleep 1
    done
  fi
}

# ── Full Pod Recreation (Origin + PgCache + Loadgen) Without Recreating K8s ─
#
# Recreates all benchmark pods on the existing Kubernetes cluster (keeping
# nodes and seeded PVCs intact) so each trial starts from a completely fresh
# process, memory, buffer pool, and connection state.
reset_all_pods() {
  # Clean up any benchmark INSERT rows (id >= 100,000,000) before restarting pods
  ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -c 'DELETE FROM order_item WHERE id >= 100000000; DELETE FROM orders WHERE id >= 100000000;' >/dev/null 2>&1" || true

  if [ "$BENCH_ENV" = "docker" ]; then
    docker compose -f "$REPO_ROOT/infra/docker-compose.yml" restart origin >/dev/null 2>&1 || true
    reset_pgcache
    return 0
  fi

  echo "  [reset_all_pods] Recreating origin, pgcache, and loadgen pods in namespace $NS..." >&2
  kubectl -n "$NS" rollout restart deploy/loadgen >/dev/null 2>&1 || true
  if kubectl -n "$NS" get statefulset origin >/dev/null 2>&1; then
    kubectl -n "$NS" rollout restart statefulset/origin >/dev/null 2>&1 || true
    kubectl -n "$NS" rollout status statefulset/origin --timeout=5m >/dev/null 2>&1 || true
  elif kubectl -n "$NS" get deploy origin >/dev/null 2>&1; then
    kubectl -n "$NS" rollout restart deploy/origin >/dev/null 2>&1 || true
    kubectl -n "$NS" rollout status deploy/origin --timeout=5m >/dev/null 2>&1 || true
  fi
  kubectl -n "$NS" rollout status deploy/loadgen --timeout=3m >/dev/null 2>&1 || true
  WORKLOAD_SCRIPTS_READY=0
  ensure_workload_scripts

  # Wait for Origin PostgreSQL to accept connections before restarting PgCache
  local tries=0
  while [ $tries -lt 30 ]; do
    if ex "pg_isready -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE >/dev/null 2>&1"; then
      break
    fi
    tries=$((tries + 1))
    sleep 2
  done

  reset_pgcache
}

# ── Ensure Workload Scripts ────────────────────────────────────────────────
ensure_workload_scripts() {
  if [ "$BENCH_ENV" = "k8s" ] && [ "${WORKLOAD_SCRIPTS_READY:-0}" != "1" ]; then
    kubectl -n "$NS" exec -c bench deploy/loadgen -- mkdir -p /tmp/mt 2>/dev/null || true
    for f in dashboard write complex-search complex-joins complex-analytics complex-dashboard complex-dashboard-zipfian; do
      if [ -f "$REPO_ROOT/workload/$f.sql" ]; then
        kubectl -n "$NS" exec -i -c bench deploy/loadgen -- bash -c "cat > /tmp/mt/$f.sql" < "$REPO_ROOT/workload/$f.sql" 2>/dev/null || true
      fi
    done
    WORKLOAD_SCRIPTS_READY=1
  fi
}

# ── One measured cell (Supports Single-Pass or Multi-Trial `TRIALS=3..5`) ──
#
# Runs path A, then warms and runs path B, and prints a result row.
# When TRIALS > 1 (e.g. TRIALS=3 or TRIALS=5):
#   - Recreates pods before each trial (`RECREATE_PODS_MODE=all` or `pgcache`)
#   - Computes mean, negative/positive deviation (`-Δ/+Δ` spread), and stddev
#     across all trials to eliminate single-run noise.
cell() {
  ensure_workload_scripts
  local label="$1"; shift
  local num_trials="${TRIALS:-1}"
  local t a b h0 m0 f0 u0 e0 h1 m1 f1 u1 e1 warm
  local a_lat a_rps a_s1 a_s2 b_lat b_rps b_s1 b_s2 hit_pct gain_pct u_delta e_delta
  local trials_data=""

  for t in $(seq 1 "$num_trials"); do
    if [ "$num_trials" -gt 1 ]; then
      if [ "$RECREATE_PODS_MODE" = "all" ]; then
        reset_all_pods
      else
        reset_pgcache
      fi
    fi

    a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")
    warm=$(warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' "$@")

    read -r h0 m0 f0 u0 e0 <<<"$(scrape)"
    b=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" "$@")
    read -r h1 m1 f1 u1 e1 <<<"$(scrape)"

    read -r a_lat a_rps a_s1 a_s2 <<<"$a"
    read -r b_lat b_rps b_s1 b_s2 <<<"$b"

    u_delta=$((u1 - u0))
    e_delta=$((e1 - e0))
    if [ "$u_delta" -gt 0 ] || [ "$e_delta" -gt 0 ]; then
      printf "  [WARN] Cell %s (trial %d/%d): uncacheable_delta=%d, cache_error_delta=%d\n" \
        "$label" "$t" "$num_trials" "$u_delta" "$e_delta" >&2
    fi

    hit_pct=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) -v u="$u_delta" 'BEGIN{tot=h+m+u; printf "%.2f", tot?100*h/tot:0}')
    gain_pct=$(awk -v x="${a_rps:-0}" -v y="${b_rps:-0}" 'BEGIN{printf "%.1f", (x+0>0)?100*((y+0)/(x+0)-1):0}')

    if [ "$num_trials" -gt 1 ]; then
      printf "  [Trial %d/%d] %-9s | A: %s ms (%s rps) | B: %s ms (%s rps) | hit: %s%% | gain: %+0.1f%% | warm: %s\n" \
        "$t" "$num_trials" "$label" "${a_lat:-0.000}" "${a_rps:-0}" "${b_lat:-0.000}" "${b_rps:-0}" "$hit_pct" "$gain_pct" "$warm" >&2
    fi

    trials_data="${trials_data}${a_lat:-0.000} ${a_rps:-0} ${b_lat:-0.000} ${b_rps:-0} ${hit_pct} ${gain_pct} ${warm}"$'\n'
  done

  if [ "$num_trials" -le 1 ]; then
    printf '%-9s %9s %6s %10s %6s %7.1f%% %+7.0f%% %5s\n' \
      "$label" "${a_lat:-0.000}" "${a_rps:-0}" "${b_lat:-0.000}" "${b_rps:-0}" \
      "$hit_pct" "$gain_pct" "$warm"
  else
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
          v_gn += (gn[i] - m_gn)^2
        }
        sd_ar = (n>1) ? sqrt(v_ar/(n-1)) : 0
        sd_br = (n>1) ? sqrt(v_br/(n-1)) : 0
        sd_gn = (n>1) ? sqrt(v_gn/(n-1)) : 0
        neg_ar = min_ar - m_ar
        pos_ar = max_ar - m_ar
        neg_br = min_br - m_br
        pos_br = max_br - m_br
        neg_gn = min_gn - m_gn
        pos_gn = max_gn - m_gn
        printf "%-9s %9.3f %6.0f %10.3f %6.0f %7.1f%% %+7.0f%% %5.1f  | A_rps_dev: %+.0f/%+.0f (sd %.1f) | B_rps_dev: %+.0f/%+.0f (sd %.1f) | gain_dev: %+.0f%%/%+.0f%%\n",
          lbl, m_al, m_ar, m_bl, m_br, m_ht, m_gn, m_wm, neg_ar, pos_ar, sd_ar, neg_br, pos_br, sd_br, neg_gn, pos_gn
      }
    '
  fi
}

header() {
  if [ "${TRIALS:-1}" -gt 1 ]; then
    printf '%-9s %9s %6s %10s %6s %8s %8s %5s  | %s\n' \
      "$1" A_lat_ms A_rps B_lat_ms B_rps hit gain warm "Multi-Trial Deviation (TRIALS=$TRIALS, -Δ/+Δ & stddev)"
  else
    printf '%-9s %9s %6s %10s %6s %8s %8s %5s\n' \
      "$1" A_lat_ms A_rps B_lat_ms B_rps hit gain warm
  fi
}
