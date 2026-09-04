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
HERE="$(cd "$(dirname "$0")" && pwd)"

for f in 01-schema 02-tenant; do
  echo "--- applying $f.sql ---"
  kubectl -n "$NS" exec -i deploy/loadgen -- bash -c "cat > /tmp/$f.sql" < "$HERE/../sql/$f.sql"
  kubectl -n "$NS" exec deploy/loadgen -- \
    bash -c "psql -h \$ORIGIN_HOST -U \$PGUSER -d \$PGDATABASE -q -f /tmp/$f.sql"
done

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
