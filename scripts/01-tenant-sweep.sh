#!/usr/bin/env bash
# SWEEP 1 -- how many active tenants does it take to break the cache?
#
# The hypothesis this campaign was built on: every query carrying
# WHERE tenant_id multiplies the query space by the tenant count, so the hit
# ratio should fall as tenants rise.
#
# Concurrency is held at 8 clients so that tenant count is the only variable.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
header tenants
for T in 1 10 50 200; do
  cell "$T" -f /tmp/mt/dashboard.sql -D tenants=$T
done
