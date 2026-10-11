#!/usr/bin/env bash
# Creates and seeds the schema. Run once, before any sweep. Takes ~1 minute.
#
#   ./00-setup.sh
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
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

if [ "$BENCH_ENV" = "docker" ]; then
  echo "=== Running setup in Docker Compose environment ==="
  TABLE_COUNT=$(docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
    psql -h origin -U bench -d bench -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('orders','order_item','customer','product');" 2>/dev/null || echo "0")
  if [ "$TABLE_COUNT" = "4" ]; then
    echo "--- Database already seeded (core tables present) ---"
  else
    for f in 01-schema 02-tenant; do
      echo "--- applying $f.sql ---"
      docker compose -f "$REPO_ROOT/infra/docker-compose.yml" exec -T client \
        bash -c "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -q -f /sql/$f.sql"
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
  echo "=== Running setup in Kubernetes environment ($NS) ==="
  TABLE_COUNT=$(kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \
    \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('orders','order_item','customer','product');\"" 2>/dev/null || echo "0")
  if [ "$TABLE_COUNT" = "4" ]; then
    echo "--- Database already seeded (core tables present) ---"
  else
    for f in 01-schema 02-tenant; do
      echo "--- applying $f.sql ---"
      kubectl -n "$NS" exec -i deploy/loadgen -- bash -c "cat > /tmp/$f.sql" < "$HERE/../sql/$f.sql"
      kubectl -n "$NS" exec deploy/loadgen -- \
        bash -c "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -q -f /tmp/$f.sql"
    done
  fi

  echo "--- copying workload scripts ---"
  kubectl -n "$NS" exec deploy/loadgen -- bash -c 'mkdir -p /tmp/mt'
  for f in dashboard write; do
    kubectl -n "$NS" exec -i deploy/loadgen -- bash -c "cat > /tmp/mt/$f.sql" < "$HERE/../workload/$f.sql"
  done

  echo "--- sizes ---"
  kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \"
       select rpad(relname,12) || lpad(n_live_tup::text, 9) || '  ' ||
              pg_size_pretty(pg_total_relation_size(relid))
         from pg_stat_user_tables where relname not like 'pgbench%'
        order by n_live_tup desc\""
  kubectl -n "$NS" exec deploy/loadgen -- bash -c \
    "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -tAc \"
       select 'TOTAL ' || pg_size_pretty(pg_database_size(current_database()))\""
fi

