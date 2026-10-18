#!/usr/bin/env bash
# ============================================================================
# Run benchmark verification for a specific pgcache image tag in Docker.
#
# Usage:
#   ./scripts/run-tag-verification.sh <tag> [duration_seconds]
#
# Examples:
#   ./scripts/run-tag-verification.sh 0.6.3 5
#   ./scripts/run-tag-verification.sh 0.6.4 5
#   ./scripts/run-tag-verification.sh 0.7.0 5
#   ./scripts/run-tag-verification.sh 0.7.1 5
# ============================================================================

set -euo pipefail

RAW_TAG="${1:-0.7.1}"
BASE_TAG="${RAW_TAG%-arm64}"
DURATION="${2:-5}"
BENCH_ENV="docker"
SCALE="${SCALE:-1}"
TENANTS="${TENANTS:-1000}"
TENANTS_LIST="${TENANTS_LIST:-1 10 50 200 500 1000}"
RUN_COMPLEX="${RUN_COMPLEX:-1}"
export BENCH_ENV DURATION SCALE TENANTS TENANTS_LIST RUN_COMPLEX

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  IMAGE_TAG="${BASE_TAG}-arm64"
else
  IMAGE_TAG="${BASE_TAG}"
fi
PGCACHE_IMAGE="pgcache/pgcache:${IMAGE_TAG}"
export PGCACHE_IMAGE

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
OUT_DIR="$REPO_ROOT/results/$BASE_TAG"
mkdir -p "$OUT_DIR"

echo "========================================================================"
echo " Starting PgCache Verification Run for Tag: $BASE_TAG (Image: $PGCACHE_IMAGE)"
echo " Duration per cell: ${DURATION}s"
echo " Output directory: $OUT_DIR"
echo "========================================================================"

# 1. Bring up Docker Compose with the specified image
echo "--> Starting docker compose environment..."
PGCACHE_IMAGE="$PGCACHE_IMAGE" docker compose -f "$REPO_ROOT/infra/docker-compose.yml" up -d
PGCACHE_IMAGE="$PGCACHE_IMAGE" docker compose -f "$REPO_ROOT/infra/docker-compose.yml" restart pgcache

# Wait for pgcache to be ready
echo "--> Waiting for PgCache and Origin to be healthy..."
READY=0
for i in {1..30}; do
  if curl -sf http://127.0.0.1:59090/metrics >/dev/null 2>&1; then
    echo "    PgCache metrics endpoint reachable."
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  echo "FATAL: PgCache metrics endpoint not reachable after 30 seconds." >&2
  exit 1
fi

# Ensure database is set up
echo "--> Ensuring database schema and seeds are loaded..."
"$HERE/00-setup.sh"

# Run Differential Correctness & Cacheability Gate
echo "--> Running Differential Correctness & Cacheability Gate..."
"$HERE/verify-correctness.sh" | tee "$OUT_DIR/verify-correctness.txt"
cp "$OUT_DIR/verify-correctness.txt" "$OUT_DIR/verify-correctness-docker.txt"

# Source library functions
source "$HERE/lib.sh"

# 2. Standalone Baseline
echo "--> Running standalone baseline (1 client directly against origin)..."
BASE_OUT=$(ex "pgbench -h \$ORIGIN_HOST -p \$ORIGIN_PORT -U \$PGUSER -n -c 1 -j 1 -T $DURATION -f /tmp/mt/dashboard.sql -D tenants=1 \$PGDATABASE" 2>&1)
BASE_LAT=$(echo "$BASE_OUT" | awk '/^latency average/{print $4}')
BASE_RPS=$(echo "$BASE_OUT" | awk '/^tps/{printf "%.0f", $3}')

# 3. Sweep 1: Tenant count sweep
echo "--> Running Sweep 1: Tenant Count Sweep ($TENANTS_LIST)..."
"$HERE/01-tenant-sweep.sh" | tee "$OUT_DIR/run-tenants-docker.txt"
if [ ! -f "$OUT_DIR/run-tenants-doks.txt" ]; then
  cp "$OUT_DIR/run-tenants-docker.txt" "$OUT_DIR/run-tenants.txt"
fi

# 4. Sweep 2: Concurrency sweep
echo "--> Running Sweep 2: Concurrency Sweep (1, 4, 8, 16, 32)..."
"$HERE/02-concurrency-sweep.sh" | tee "$OUT_DIR/run-clients.txt"

# 5. Sweep 3: Write ratio sweep
echo "--> Running Sweep 3: Write Ratio Sweep..."
"$HERE/03-write-sweep.sh" | tee "$OUT_DIR/run-writes.txt"

