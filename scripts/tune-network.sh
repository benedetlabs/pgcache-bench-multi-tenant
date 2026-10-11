#!/usr/bin/env bash
# ============================================================================
# Network & Host Tuning Helper for PgCache Multi-Tenant Benchmark
#
# Configures:
# 1. Direct Node IP host routing in /etc/hosts across all pods to bypass CoreDNS
# 2. Exports direct node IP environment variables in loadgen
# 3. Verifies Linux kernel sysctl stack tuning applied by initContainer
# ============================================================================
set -euo pipefail

NS="${NS:-pgcache-mt}"

echo "=== Verifying Cluster Pods & Node Distribution ==="
kubectl -n "$NS" get pods -o wide

# Ensure all 3 benchmark pods are running
for pod in origin-0 deploy/pgcache deploy/loadgen; do
  echo "--> Waiting for $pod to be ready..."
  kubectl -n "$NS" rollout status "$pod" --timeout=3m 2>/dev/null || true
done

ORIGIN_IP="$(kubectl -n "$NS" get pod -l app=origin -o jsonpath='{.items[0].status.podIP}')"
PGCACHE_IP="$(kubectl -n "$NS" get pod -l app=pgcache -o jsonpath='{.items[0].status.podIP}')"
LOADGEN_IP="$(kubectl -n "$NS" get pod -l app=loadgen -o jsonpath='{.items[0].status.podIP}')"

echo ""
echo "=== Direct Node IP Addresses ==="
echo "Origin Node IP:  $ORIGIN_IP"
echo "PgCache Node IP: $PGCACHE_IP"
echo "Loadgen Node IP: $LOADGEN_IP"

if [ -z "$ORIGIN_IP" ] || [ -z "$PGCACHE_IP" ] || [ -z "$LOADGEN_IP" ]; then
  echo "FATAL: Could not resolve all pod IPs." >&2
  exit 1
fi

echo ""
echo "=== Enforcing Direct Node IP Addressing in Deployments (CoreDNS Bypass) ==="
# PgCache upstream URL to direct Origin IP
TARGET_UPSTREAM="postgres://bench:benchpass@$ORIGIN_IP:5432/bench"
CURRENT_UPSTREAM="$(kubectl -n "$NS" get deploy pgcache -o jsonpath='{.spec.template.spec.containers[?(@.name=="pgcache")].env[?(@.name=="UPSTREAM_URL")].value}' 2>/dev/null || true)"
if [ "$CURRENT_UPSTREAM" != "$TARGET_UPSTREAM" ]; then
  echo "--> Setting PgCache UPSTREAM_URL to direct Origin IP ($ORIGIN_IP)..."
  kubectl -n "$NS" set env deploy/pgcache UPSTREAM_URL="$TARGET_UPSTREAM"
  kubectl -n "$NS" rollout status deploy/pgcache --timeout=3m
fi

# Loadgen direct target hosts
CURRENT_ORIGIN="$(kubectl -n "$NS" get deploy loadgen -o jsonpath='{.spec.template.spec.containers[?(@.name=="bench")].env[?(@.name=="ORIGIN_HOST")].value}' 2>/dev/null || true)"
CURRENT_PGCACHE="$(kubectl -n "$NS" get deploy loadgen -o jsonpath='{.spec.template.spec.containers[?(@.name=="bench")].env[?(@.name=="PGCACHE_HOST")].value}' 2>/dev/null || true)"
if [ "$CURRENT_ORIGIN" != "$ORIGIN_IP" ] || [ "$CURRENT_PGCACHE" != "$PGCACHE_IP" ]; then
  echo "--> Setting Loadgen ORIGIN_HOST ($ORIGIN_IP) and PGCACHE_HOST ($PGCACHE_IP)..."
  kubectl -n "$NS" set env deploy/loadgen ORIGIN_HOST="$ORIGIN_IP" PGCACHE_HOST="$PGCACHE_IP"
  kubectl -n "$NS" rollout status deploy/loadgen --timeout=3m
fi

echo ""
echo "=== Configuring Direct Node Routing in /etc/hosts ==="
HOSTS_BLOCK="
# Benchmark direct node routing (bypasses CoreDNS)
$ORIGIN_IP origin origin.$NS.svc.cluster.local origin.$NS.svc origin.default.svc.cluster.local
$PGCACHE_IP pgcache pgcache.$NS.svc.cluster.local pgcache.$NS.svc pgcache.default.svc.cluster.local
$LOADGEN_IP loadgen loadgen.$NS.svc.cluster.local loadgen.$NS.svc loadgen.default.svc.cluster.local
"

for target in "deploy/loadgen" "pod/origin-0"; do
  echo "--> Injecting direct routing into $target..."
  kubectl -n "$NS" exec "$target" -- /bin/sh -c "
    if ! grep -q '$ORIGIN_IP origin' /etc/hosts 2>/dev/null; then
      printf '%s\n' '$HOSTS_BLOCK' >> /etc/hosts
    fi
  " 2>/dev/null || echo "Note: /etc/hosts already populated or read-only in $target"
done

# In pgcache (non-root), UPSTREAM_URL already connects directly to $ORIGIN_IP:5432
echo "--> Note: deploy/pgcache connects directly to $ORIGIN_IP:5432 via UPSTREAM_URL (zero DNS lookup)."

echo ""
echo "=== Configuring Loadgen Direct Node IP Environment ==="
kubectl -n "$NS" exec deploy/loadgen -- bash -c "
  echo 'export ORIGIN_HOST=$ORIGIN_IP' >> /etc/profile.d/benchmark-hosts.sh 2>/dev/null || true
  echo 'export PGCACHE_HOST=$PGCACHE_IP' >> /etc/profile.d/benchmark-hosts.sh 2>/dev/null || true
  echo 'export ORIGIN_HOST=$ORIGIN_IP' >> ~/.bashrc 2>/dev/null || true
  echo 'export PGCACHE_HOST=$PGCACHE_IP' >> ~/.bashrc 2>/dev/null || true
"

echo ""
echo "=== Verifying Sysctl & Kernel Tuning on Nodes ==="
for target in "pod/origin-0" "deploy/loadgen"; do
  echo "--> Checking kernel parameters in $target:"
  kubectl -n "$NS" exec "$target" -- /bin/sh -c "
    echo '  tcp_slow_start_after_idle:' \$(cat /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null || echo 'N/A')
    echo '  somaxconn:                ' \$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo 'N/A')
    echo '  tcp_max_syn_backlog:      ' \$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || echo 'N/A')
    echo '  tcp_tw_reuse:             ' \$(cat /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || echo 'N/A')
    for rps in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
      if [ -f \"\$rps\" ]; then
        echo \"  rps_cpus (\$rps):        \$(cat \$rps 2>/dev/null || echo 'N/A')\"
      fi
    done
  "
done

echo ""
echo "=== Network & Host Tuning Complete ==="
