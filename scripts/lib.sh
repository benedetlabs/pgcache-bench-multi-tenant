#!/usr/bin/env bash
# ============================================================================
# Shared helpers for the multi-tenant sweeps.
#
#   source lib.sh
#
# HONESTY NOTE: the mt1 campaign was driven by ad-hoc bash loops typed at a
# prompt. These are cleaned-up equivalents that perform the same measurements in
# the same order with the same parameters -- not a verbatim transcript. They are
# here so the campaign is reproducible from the repository, which it was not:
# every SQL file and driver loop lived only in /tmp inside a pod that no longer
# exists.
#
# Requires: kubectl with a context on the lab cluster, and the release deployed
# in namespace $NS with origin, pgcache and loadgen at 1 replica each.
# ============================================================================

set -uo pipefail

NS="${NS:-pgcache-mt}"
CLIENTS="${CLIENTS:-8}"
THREADS="${THREADS:-4}"
DURATION="${DURATION:-30}"

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
      if out=$(kubectl -n "$NS" exec deploy/loadgen -- bash -c "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; $1" 2>&1); then
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
# is postgres:17, which ships neither curl nor wget, and installing one at pod
# start is the exact fragility that killed an earlier campaign with exit 127.
#
# metrics-reader reaches PgCache over the node IP, which is what the headless
# Service resolves to under hostNetwork.
pgcache_ip() {
  kubectl -n "$NS" get pod -l app=pgcache -o jsonpath='{.items[0].status.podIP}'
}

# Prints: <cumulative_hits> <cumulative_misses> <cumulative_mv_fallthrough>
# Counters are cumulative since the PgCache process started, so callers take a
# DELTA around the measured window rather than reading them absolutely.
scrape() {
  if [ "$BENCH_ENV" = "docker" ]; then
    if curl -sf --connect-timeout 5 http://127.0.0.1:59090/metrics >/tmp/metrics.scrape.$$ 2>/dev/null && grep -q "pgcache_queries_" /tmp/metrics.scrape.$$; then
      awk '/^pgcache_queries_cache_hit /     {h=$2}
           /^pgcache_queries_cache_miss /    {m=$2}
           /^pgcache_cache_mv_fallthrough /  {f=$2}
           END { print h+0, m+0, f+0 }' /tmp/metrics.scrape.$$
      rm -f /tmp/metrics.scrape.$$
    else
      local out
      out=$(docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T metrics-reader \
        sh -c "wget -qO- --timeout=20 http://pgcache:9090/metrics" 2>/dev/null || true)
      if [ -n "$out" ] && echo "$out" | grep -q "pgcache_queries_"; then
        echo "$out" | awk '/^pgcache_queries_cache_hit /     {h=$2}
                           /^pgcache_queries_cache_miss /    {m=$2}
                           /^pgcache_cache_mv_fallthrough /  {f=$2}
                           END { print h+0, m+0, f+0 }'
      else
        die "could not scrape pgcache metrics in docker"
      fi
    fi
  else
    local ip; ip="$(pgcache_ip)"
    [ -n "$ip" ] || die "could not resolve the pgcache pod IP"
    local mport="${PGCACHE_METRICS_PORT:-}"
    if [ -z "$mport" ]; then
      mport=$(kubectl -n "$NS" get svc pgcache -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "9090")
      [ -z "$mport" ] && mport="9090"
    fi
    local out="" tries=0
    while [ $tries -lt 3 ]; do
      out=$(kubectl -n "$NS" exec deploy/metrics-reader -- \
        sh -c "wget -qO- --timeout=20 http://$ip:$mport/metrics" 2>/dev/null || true)
      if [ -n "$out" ] && echo "$out" | grep -q "pgcache_queries_"; then
        break
      fi
      tries=$((tries + 1))
      sleep 1
    done
    [ -n "$out" ] || die "failed to scrape pgcache metrics from metrics-reader (port $mport)"
    echo "$out" | awk '/^pgcache_queries_cache_hit /     {h=$2}
                       /^pgcache_queries_cache_miss /    {m=$2}
                       /^pgcache_cache_mv_fallthrough /  {f=$2}
                       END { print h+0, m+0, f+0 }'
  fi
}

# ── Load ───────────────────────────────────────────────────────────────────
#
# $1 host-var  $2 port-var  $3 seconds  $4.. extra pgbench args
# Prints: <latency_ms> <tps>
#
# -M simple is pgbench's own default and is not passed explicitly anywhere in
# this campaign. Under simple protocol the literal is interpolated into the SQL
# text before it is sent, which is the form PgCache caches. Both paths run it,
# so there is no confound -- unlike the openFGA lab, where simple protocol had
# to be forced on the cached path only.
run() {
  local host="$1" port="$2" secs="$3"; shift 3
  local threads=$THREADS
  [ "$threads" -gt "$CLIENTS" ] && threads="$CLIENTS"
  local out
  out=$(ex "pgbench -h $host -p $port -U \$PGUSER -n -c $CLIENTS -j $threads -T $secs $* \$PGDATABASE" 2>&1) \
    || die "pgbench failed: $(echo "$out" | tail -3)"
  echo "$out" | awk 'BEGIN{l="0.000"; t=0} /^latency average/{if($4!="" && $4!="NaN") l=$4} /^tps/{if($3!="" && $3!="NaN") t=$3} END{printf "%s %.0f\n", l, t}'
}