# 6. Generate results-docker.tsv (and results.tsv if no DOKS primary exists)
echo "--> Generating $OUT_DIR/results-docker.tsv..."
TSV="$OUT_DIR/results-docker.tsv"
printf "sweep\tparam\tclients\tA_lat_ms\tA_rps\tB_lat_ms\tB_rps\thit_ratio\tgain_pct\twarm_passes\n" > "$TSV"
printf "baseline\tstandalone_1client\t1\t%s\t%s\t-\t-\t-\t-\t-\n" "$BASE_LAT" "$BASE_RPS" >> "$TSV"

# Parse Sweep 1 (tenants)
tail -n +2 "$OUT_DIR/run-tenants-docker.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
  [ -n "$p" ] || continue
  hit_num=$(echo "$hit" | tr -d '%')
  gain_num=$(echo "$gain" | tr -d '%+')
  printf "tenants\t%s\t8\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
    "$p" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$TSV"
done

# Parse Sweep 2 (clients)
tail -n +2 "$OUT_DIR/run-clients.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
  [ -n "$p" ] || continue
  hit_num=$(echo "$hit" | tr -d '%')
  gain_num=$(echo "$gain" | tr -d '%+')
  printf "clients\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
    "$p" "$p" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$TSV"
done

# Parse Sweep 3 (writes)
tail -n +2 "$OUT_DIR/run-writes.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
  [ -n "$p" ] || continue
  hit_num=$(echo "$hit" | tr -d '%')
  gain_num=$(echo "$gain" | tr -d '%+')
  w_pct="${p%%:*}"
  w_t="${p##*:}"
  param="${w_pct}pct_wt${w_t}"
  printf "writes\t%s\t8\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
    "$param" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$TSV"
done

if [ ! -f "$OUT_DIR/results-doks.tsv" ]; then
  cp "$TSV" "$OUT_DIR/results.tsv"
fi

# 7. Complex Multi-Tenant Workload Sweeps
if [ "$RUN_COMPLEX" = "1" ]; then
  echo "--> Running Sweep 4A: Complex Scenario Family Comparison..."
  TENANTS=200 "$HERE/04-complex-sweep.sh" scenarios | tee "$OUT_DIR/run-complex-scenarios.txt"

  echo "--> Running Sweep 4B: Complex Dashboard Tenant Scaling ($TENANTS_LIST)..."
  "$HERE/04-complex-sweep.sh" tenants | tee "$OUT_DIR/run-complex-tenants.txt"

  echo "--> Running Sweep 4C: Complex Dashboard Concurrency Scaling (1, 4, 8, 16, 32)..."
  TENANTS=200 "$HERE/04-complex-sweep.sh" clients | tee "$OUT_DIR/run-complex-clients.txt"

  echo "--> Running Sweep 4D: Complex Dashboard Mixed Write Resilience..."
  TENANTS=200 "$HERE/04-complex-sweep.sh" writes | tee "$OUT_DIR/run-complex-writes.txt"

  CTSV="$OUT_DIR/results-complex.tsv"
  printf "sweep\tparam\tclients\tA_lat_ms\tA_rps\tB_lat_ms\tB_rps\thit_ratio\tgain_pct\twarm_passes\n" > "$CTSV"

  tail -n +2 "$OUT_DIR/run-complex-scenarios.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
    [ -n "$p" ] || continue
    hit_num=$(echo "$hit" | tr -d '%')
    gain_num=$(echo "$gain" | tr -d '%+')
    printf "complex_scenarios\t%s\t8\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
      "$p" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$CTSV"
  done

  tail -n +2 "$OUT_DIR/run-complex-tenants.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
    [ -n "$p" ] || continue
    hit_num=$(echo "$hit" | tr -d '%')
    gain_num=$(echo "$gain" | tr -d '%+')
    printf "complex_tenants\t%s\t8\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
      "$p" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$CTSV"
  done

  tail -n +2 "$OUT_DIR/run-complex-clients.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
    [ -n "$p" ] || continue
    hit_num=$(echo "$hit" | tr -d '%')
    gain_num=$(echo "$gain" | tr -d '%+')
    printf "complex_clients\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
      "$p" "$p" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$CTSV"
  done

  tail -n +2 "$OUT_DIR/run-complex-writes.txt" | while read -r p a_lat a_rps b_lat b_rps hit gain warm; do
    [ -n "$p" ] || continue
    hit_num=$(echo "$hit" | tr -d '%')
    gain_num=$(echo "$gain" | tr -d '%+')
    w_pct="${p%%:*}"
    w_t="${p##*:}"
    param="${w_pct}pct_wt${w_t}"
    printf "complex_writes\t%s\t8\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n" \
      "$param" "$a_lat" "$a_rps" "$b_lat" "$b_rps" "$(awk -v h="$hit_num" 'BEGIN{print h/100}')" "$gain_num" "$warm" >> "$CTSV"
  done
  cp "$CTSV" "$OUT_DIR/results-complex-docker.tsv"
fi

echo "========================================================================"
echo " Finished run for $BASE_TAG! Results stored in $OUT_DIR"
echo "========================================================================"
