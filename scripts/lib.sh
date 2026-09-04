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

# Fail loudly rather than silently producing a table of zeroes.
die() { echo "FATAL: $*" >&2; exit 1; }

# Run a command inside the loadgen pod.
ex() { kubectl -n "$NS" exec deploy/loadgen -- bash -c "$1"; }

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

# Prints: <cumulative_hits> <cumulative_misses>
# Counters are cumulative since the PgCache process started, so callers take a
# DELTA around the measured window rather than reading them absolutely.
scrape() {
  local ip; ip="$(pgcache_ip)"
  [ -n "$ip" ] || die "could not resolve the pgcache pod IP"
  kubectl -n "$NS" exec deploy/metrics-reader -- \
    sh -c "wget -qO- --timeout=20 http://$ip:9090/metrics" 2>/dev/null \
  | awk '/^pgcache_queries_cache_hit /  {h=$2}
         /^pgcache_queries_cache_miss / {m=$2}
         END { print h+0, m+0 }'
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
  local out
  out=$(ex "pgbench -h $host -p $port -U \$PGUSER -n -c $CLIENTS -j $THREADS -T $secs $* \$PGDATABASE" 2>&1) \
    || die "pgbench failed: $(echo "$out" | tail -3)"
  echo "$out" | awk '/^latency average/{l=$4} /^tps/{printf "%s %.0f", l, $3}'
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
# The settling threshold is one percentage point between consecutive passes.
warm_until_settled() {
  local host="$1" port="$2"; shift 2
  local prev=0 cur h0 m0 h1 m1 p
  for p in 1 2 3 4 5; do
    read -r h0 m0 <<<"$(scrape)"
    run "$host" "$port" "$DURATION" "$@" >/dev/null
    read -r h1 m1 <<<"$(scrape)"
    cur=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) 'BEGIN{printf "%.4f", (h+m)?h/(h+m):0}')
    if awk -v c="$cur" -v q="$prev" 'BEGIN{exit !(c-q < 0.01 && c-q > -0.01)}'; then
      echo "$p"; return 0
    fi
    prev="$cur"
  done
  echo 5
}

# ── One measured cell ──────────────────────────────────────────────────────
#
# Runs path A, then warms and runs path B, and prints a result row.
# The ONLY difference between the paths is host and port. Same pgbench binary,
# same script, same data, same node class, same zone.
cell() {
  local label="$1"; shift
  local a b h0 m0 h1 m1 warm

  a=$(run '$ORIGIN_HOST' '$ORIGIN_PORT' "$DURATION" "$@")
  warm=$(warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' "$@")

  read -r h0 m0 <<<"$(scrape)"
  b=$(run '$PGCACHE_HOST' '$PGCACHE_PORT' "$DURATION" "$@")
  read -r h1 m1 <<<"$(scrape)"

  local a_lat a_rps b_lat b_rps
  read -r a_lat a_rps <<<"$a"
  read -r b_lat b_rps <<<"$b"

  printf '%-9s %9s %6s %10s %6s %7.1f%% %+7.0f%% %5s\n' \
    "$label" "$a_lat" "$a_rps" "$b_lat" "$b_rps" \
    "$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) 'BEGIN{print (h+m)?100*h/(h+m):0}')" \
    "$(awk -v x="$a_rps" -v y="$b_rps" 'BEGIN{print (x>0)?100*(y/x-1):0}')" \
    "$warm"
}

header() {
  printf '%-9s %9s %6s %10s %6s %8s %8s %5s\n' \
    "$1" A_lat_ms A_rps B_lat_ms B_rps hit gain warm
}
