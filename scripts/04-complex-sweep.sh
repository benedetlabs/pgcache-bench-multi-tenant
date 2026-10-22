#!/usr/bin/env bash
# ============================================================================
# SWEEP 4 -- Complex Multi-Tenant Workload Scenarios
#
# Evaluates PgCache vs Origin when the workload moves beyond simple index
# lookups into expensive relational patterns:
#   1. complex-search.sql    : Multi-column ILIKE '%...%' text search + JOINs
#   2. complex-joins.sql     : Deep 4-to-6 table INNER JOIN & LEFT JOIN chains
#   3. complex-analytics.sql : Multi-dimensional GROUP BY, FILTER, CASE, HAVING
#   4. complex-dashboard.sql : Unified 8-statement enterprise analytics screen
#
# Modes (pass as $1, default: all):
#   scenarios : Compare all workload shapes at fixed tenants & concurrency
#   tenants   : Sweep active tenants (1..1000) on complex-dashboard.sql (uniform)
#   zipfian   : Sweep active tenants (100..2000) on complex-dashboard-zipfian.sql (Pareto 80/20)
#   clients   : Sweep client concurrency (1..32) on complex-dashboard.sql
#   writes    : Sweep mixed write ratios (0%, 5%, 10%) on complex-dashboard.sql
#   all       : Run scenarios, tenants, clients, and writes sequentially
# ============================================================================

set -uo pipefail
source "$(dirname "$0")/lib.sh"

MODE="${1:-all}"
TENANTS="${TENANTS:-200}"
TENANTS_LIST="${TENANTS_LIST:-1 10 50 200 500 1000}"
ZIPF_TENANTS_LIST="${ZIPF_TENANTS_LIST:-100 200 500 1000 2000}"
CLIENTS_LIST="${CLIENTS_LIST:-1 4 8 16 32}"
SPECS="${2:-${WRITE_SPECS:-0:$TENANTS 5:1 5:10 5:$TENANTS 10:1 10:$TENANTS}}"

run_scenarios() {
  header scenario
  [ "${TRIALS:-1}" -le 1 ] && reset_pgcache
  cell " dash_base" -f /tmp/mt/dashboard.sql                 -D tenants="$TENANTS"
  [ "${TRIALS:-1}" -le 1 ] && reset_pgcache
  cell "   search"  -f /tmp/mt/complex-search.sql            -D tenants="$TENANTS"
  [ "${TRIALS:-1}" -le 1 ] && reset_pgcache
  cell "    joins"  -f /tmp/mt/complex-joins.sql             -D tenants="$TENANTS"
  [ "${TRIALS:-1}" -le 1 ] && reset_pgcache
  cell "analytics"  -f /tmp/mt/complex-analytics.sql         -D tenants="$TENANTS"
  [ "${TRIALS:-1}" -le 1 ] && reset_pgcache
  cell "cplx_dash"  -f /tmp/mt/complex-dashboard.sql         -D tenants="$TENANTS"
  [ "${TRIALS:-1}" -le 1 ] && reset_pgcache
  cell "cplx_zipf"  -f /tmp/mt/complex-dashboard-zipfian.sql -D tenants="$TENANTS"
}

run_complex_tenants() {
  header c_tenants
  for T in $TENANTS_LIST; do
    if [ "$T" -le 50 ]; then
      reset_pgcache
    fi
    cell "$T" -f /tmp/mt/complex-dashboard.sql -D tenants="$T"
  done
}

run_complex_zipfian() {
  header z_tenants
  for T in $ZIPF_TENANTS_LIST; do
    reset_pgcache
    cell "$T" -f /tmp/mt/complex-dashboard-zipfian.sql -D tenants="$T"
  done
}

run_complex_clients() {
  reset_pgcache
  CLIENTS=8 warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' -f /tmp/mt/complex-dashboard.sql -D tenants="$TENANTS" >/dev/null
  header c_clients
  for C in $CLIENTS_LIST; do
    CLIENTS=$C cell "$C" -f /tmp/mt/complex-dashboard.sql -D tenants="$TENANTS"
  done
}

run_complex_writes() {
  if [ "${RESET_BEFORE_WRITES:-1}" = "1" ]; then
    reset_pgcache
    CLIENTS=8 warm_until_settled '$PGCACHE_HOST' '$PGCACHE_PORT' -f /tmp/mt/complex-dashboard.sql -D tenants="$TENANTS" >/dev/null
  fi
  header "c_wpct:wt"
  for spec in $SPECS; do
    W="${spec%%:*}"; WT="${spec##*:}"; R=$((100 - W))
    if [ "$W" = "0" ]; then
      cell "$spec" -f /tmp/mt/complex-dashboard.sql -D tenants="$TENANTS" -D wtenants="$WT"
    else
      MAX_WARM_PASSES="${MAX_WARM_PASSES:-3}" cell "$spec" -f /tmp/mt/complex-dashboard.sql@"$R" -f /tmp/mt/write.sql@"$W" \
                   -D tenants="$TENANTS" -D wtenants="$WT"
    fi
  done
}

case "$MODE" in
  scenarios) run_scenarios ;;
  tenants)   run_complex_tenants ;;
  zipfian)   run_complex_zipfian ;;
  clients)   run_complex_clients ;;
  writes)    run_complex_writes ;;
  all)
    run_scenarios
    echo ""
    run_complex_tenants
    echo ""
    run_complex_clients
    echo ""
    run_complex_writes
    ;;
  *)
    die "Unknown mode: $MODE (expected: scenarios|tenants|zipfian|clients|writes|all)"
    ;;
esac
