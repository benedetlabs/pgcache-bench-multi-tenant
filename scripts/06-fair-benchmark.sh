#!/usr/bin/env bash
# ============================================================================
# SWEEP 6 -- Fair Benchmark ("Teste Justo"): Tuned PostgreSQL Origin +
#            GIN pg_trgm Indexes + Dynamic Intra-Tenant Filter Variations
# ============================================================================

set -uo pipefail
export PREWARM_ORIGIN=1
export RECREATE_PODS_MODE="pgcache"
source "$(dirname "$0")/lib.sh"

TENANTS="${TENANTS:-200}"
TAG="${TAG:-0.7.1}"

echo "========================================================================"
echo " Applying Fair-Tuning Profile to PostgreSQL Origin (2 GiB RAM + GIN)"
echo "========================================================================"

if [ "$BENCH_ENV" = "k8s" ]; then
  kubectl -n "$NS" rollout status statefulset/origin --timeout=5m
  kubectl -n "$NS" rollout status deploy/loadgen --timeout=3m
  "$REPO_ROOT/scripts/tune-network.sh" >/dev/null 2>&1 || true
  kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m

  echo "--> Applying GIN pg_trgm indexes and prewarming Origin (sql/03-fair-tuning.sql)..."
  kubectl -n "$NS" exec -i -c bench deploy/loadgen -- bash -c "cat > /tmp/03-fair-tuning.sql" < "$REPO_ROOT/sql/03-fair-tuning.sql"
  ex "psql -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -d \$PGDATABASE -q -f /tmp/03-fair-tuning.sql"
else
  docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
    bash -c "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -q -f /sql/03-fair-tuning.sql"
fi

WORKLOAD_SCRIPTS_READY=0
ensure_workload_scripts

echo ""
echo "========================================================================"
echo " Running 5-Trial Fair Benchmark (TRIALS=$TRIALS, TENANTS=$TENANTS)"
echo "========================================================================"
header fair_scen
cell "search_1c" -f /tmp/mt/complex-search.sql            -D tenants="$TENANTS"
cell "search_3c" -f /tmp/mt/complex-search-fair.sql       -D tenants="$TENANTS"
cell "cplx_dash" -f /tmp/mt/complex-dashboard.sql         -D tenants="$TENANTS"
cell " cplx_dyn" -f /tmp/mt/complex-dashboard-dynamic.sql -D tenants="$TENANTS"
