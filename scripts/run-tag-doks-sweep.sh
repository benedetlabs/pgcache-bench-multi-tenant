#!/usr/bin/env bash
# ============================================================================
# DigitalOcean DOKS Tenant Benchmark Sweep Runner
# Deploys specified pgcache tag to DOKS cluster and executes the tenant sweep
# across 1, 10, 50, 100, 500, 1000, 2000 tenants.
# ============================================================================
set -euo pipefail

TAG="${1:-}"
if [ -z "$TAG" ]; then
  echo "Usage: $0 <pgcache_tag>"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

echo "========================================================================"
echo " Starting Tenant Benchmark Sweep on DigitalOcean DOKS"
echo " PgCache Tag: $TAG"
echo " Tenants:     1 10 50 100 500 1000 2000"
echo "========================================================================"

# 1. Deploy the tag with budget profile
"$REPO_ROOT/scripts/do-cluster.sh" deploy "$TAG"

# 2. Wait for rollout
echo "--> Waiting for pgcache rollout..."
kubectl -n pgcache-mt rollout status deploy/pgcache --timeout=5m
echo "--> Cluster pods placement:"
kubectl -n pgcache-mt get pods -o wide

# 3. Create results directory
mkdir -p "$REPO_ROOT/results/$TAG"

# 4. Run tenant sweep
export TENANTS_LIST="1 10 50 100 500 1000 2000"
"$REPO_ROOT/scripts/01-tenant-sweep.sh" | tee "$REPO_ROOT/results/$TAG/run-tenants.txt"

echo "========================================================================"
echo " Completed tenant sweep for PgCache $TAG"
echo " Results written to: results/$TAG/run-tenants.txt"
echo "========================================================================"
