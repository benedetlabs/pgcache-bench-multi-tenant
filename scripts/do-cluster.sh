#!/usr/bin/env bash
# ============================================================================
# DigitalOcean Kubernetes (DOKS) Helper for PgCache Multi-Tenant Benchmark
#
# Creates and destroys a low-cost, 3-node Kubernetes cluster on DigitalOcean
# with High Availability disabled (--ha=false) to keep control plane costs at $0.
#
# Usage:
#   ./scripts/do-cluster.sh create   [name] [size] [region]
#   ./scripts/do-cluster.sh destroy  [name]
#   ./scripts/do-cluster.sh deploy   [tag]
#   ./scripts/do-cluster.sh status   [name]
#
# Defaults:
#   name:   pgcache-bench
#   size:   s-4vcpu-8gb   (4 vCPU, 8 GB RAM -> ~$0.071/hr per node = ~$0.21/hr total)
#   region: nyc1
#
# Cost summary:
#   3x s-4vcpu-8gb: ~$0.21 / hour total ($0 control plane with --ha=false)
#   Destroy command (--dangerous) deletes nodes, cluster, and PVC block storage.
# ============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/do-cluster.sh <command> [arguments]

Commands:
  create   [name] [size] [region]  Create a 3-node low-cost cluster (--ha=false)
  destroy  [name]                  Delete cluster AND all associated disks (--dangerous)
  deploy   [tag]                   Deploy pgcache-mt Helm chart using budget profile
  status   [name]                  Show cluster and node status

Examples:
  ./scripts/do-cluster.sh create                                # Default: pgcache-bench, s-4vcpu-8gb, nyc1
  ./scripts/do-cluster.sh create pgcache-bench c-4 nyc3         # 4 vCPU dedicated CPU nodes in nyc3
  ./scripts/do-cluster.sh deploy 0.7.0                          # Deploy PgCache 0.7.0
  ./scripts/do-cluster.sh destroy                               # Tear down everything ($0 leftover billing)
EOF
  exit 1
}

CMD="${1:-}"
[ -z "$CMD" ] && usage

CLUSTER_NAME="${2:-pgcache-bench}"
SIZE="${3:-s-4vcpu-8gb}"
REGION="${4:-sfo2}"

case "$CMD" in
  create)
    echo "========================================================================"
    echo " Creating Low-Cost DigitalOcean Kubernetes Cluster"
    echo " Cluster Name:   $CLUSTER_NAME"
    echo " Node Size:      $SIZE (3 worker nodes)"
    echo " Region:         $REGION (Single-AZ)"
    echo " High Avail:     false (\$0 Control Plane)"
    echo " Estimated Cost: ~\$0.21 / hour total (Droplet cost only)"
    echo "========================================================================"

    # Verify doctl is authenticated
    if ! doctl account get >/dev/null 2>&1; then
      echo "FATAL: doctl is not authenticated. Run 'doctl auth init' first." >&2
      exit 1
    fi

    # Create cluster with HA disabled
    doctl kubernetes cluster create "$CLUSTER_NAME" \
      --region "$REGION" \
      --size "$SIZE" \
      --count 3 \
      --ha=false \
      --set-current-context \
      --wait

    echo ""
    echo "--> Cluster ready! Configuring benchmark namespace..."
    kubectl create namespace pgcache-mt --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace pgcache-mt pod-security.kubernetes.io/enforce=privileged --overwrite

    echo ""
    echo "--> Verifying node topology:"
    kubectl get nodes -o wide -L topology.kubernetes.io/zone

    echo ""
    echo "========================================================================"
    echo " Cluster '$CLUSTER_NAME' is ready!"
    echo ""
    echo " Next step (deploy benchmark):"
    echo "   $0 deploy 0.7.0"
    echo ""
    echo " When finished testing (destroy everything):"
    echo "   $0 destroy $CLUSTER_NAME"
    echo "========================================================================"
    ;;

  destroy)
    echo "========================================================================"
    echo " Destroying DigitalOcean Cluster '$CLUSTER_NAME' and Associated Disks"
    echo "========================================================================"

    read -p "Are you sure you want to permanently delete cluster '$CLUSTER_NAME' and all its volumes? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi

    # Delete cluster, all droplets, and all storage volumes/snapshots
    doctl kubernetes cluster delete "$CLUSTER_NAME" --dangerous -f

    echo "--> Cluster and all associated block storage volumes deleted successfully."
    echo "--> No residual resources remain active."
    ;;

  deploy)
    TAG="${2:-0.7.0}"
    echo "--> Deploying benchmark to current cluster with DigitalOcean budget profile..."
    "$REPO_ROOT/scripts/helm-deploy.sh" --do "$TAG"
    echo ""
    echo "--> Monitor pod status with:"
    echo "    kubectl -n pgcache-mt get pods -o wide -w"
    ;;

  status)
    echo "=== DigitalOcean Cluster Info ==="
    doctl kubernetes cluster get "$CLUSTER_NAME" || true
    echo ""
    echo "=== Kubernetes Nodes ==="
    kubectl get nodes -o wide -L topology.kubernetes.io/zone || true
    echo ""
    echo "=== Benchmark Pods ==="
    kubectl -n pgcache-mt get pods -o wide || true
    ;;

  *)
    usage
    ;;
esac
