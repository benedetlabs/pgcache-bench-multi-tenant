#!/usr/bin/env bash
# ============================================================================
# DigitalOcean DOKS Tuned Benchmark Sweep Runner
# Deploys specified pgcache tag with tuned profile (network stack tuning,
# 8 workers, raw integer memo cache size, direct node IP routing)
# and executes tenant sweep across 1, 10, 50, 100, 500, 1000, 2000 tenants.
#
# Preserves all existing baseline results without overwriting them.
# ============================================================================
set -euo pipefail

TAG="${1:-0.7.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

echo "========================================================================"
echo " Starting Tuned Benchmark Sweep on DigitalOcean DOKS"
echo " PgCache Tag: $TAG"
echo " Tenants:     1 10 50 100 500 1000 2000"
echo " Profile:     Tuned (Network stack + 8 Workers + 1GiB Memo Cache + Direct IP)"
echo "========================================================================"

# 1. Deploy the tag with tuned profile
"$REPO_ROOT/scripts/helm-deploy.sh" --do-tuned "$TAG"

# 2. Wait for pods rollout
echo "--> Waiting for rollout..."
kubectl -n pgcache-mt rollout status statefulset/origin --timeout=5m
kubectl -n pgcache-mt rollout status deploy/pgcache --timeout=5m
kubectl -n pgcache-mt rollout status deploy/loadgen --timeout=5m
kubectl -n pgcache-mt rollout status deploy/metrics-reader --timeout=5m

# 3. Apply direct node IP routing and verify network tuning
"$REPO_ROOT/scripts/tune-network.sh"

# 4. Verify pod placement across 3 distinct nodes
echo "--> Pod distribution:"
kubectl -n pgcache-mt get pods -o wide

# 5. Database Setup / Seeding (Scale 1 by default, or existing DB)
echo "--> Running setup check..."
export TENANTS="${TENANTS:-2000}"
"$REPO_ROOT/scripts/00-setup.sh"

# 6. Re-apply / verify direct node routing after any setup
"$REPO_ROOT/scripts/tune-network.sh"

# 7. Create results directory for tuned sweep
OUT_DIR="$REPO_ROOT/results/$TAG"
mkdir -p "$OUT_DIR"
TUNED_DIR="$REPO_ROOT/results/tuned"
mkdir -p "$TUNED_DIR"

# 8. Run tenant sweep
export TENANTS_LIST="1 10 50 100 500 1000 2000"
echo "--> Executing tenant sweep with warm_until_settled dynamic warmup..."
"$REPO_ROOT/scripts/01-tenant-sweep.sh" | tee "$OUT_DIR/run-tenants-tuned.txt"

# Copy raw log to dedicated results/tuned directory
cp "$OUT_DIR/run-tenants-tuned.txt" "$TUNED_DIR/run-tenants.txt"

# Generate TSV files
awk 'NR==1 { print "sweep\tparam\tclients\tA_lat_ms\tA_rps\tB_lat_ms\tB_rps\thit_ratio\tgain_pct\twarm_passes"; next }
     NF>=8 {
       hit = $6; sub(/%/, "", hit); hit_ratio = sprintf("%.3f", hit / 100);
       gain = $7; sub(/%/, "", gain); sub(/^\+/, "", gain);
       print "tenants\t" $1 "\t8\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" hit_ratio "\t" gain "\t" $8
     }' "$OUT_DIR/run-tenants-tuned.txt" > "$OUT_DIR/results-tuned.tsv"
cp "$OUT_DIR/results-tuned.tsv" "$TUNED_DIR/results.tsv"

echo "========================================================================"
echo " Completed tuned tenant sweep for PgCache $TAG"
echo " Results written to:"
echo "   - results/$TAG/run-tenants-tuned.txt"
echo "   - results/$TAG/results-tuned.tsv"
echo "   - results/tuned/run-tenants.txt"
echo "   - results/tuned/results.tsv"
echo "========================================================================"
