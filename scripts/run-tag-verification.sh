#!/usr/bin/env bash
# ============================================================================
# Run benchmark verification for a specific PgCache image tag.
#
# Policy:
#   - Official performance benchmark results are collected EXCLUSIVELY on the
#     3-node Kubernetes cluster (`BENCH_ENV=k8s`, default `DURATION=30`,
#     `TRIALS=3` or `5`) with full pod recreation (`reset_all_pods`) between
#     trials to capture positive/negative deviation trends (`-Δ/+Δ`, `stddev`).
#   - Local Docker (`--smoke-docker` or `DOCKER=1`) is used ONLY to assemble
#     the environment and run the functional/correctness gate (`00-setup.sh` +
#     `verify-correctness.sh`), never to publish benchmark numbers.
#
# Usage:
#   # Official 3-node Kubernetes multi-trial benchmark (default: 5 trials):
#   ./scripts/run-tag-verification.sh <tag> [duration_seconds=30] [trials=5]
#
#   # Local Docker functional & correctness smoke test only (no results saved):
#   ./scripts/run-tag-verification.sh --smoke-docker <tag>
# ============================================================================

set -euo pipefail

SMOKE_DOCKER=0
if [ "${1:-}" = "--smoke-docker" ]; then
  SMOKE_DOCKER=1
  shift
fi

if [ "${DOCKER:-0}" = "1" ] || [ "${BENCH_ENV:-}" = "docker" ]; then
  SMOKE_DOCKER=1
fi

RAW_TAG="${1:-0.7.1}"
BASE_TAG="${RAW_TAG%-arm64}"
DURATION="${2:-30}"
TRIALS="${3:-${TRIALS:-5}}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

if [ "$SMOKE_DOCKER" -eq 1 ]; then
  BENCH_ENV="docker"
  SCALE="${SCALE:-1}"
  TENANTS="${TENANTS:-200}"
  export BENCH_ENV SCALE TENANTS

  ARCH="$(uname -m)"
  if [ "$ARCH" = "arm64" ]; then
    IMAGE_TAG="${BASE_TAG}-arm64"
  else
    IMAGE_TAG="${BASE_TAG}"
  fi
  PGCACHE_IMAGE="pgcache/pgcache:${IMAGE_TAG}"
  export PGCACHE_IMAGE

  echo "========================================================================"
  echo " Local Docker Environment Setup & Correctness Smoke Test"
  echo " Image: $PGCACHE_IMAGE"
  echo " Policy: Docker is used strictly for setup & correctness validation."
  echo "         Official performance numbers are collected only on 3-node K8s."
  echo "========================================================================"

  PGCACHE_IMAGE="$PGCACHE_IMAGE" docker compose -f "$REPO_ROOT/infra/docker-compose.yml" up -d
  PGCACHE_IMAGE="$PGCACHE_IMAGE" docker compose -f "$REPO_ROOT/infra/docker-compose.yml" restart pgcache

  READY=0
  for i in {1..30}; do
    if curl -sf http://127.0.0.1:59090/metrics >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done
  if [ "$READY" -ne 1 ]; then
    echo "FATAL: PgCache metrics endpoint not reachable after 30 seconds." >&2
    exit 1
  fi

  "$HERE/00-setup.sh"
  "$HERE/verify-correctness.sh"

  echo "========================================================================"
  echo " [PASS] Local Docker environment and Post-CDC correctness gate verified!"
  echo " (No performance results written; use 3-node K8s for benchmark runs.)"
  echo "========================================================================"
  exit 0
fi

# ── Official 3-Node Kubernetes Multi-Trial Benchmark Campaign ──────────────
BENCH_ENV="k8s"
SCALE="${SCALE:-1}"
TENANTS="${TENANTS:-2000}"
TENANTS_LIST="${TENANTS_LIST:-1 10 50 100 500 1000 2000}"
RUN_COMPLEX="${RUN_COMPLEX:-1}"
RECREATE_PODS_MODE="${RECREATE_PODS_MODE:-all}"
export BENCH_ENV DURATION TRIALS SCALE TENANTS TENANTS_LIST RUN_COMPLEX RECREATE_PODS_MODE

OUT_DIR="$REPO_ROOT/results/$BASE_TAG"
mkdir -p "$OUT_DIR"

echo "========================================================================"
echo " Starting Official 3-Node K8s Multi-Trial Benchmark for Tag: $BASE_TAG"
echo " Duration per cell: ${DURATION}s | Trials per cell: ${TRIALS} (Pod Recreation: ${RECREATE_PODS_MODE})"
echo " Output directory:  $OUT_DIR"
echo "========================================================================"

# 1. Verify 3-node placement and seed database
"$HERE/00-setup.sh"

# 2. Recreate all pods cleanly before starting correctness gate
source "$HERE/lib.sh"
reset_all_pods

# 3. Run Differential Correctness, Cacheability, MV Admission & Post-CDC Gate
echo "--> Running Differential Correctness, Cacheability & Post-CDC Gate..."
"$HERE/verify-correctness.sh" | tee "$OUT_DIR/verify-correctness-doks.txt"
cp "$OUT_DIR/verify-correctness-doks.txt" "$OUT_DIR/verify-correctness.txt"