# ── Warm-up ────────────────────────────────────────────────────────────────
#
# THE MOST IMPORTANT FUNCTION HERE. Repeats passes until the hit ratio stops
# climbing, and reports how many it took.
#
# A FIXED warm-up pass has produced a wrong published result three separate
# times on this platform. The worst was campaign r5: 52 runs each recorded 45 s
# of warm-up while the hit ratio was still climbing at 2m30, and nine cells of
# the conclusion had to be retracted. The most recent was the ten-shape probe,
# where one 15 s pass made a plain primary-key lookup appear to reach only a
# 19.5% hit ratio and lose by 42%; with adequate warm-up the same cell reaches
# 100% and wins by 38%.
#
# In PgCache 0.7+, table-level subsumption increments pgcache_queries_cache_hit
# even while new queries' Materialized Views are still building via
# pgcache_cache_mv_fallthrough. We therefore measure effective MV/memo hit rate
# ((hits - mv_fallthrough) / (hits + misses)) so warm-up continues until both
# base-table population AND MV construction have settled within 1%.
warm_until_settled() {
  local host="$1" port="$2"; shift 2
  local prev=-1 cur h0 m0 f0 h1 m1 f1 p
  local max_passes="${MAX_WARM_PASSES:-6}"
  for p in $(seq 1 "$max_passes"); do
    read -r h0 m0 f0 <<<"$(scrape)"
    run "$host" "$port" "$DURATION" "$@" >/dev/null
    read -r h1 m1 f1 <<<"$(scrape)"
    cur=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) -v f=$((f1-f0)) 'BEGIN{eh=h-f; if(eh<0)eh=0; printf "%.4f", (h+m)?eh/(h+m):0}')
    if awk -v c="$cur" -v q="$prev" 'BEGIN{exit !(q >= 0 && c > 0.05 && c-q < 0.01 && c-q > -0.01)}'; then
      echo "$p"; return 0
    fi
    prev="$cur"
  done
  echo "$max_passes"
}

# ── Reset PgCache ──────────────────────────────────────────────────────────
#
# Cleanly recreates the pgcache container in Docker mode so that SysV shared
# memory segments (pgcache_pgrx DSA) and registered MVs from a prior suite are
# released before starting an independent scenario sweep.
reset_pgcache() {
  if [ "$BENCH_ENV" = "docker" ]; then
    docker compose -f "$REPO_ROOT/infra/docker-compose.yml" up -d --force-recreate pgcache >/dev/null 2>&1
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
  fi
}

# ── Ensure Workload Scripts ────────────────────────────────────────────────
ensure_workload_scripts() {
  if [ "$BENCH_ENV" = "k8s" ]; then
    if ! kubectl -n "$NS" exec deploy/loadgen -- test -f /tmp/mt/complex-dashboard.sql 2>/dev/null; then
      echo "--> Workload scripts missing in loadgen pod; restoring..." >&2
      kubectl -n "$NS" exec deploy/loadgen -- mkdir -p /tmp/mt 2>/dev/null || true
      for f in dashboard write complex-search complex-joins complex-analytics complex-dashboard; do
        if [ -f "$REPO_ROOT/workload/$f.sql" ]; then
          kubectl -n "$NS" exec -i deploy/loadgen -- bash -c "cat > /tmp/mt/$f.sql" < "$REPO_ROOT/workload/$f.sql" 2>/dev/null || true
        fi
      done
    fi
  fi
}

# ── One measured cell ──────────────────────────────────────────────────────
#
# Runs path A, then warms and runs path B, and prints a result row.
# The ONLY difference between the paths is host and port. Same pgbench binary,
# same script, same data, same node class, same zone.
cell() {
  ensure_workload_scripts
  local label="$1"; shift
  local a b h0 m0 f0 h1 m1 f1 warm

  a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")
  warm=$(warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' "$@")

  read -r h0 m0 f0 <<<"$(scrape)"
  b=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" "$@")
  read -r h1 m1 f1 <<<"$(scrape)"

  local a_lat a_rps b_lat b_rps
  read -r a_lat a_rps <<<"$a"
  read -r b_lat b_rps <<<"$b"

  printf '%-9s %9s %6s %10s %6s %7.1f%% %+7.0f%% %5s\n' \
    "$label" "${a_lat:-0.000}" "${a_rps:-0}" "${b_lat:-0.000}" "${b_rps:-0}" \
    "$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) 'BEGIN{print (h+m)?100*h/(h+m):0}')" \
    "$(awk -v x="${a_rps:-0}" -v y="${b_rps:-0}" 'BEGIN{print (x+0>0)?100*((y+0)/(x+0)-1):0}')" \
    "$warm"
}

header() {
  printf '%-9s %9s %6s %10s %6s %8s %8s %5s\n' \
    "$1" A_lat_ms A_rps B_lat_ms B_rps hit gain warm
}
