#!/usr/bin/env bash
# ============================================================================
# Helm deployment helper for PgCache Multi-Tenant Benchmark.
#
# Usage:
#   ./scripts/helm-deploy.sh --docker [tag]     # Deploy to Docker Desktop / local k8s
#   ./scripts/helm-deploy.sh --prod   [tag]     # Deploy to 3-node production k8s
#   ./scripts/helm-deploy.sh --template [tag]   # Render manifests locally
#   ./scripts/helm-deploy.sh --uninstall        # Uninstall pgcache-mt release
#   ./scripts/helm-deploy.sh --check            # Check cluster readiness
#
# Examples:
#   ./scripts/helm-deploy.sh --docker 0.7.0-arm64
#   ./scripts/helm-deploy.sh --prod 0.7.0
# ============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CHART_DIR="$REPO_ROOT/infra/helm/pgcache-mt"
NS="${NS:-pgcache-mt}"

usage() {
  echo "Usage: $0 [--docker|--prod|--do|--do-tuned|--template|--uninstall|--check] [tag]"
  exit 1
}

MODE="${1:-}"
TAG="${2:-0.7.0}"
[ -z "$MODE" ] && usage

case "$MODE" in
  --docker|--local)
    echo "=== Deploying PgCache Benchmark Helm Chart to Docker/Local Kubernetes ==="
    ARCH="$(uname -m)"
    if [ "$ARCH" = "arm64" ] && [[ "$TAG" != *-arm64 ]]; then
      TAG="${TAG}-arm64"
    fi
    echo "Namespace: $NS"
    echo "Tag:       $TAG"
    echo "Values:    $CHART_DIR/values-docker.yaml"
    helm upgrade --install pgcache-mt "$CHART_DIR" \
      -f "$CHART_DIR/values-docker.yaml" \
      --namespace "$NS" \
      --create-namespace \
      --set image.pgcache.tag="$TAG"
    echo ""
    echo "--> Waiting for pods to initialize..."
    kubectl -n "$NS" get pods -o wide || true
    ;;

  --prod|--k8s)
    echo "=== Deploying PgCache Benchmark Helm Chart to 3-Node Production Kubernetes ==="
    echo "Namespace: $NS"
    echo "Tag:       $TAG"
    echo "Values:    $CHART_DIR/values.yaml"
    helm upgrade --install pgcache-mt "$CHART_DIR" \
      --namespace "$NS" \
      --create-namespace \
      --set image.pgcache.tag="$TAG"
    echo ""
    echo "--> Verifying node distribution (must land on 3 distinct nodes):"
    kubectl -n "$NS" get pods -o wide || true
    ;;

  --do|--do-lowcost|--digitalocean)
    echo "=== Deploying PgCache Benchmark Helm Chart to DigitalOcean (Budget Profile) ==="
    echo "Namespace: $NS"
    echo "Tag:       $TAG"
    echo "Values:    $CHART_DIR/values-do-lowcost.yaml"
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite
    helm upgrade --install pgcache-mt "$CHART_DIR" \
      -f "$CHART_DIR/values-do-lowcost.yaml" \
      --namespace "$NS" \
      --set image.pgcache.tag="$TAG"
    echo ""
    echo "--> Verifying node distribution (must land on 3 distinct nodes):"
    kubectl -n "$NS" get pods -o wide || true
    ;;

  --do-tuned|--tuned)
    echo "=== Deploying PgCache Benchmark Helm Chart to DigitalOcean (Tuned Profile) ==="
    echo "Namespace: $NS"
    echo "Tag:       $TAG"
    echo "Values:    $CHART_DIR/values-do-tuned.yaml"
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite

    EXTRA_ARGS=()
    ORIGIN_IP="$(kubectl -n "$NS" get pod -l app=origin -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
    if [ -n "$ORIGIN_IP" ]; then
      echo "--> Configuring direct upstream URL to origin IP: $ORIGIN_IP"
      EXTRA_ARGS+=(--set pgcache.upstreamUrl="postgres://bench:benchpass@$ORIGIN_IP:5432/bench")
      EXTRA_ARGS+=(--set loadgen.originHost="$ORIGIN_IP")
    fi
    PGCACHE_IP="$(kubectl -n "$NS" get pod -l app=pgcache -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
    if [ -n "$PGCACHE_IP" ]; then
      echo "--> Configuring direct pgcache host to IP: $PGCACHE_IP"
      EXTRA_ARGS+=(--set loadgen.pgcacheHost="$PGCACHE_IP")
    fi

    helm upgrade --install pgcache-mt "$CHART_DIR" \
      -f "$CHART_DIR/values-do-tuned.yaml" \
      --namespace "$NS" \
      --set image.pgcache.tag="$TAG" \
      "${EXTRA_ARGS[@]}"
    echo ""
    echo "--> Verifying node distribution (must land on 3 distinct nodes):"
    kubectl -n "$NS" get pods -o wide || true
    ;;

  --template)
    echo "=== Rendering Helm Template Manifests ==="
    helm template pgcache-mt "$CHART_DIR" \
      -f "$CHART_DIR/values-docker.yaml" \
      --namespace "$NS" \
      --set image.pgcache.tag="$TAG"
    ;;

  --uninstall)
    echo "=== Uninstalling pgcache-mt release ==="
    helm uninstall pgcache-mt --namespace "$NS" || true
    ;;

  --check)
    echo "=== Kubernetes Pre-flight Check ==="
    if ! kubectl cluster-info >/dev/null 2>&1; then
      echo "ERROR: Unable to connect to a running Kubernetes cluster."
      echo "If using Docker Desktop, ensure Kubernetes is enabled under Settings -> Kubernetes."
      exit 1
    fi
    NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "Connected successfully. Found $NODES node(s)."
    kubectl get nodes -o wide
    ;;

  *)
    usage
    ;;
esac
