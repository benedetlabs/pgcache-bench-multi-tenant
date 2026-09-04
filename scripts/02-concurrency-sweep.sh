#!/usr/bin/env bash
# SWEEP 2 -- separating the caching gain from the saturation gain.
#
# A big number at high concurrency is two effects added together: the cache
# being faster per request, and the origin falling over under load. Only the
# first follows a reader home to an unsaturated system.
#
# The single-client row is the one that isolates caching: with one client there
# is no queueing at the origin OR at the proxy.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
header clients
for C in 1 4 8 16 32; do
  CLIENTS=$C cell "$C" -f /tmp/mt/dashboard.sql -D tenants=200
done
