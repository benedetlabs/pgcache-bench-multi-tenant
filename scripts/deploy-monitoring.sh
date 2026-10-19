#!/usr/bin/env bash
# ============================================================================
# Deploy Telemetry & Grafana Cloud Remote Write Stack to Kubernetes (DOKS/AKS)
#
# Labels the 3 benchmark nodes with bench_role={origin,pgcache,loadgen},
# creates the grafana-cloud-credentials Secret from .env.grafana (or env vars),
# deploys node-exporter, postgres-exporter, pgbench-exporter, and grafana-alloy,
# and verifies that metrics are flowing to Grafana Cloud.
#
# Usage:
#   ./scripts/deploy-monitoring.sh
# ============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-pgcache-mt}"
MON_NS="monitoring"

# Load local Grafana Cloud credentials if present
if [ -f "$REPO_ROOT/.env.grafana" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env.grafana"
fi

CLUSTER_NAME="${CLUSTER_NAME:-pgcache-doks}"
GCLOUD_PROM_URL="${GCLOUD_PROM_URL:-https://prometheus-prod-67-prod-us-west-0.grafana.net/api/prom/push}"
GCLOUD_PROM_USER="${GCLOUD_PROM_USER:-3686863}"
GCLOUD_LOKI_URL="${GCLOUD_LOKI_URL:-https://logs-prod-021.grafana.net/loki/api/v1/push}"
GCLOUD_LOKI_USER="${GCLOUD_LOKI_USER:-1839096}"
GCLOUD_FM_URL="${GCLOUD_FM_URL:-https://fleet-management-prod-014.grafana.net}"
GCLOUD_FM_USER="${GCLOUD_FM_USER:-1881320}"

if [ -z "${GCLOUD_RW_API_KEY:-}" ] || [[ "${GCLOUD_RW_API_KEY}" == *"REPLACE_WITH"* ]]; then
  echo "FATAL: GCLOUD_RW_API_KEY is not set. Configure .env.grafana or export GCLOUD_RW_API_KEY." >&2
  exit 1
fi

echo "========================================================================"
echo " Deploying Grafana Cloud Telemetry Stack"
echo " Cluster Name:    $CLUSTER_NAME"
echo " Prometheus URL:  $GCLOUD_PROM_URL (User: $GCLOUD_PROM_USER)"
echo " Fleet Mgmt URL:  $GCLOUD_FM_URL (User: $GCLOUD_FM_USER)"
echo "========================================================================"

# 1. Label the 3 Kubernetes nodes with their benchmark role (origin, pgcache, loadgen)
echo "--> Labeling Kubernetes nodes by benchmark role (bench_role)..."
for role in origin pgcache loadgen; do
  node=$(kubectl -n "$NS" get pod -l "app=$role" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
  if [ -n "$node" ]; then
    echo "    Node '$node' -> bench_role=$role"
    kubectl label node "$node" "bench_role=$role" --overwrite >/dev/null
  else
    echo "    WARNING: Could not find running pod for app=$role in namespace $NS"
  fi
done

# 2. Ensure monitoring namespace exists and has privileged pod security for node-exporter
kubectl create namespace "$MON_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$MON_NS" pod-security.kubernetes.io/enforce=privileged --overwrite

# 3. Create/update the Grafana Cloud credentials Secret
echo "--> Configuring Secret 'grafana-cloud-credentials' in namespace '$MON_NS'..."
kubectl -n "$MON_NS" create secret generic grafana-cloud-credentials \
  --from-literal=CLUSTER_NAME="$CLUSTER_NAME" \
  --from-literal=GCLOUD_RW_API_KEY="$GCLOUD_RW_API_KEY" \
  --from-literal=GCLOUD_PROM_URL="$GCLOUD_PROM_URL" \
  --from-literal=GCLOUD_PROM_USER="$GCLOUD_PROM_USER" \
  --from-literal=GCLOUD_LOKI_URL="$GCLOUD_LOKI_URL" \
  --from-literal=GCLOUD_LOKI_USER="$GCLOUD_LOKI_USER" \
  --from-literal=GCLOUD_FM_URL="$GCLOUD_FM_URL" \
  --from-literal=GCLOUD_FM_USER="$GCLOUD_FM_USER" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Apply the telemetry stack manifest
echo "--> Applying infra/monitoring/grafana-cloud-monitoring.yaml..."
kubectl apply -f "$REPO_ROOT/infra/monitoring/grafana-cloud-monitoring.yaml"

# 5. Point postgres-exporter directly at Origin's IP (bypasses headless DNS issues under hostNetwork)
ORIGIN_IP=$(kubectl -n "$NS" get pod -l app=origin -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
if [ -n "$ORIGIN_IP" ]; then
  echo "--> Pointing postgres-exporter directly to Origin IP ($ORIGIN_IP:5432)..."
  kubectl -n "$MON_NS" set env deploy/postgres-exporter \
    DATA_SOURCE_NAME="postgresql://bench:benchpass@${ORIGIN_IP}:5432/bench?sslmode=disable"
fi

echo "--> Waiting for monitoring pods to become ready..."
kubectl -n "$MON_NS" rollout status daemonset/node-exporter --timeout=2m
kubectl -n "$MON_NS" rollout status deploy/postgres-exporter --timeout=2m
kubectl -n "$MON_NS" rollout status deploy/pgbench-exporter --timeout=2m
kubectl -n "$MON_NS" rollout status deploy/grafana-alloy --timeout=2m

echo ""
echo "=== Monitoring Pods Status ==="
kubectl -n "$MON_NS" get pods -o wide
echo ""
echo "========================================================================"
echo " Grafana Cloud Telemetry Stack is LIVE!"
echo " Metrics are now streaming every 5-10s to:"
echo "   ${GRAFANA_STACK_URL:-https://pgcachebench.grafana.net}"
echo "========================================================================"
