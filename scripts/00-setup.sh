#!/usr/bin/env bash
# Creates and seeds the schema. Run once, before any sweep. Takes ~1 minute on Scale 1.
#
#   ./00-setup.sh
#
# Configurable variables:
#   SCALE=1       (1 -> 500k orders, ~463 MB; 5 -> 2.5M orders, ~2.3 GB; 10 -> 5M orders, ~4.6 GB)
#   TENANTS=200   (Number of distinct tenants to distribute data across, default: 200)
#   FORCE=1       (Force re-seeding even if tables and row counts already exist)
#   RESEED=1      (Alias for FORCE=1)
#
# Copies the SQL into the loadgen pod and applies it against the ORIGIN.
# Everything is written through the origin, never through PgCache: seeding via
# the cache would be measuring the cache's write path, which is not the subject.
set -euo pipefail
NS="${NS:-pgcache-mt}"
BENCH_ENV="${BENCH_ENV:-${TARGET_ENV:-}}"
if [ -z "$BENCH_ENV" ]; then
  if [ "${DOCKER:-0}" = "1" ] || [ "${USE_DOCKER:-0}" = "1" ]; then
    BENCH_ENV="docker"
  else
    BENCH_ENV="k8s"
  fi
fi

SCALE="${SCALE:-1}"
TENANTS="${TENANTS:-200}"
FORCE="${FORCE:-${RESEED:-0}}"
EXPECTED_ORDERS=$((500000 * SCALE))

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

echo "=== Setup Configuration ==="
echo "Environment:     $BENCH_ENV"
echo "Scale Factor:    $SCALE (Target orders: $EXPECTED_ORDERS)"
echo "Tenants:         $TENANTS"
echo "Force Reseed:    $FORCE"

if [ "$BENCH_ENV" = "docker" ]; then
  CURRENT_ORDERS=$(docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
    psql -h origin -U bench -d bench -tAc \
    "SELECT count(*) FROM orders;" 2>/dev/null || echo "0")
  CURRENT_ORDERS="${CURRENT_ORDERS//[[:space:]]/}"
  [ -z "$CURRENT_ORDERS" ] && CURRENT_ORDERS=0

  CURRENT_TENANTS=$(docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
    psql -h origin -U bench -d bench -tAc \
    "SELECT count(DISTINCT tenant_id) FROM orders;" 2>/dev/null || echo "0")
  CURRENT_TENANTS="${CURRENT_TENANTS//[[:space:]]/}"
  [ -z "$CURRENT_TENANTS" ] && CURRENT_TENANTS=0

  if [ "$FORCE" != "1" ] && [ "$CURRENT_ORDERS" -eq "$EXPECTED_ORDERS" ] && [ "$CURRENT_TENANTS" -eq "$TENANTS" ] && [ "$CURRENT_ORDERS" -gt 0 ]; then
    echo "--- Database already seeded with SCALE=$SCALE ($CURRENT_ORDERS orders, $CURRENT_TENANTS tenants) ---"
  else
    echo "--- Seeding database (Current: $CURRENT_ORDERS orders / $CURRENT_TENANTS tenants, Target: $EXPECTED_ORDERS orders / $TENANTS tenants) ---"
    for f in 01-schema 02-tenant; do
      echo "--- applying $f.sql (scale=$SCALE, tenants=$TENANTS) ---"
      docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
        bash -c "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -v scale=$SCALE -v tenants=$TENANTS -q -f /sql/$f.sql"
    done
  fi

  echo "--- sizes ---"
  docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client bash -c \
    "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \"
       select rpad(relname,12) || lpad(n_live_tup::text, 9) || '  ' ||
              pg_size_pretty(pg_total_relation_size(relid))
         from pg_stat_user_tables where relname not like 'pgbench%'
        order by n_live_tup desc\""
  docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client bash -c \
    "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \"
       select 'TOTAL ' || pg_size_pretty(pg_database_size(current_database()))\""
else
  CURRENT_ORDERS=$(kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; \
    psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \
    \"SELECT count(*) FROM orders;\"" 2>/dev/null || echo "0")
  CURRENT_ORDERS="${CURRENT_ORDERS//[[:space:]]/}"
  [ -z "$CURRENT_ORDERS" ] && CURRENT_ORDERS=0

  CURRENT_TENANTS=$(kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; \
    psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \
    \"SELECT count(DISTINCT tenant_id) FROM orders;\"" 2>/dev/null || echo "0")
  CURRENT_TENANTS="${CURRENT_TENANTS//[[:space:]]/}"
  [ -z "$CURRENT_TENANTS" ] && CURRENT_TENANTS=0

  if [ "$FORCE" != "1" ] && [ "$CURRENT_ORDERS" -eq "$EXPECTED_ORDERS" ] && [ "$CURRENT_TENANTS" -eq "$TENANTS" ] && [ "$CURRENT_ORDERS" -gt 0 ]; then
    echo "--- Database already seeded with SCALE=$SCALE ($CURRENT_ORDERS orders, $CURRENT_TENANTS tenants) ---"
  else
    echo "--- Seeding database in Kubernetes (Current: $CURRENT_ORDERS orders / $CURRENT_TENANTS tenants, Target: $EXPECTED_ORDERS orders / $TENANTS tenants) ---"
    for f in 01-schema 02-tenant; do
      echo "--- applying $f.sql (scale=$SCALE, tenants=$TENANTS) ---"
      kubectl -n "$NS" exec -i deploy/loadgen -- bash -c "cat > /tmp/$f.sql" < "$HERE/../sql/$f.sql"
      kubectl -n "$NS" exec deploy/loadgen -- \
        bash -c "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; \
        psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -v scale=$SCALE -v tenants=$TENANTS -q -f /tmp/$f.sql"
    done
  fi

  echo "--- copying workload scripts ---"
  kubectl -n "$NS" exec deploy/loadgen -- bash -c 'mkdir -p /tmp/mt'
  for f in dashboard write complex-search complex-joins complex-analytics complex-dashboard; do
    if [ -f "$HERE/../workload/$f.sql" ]; then
      kubectl -n "$NS" exec -i deploy/loadgen -- bash -c "cat > /tmp/mt/$f.sql" < "$HERE/../workload/$f.sql"
    fi
  done

  echo "--- sizes ---"
  kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; \
     psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \"
       select rpad(relname,12) || lpad(n_live_tup::text, 9) || '  ' ||
              pg_size_pretty(pg_total_relation_size(relid))
         from pg_stat_user_tables where relname not like 'pgbench%'
        order by n_live_tup desc\""
  kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "[ -f /etc/profile.d/benchmark-hosts.sh ] && . /etc/profile.d/benchmark-hosts.sh; \
     psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \"
       select 'TOTAL ' || pg_size_pretty(pg_database_size(current_database()))\""
fi
