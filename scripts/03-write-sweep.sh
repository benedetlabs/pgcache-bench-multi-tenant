#!/usr/bin/env bash
# SWEEP 3 -- does the advantage survive writes, and does concentration matter?
#
# Campaign s4 found the throughput advantage gone at a 10% write ratio. That
# campaign had cheap reads (0.191 ms point selects) and reads and writes sharing
# the same 1,000 keys.
#
# Two things change here: the read is an eight-statement dashboard costing the
# origin ~79 ms, and :wtenants lets writes be concentrated on a subset of the
# tenants the reads span.
#
# Columns are "write_pct:write_tenants".
set -uo pipefail
source "$(dirname "$0")/lib.sh"
header "wpct:wt"
for spec in "0:200" "5:1" "5:10" "5:200" "10:1" "10:200"; do
  W="${spec%%:*}"; WT="${spec##*:}"; R=$((100 - W))
  if [ "$W" = "0" ]; then
    cell "$spec" -f /tmp/mt/dashboard.sql -D tenants=200 -D wtenants=$WT
  else
    cell "$spec" -f /tmp/mt/dashboard.sql@$R -f /tmp/mt/write.sql@$W \
                 -D tenants=200 -D wtenants=$WT
  fi
done