# 4. Sweep 1: Tenant count sweep
echo "--> Running Sweep 1: Tenant Count Sweep ($TENANTS_LIST) [TRIALS=$TRIALS]..."
"$HERE/01-tenant-sweep.sh" | tee "$OUT_DIR/run-tenants-doks.txt"
cp "$OUT_DIR/run-tenants-doks.txt" "$OUT_DIR/run-tenants.txt"

# 5. Sweep 2: Concurrency sweep
echo "--> Running Sweep 2: Concurrency Sweep (1, 4, 8, 16, 32) [TRIALS=$TRIALS]..."
TENANTS=200 "$HERE/02-concurrency-sweep.sh" | tee "$OUT_DIR/run-clients-doks.txt"
cp "$OUT_DIR/run-clients-doks.txt" "$OUT_DIR/run-clients.txt"

# 6. Sweep 3: Write ratio sweep
echo "--> Running Sweep 3: Write Ratio Sweep [TRIALS=$TRIALS]..."
TENANTS=200 "$HERE/03-write-sweep.sh" | tee "$OUT_DIR/run-writes-doks.txt"
cp "$OUT_DIR/run-writes-doks.txt" "$OUT_DIR/run-writes.txt"

# 7. Generate results-doks.tsv & results.tsv
echo "--> Generating $OUT_DIR/results-doks.tsv..."
TSV="$OUT_DIR/results-doks.tsv"
printf "sweep\tparam\tclients\tA_lat_ms\tA_rps\tB_lat_ms\tB_rps\thit_ratio\tgain_pct\twarm_passes\n" > "$TSV"

parse_sweep_to_tsv() {
  local sweep_name="$1" file="$2" fixed_clients="$3"
  tail -n +2 "$file" | while IFS='|' read -r main_cols dev_cols; do
    read -r p a_lat a_rps b_lat b_rps hit gain warm <<<"$main_cols"
    [ -n "${p:-}" ] || continue
    local c_val="$fixed_clients"
    [ "$sweep_name" = "clients" ] && c_val="$p"
    local param="$p"
    if [ "$sweep_name" = "writes" ] || [ "$sweep_name" = "complex_writes" ]; then
      local w_pct="${p%%:*}"
      local w_t="${p##*:}"
      param="${w_pct}pct_wt${w_t}"
    fi
    local hit_num; hit_num=$(echo "$hit" | tr -d '%')
    local gain_num; gain_num=$(echo "$gain" | tr -d '%+')
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
      "$sweep_name" "$param" "$c_val" "$a_lat" "$a_rps" "$b_lat" "$b_rps" \
      "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$4"
  done
}

parse_sweep_to_tsv "tenants" "$OUT_DIR/run-tenants-doks.txt" "8" "$TSV"
parse_sweep_to_tsv "clients" "$OUT_DIR/run-clients-doks.txt" "8" "$TSV"
parse_sweep_to_tsv "writes"  "$OUT_DIR/run-writes-doks.txt"  "8" "$TSV"
cp "$TSV" "$OUT_DIR/results.tsv"

# 8. Complex Multi-Tenant Workload Sweeps
if [ "$RUN_COMPLEX" = "1" ]; then
  echo "--> Running Sweep 4A: Complex Scenario Family Comparison [TRIALS=$TRIALS]..."
  TENANTS=200 "$HERE/04-complex-sweep.sh" scenarios | tee "$OUT_DIR/run-complex-scenarios-doks.txt"

  echo "--> Running Sweep 4B: Complex Dashboard Tenant Scaling [TRIALS=$TRIALS]..."
  TENANTS_LIST="1 10 50 200 500 1000" "$HERE/04-complex-sweep.sh" tenants | tee "$OUT_DIR/run-complex-tenants-doks.txt"

  echo "--> Running Sweep 4C: Complex Dashboard Concurrency Scaling (1, 4, 8, 16, 32) [TRIALS=$TRIALS]..."
  TENANTS=200 "$HERE/04-complex-sweep.sh" clients | tee "$OUT_DIR/run-complex-clients-doks.txt"

  echo "--> Running Sweep 4D: Complex Dashboard Mixed Write Resilience [TRIALS=$TRIALS]..."
  TENANTS=200 "$HERE/04-complex-sweep.sh" writes | tee "$OUT_DIR/run-complex-writes-doks.txt"

  CTSV="$OUT_DIR/results-complex-doks.tsv"
  printf "sweep\tparam\tclients\tA_lat_ms\tA_rps\tB_lat_ms\tB_rps\thit_ratio\tgain_pct\twarm_passes\n" > "$CTSV"
  parse_sweep_to_tsv "complex_scenarios" "$OUT_DIR/run-complex-scenarios-doks.txt" "8" "$CTSV"
  parse_sweep_to_tsv "complex_tenants"   "$OUT_DIR/run-complex-tenants-doks.txt"   "8" "$CTSV"
  parse_sweep_to_tsv "complex_clients"   "$OUT_DIR/run-complex-clients-doks.txt"   "8" "$CTSV"
  parse_sweep_to_tsv "complex_writes"    "$OUT_DIR/run-complex-writes-doks.txt"    "8" "$CTSV"
  cp "$CTSV" "$OUT_DIR/results-complex.tsv"
fi

echo "========================================================================"
echo " Finished 3-Node K8s Multi-Trial Run ($TRIALS trials) for $BASE_TAG!"
echo " Official results stored in $OUT_DIR"
echo "========================================================================"
