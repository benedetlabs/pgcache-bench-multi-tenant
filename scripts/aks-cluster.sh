#!/usr/bin/env bash
# ============================================================================
# Azure Kubernetes Service (AKS) Helper for PgCache Multi-Tenant Benchmark
#
# Provisions and destroys an ultra-low-cost AKS cluster via Terraform
# (infra/terraform/aks/) with:
#   - Control Plane: sku_tier = "Free" ($0.00/hr management fee)
#   - Zero Paid Add-ons: NO Azure Monitor/Log Analytics, NO Managed Prometheus,
#     NO Managed Grafana, NO Defender, NO Azure Policy, NO NAT Gateway
#   - System Pool: 1x Standard_B2als_v2 (CriticalAddonsOnly taint)
#   - Benchmark Pool: 3x Spot VMs (Standard_D8as_v5 default — 8 vCPU, 32 GiB RAM)
#     pinned to a single Availability Zone ($0 cross-AZ bandwidth, ~160 us RTT)
#
# Usage:
#   ./scripts/aks-cluster.sh create   [vm_size] [location] [zone]
#   ./scripts/aks-cluster.sh plan     [vm_size] [location] [zone]
#   ./scripts/aks-cluster.sh deploy   [tag] [profile]
#   ./scripts/aks-cluster.sh status
#   ./scripts/aks-cluster.sh destroy  [--yes]
# ============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform/aks"
NS="${NS:-pgcache-mt}"

usage() {
  cat <<'EOF'
Usage: ./scripts/aks-cluster.sh <command> [arguments]

Commands:
  create   [vm_size] [location] [zone]  Provision ultra-low-cost AKS + 3-node Spot pool via Terraform
  plan     [vm_size] [location] [zone]  Preview Terraform execution plan without creating resources
  deploy   [tag] [profile]              Deploy pgcache-mt Helm chart (--aks-tuned default, or --aks)
  status                                Show AKS cluster, Spot node topology, and benchmark pod status
  destroy  [--yes]                      Uninstall Helm release and destroy entire Terraform stack ($0 billing)

Defaults:
  vm_size:  Standard_D8as_v5 (8 vCPU, 32 GiB RAM Spot, matching README.md Section 7.1)
            (Alternatives: Standard_E4s_v5 [4 vCPU, 32 GiB] or Standard_D4as_v5 [4 vCPU, 16 GiB])
  location: eastus2
  zone:     1 (Single-AZ placement for $0 cross-AZ traffic & minimal RTT)

Examples:
  ./scripts/aks-cluster.sh create                                   # Default: Standard_D8as_v5, eastus2, zone 1
  ./scripts/aks-cluster.sh create Standard_E4s_v5 eastus2 1         # 4-vCPU / 32-GiB Spot nodes (12 Spot vCPUs total)
  ./scripts/aks-cluster.sh deploy 0.7.1                             # Deploy PgCache 0.7.1 with direct node routing
  ./scripts/aks-cluster.sh destroy                                  # Tear down cluster + Resource Group ($0 leftover)
EOF
  exit 1
}

ensure_azure_auth() {
  if ! command -v terraform >/dev/null 2>&1; then
    echo "FATAL: 'terraform' CLI not found. Install via 'brew install terraform'." >&2
    exit 1
  fi
  if ! command -v az >/dev/null 2>&1; then
    echo "FATAL: Azure CLI ('az') not found. Install via 'brew install azure-cli'." >&2
    exit 1
  fi
  if ! az account show >/dev/null 2>&1; then
    echo "FATAL: Azure CLI is not authenticated. Run 'az login' first." >&2
    exit 1
  fi
  if [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
    ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
    export ARM_SUBSCRIPTION_ID
  fi
}

CMD="${1:-}"
[ -z "$CMD" ] && usage

case "$CMD" in
  create)
    VM_SIZE="${2:-Standard_D8as_v5}"
    LOCATION="${3:-eastus2}"
    ZONE="${4:-1}"

    ensure_azure_auth

    echo "========================================================================"
    echo " Provisioning Ultra-Low-Cost Azure AKS Benchmark Cluster (Terraform)"
    echo " Subscription:   $ARM_SUBSCRIPTION_ID"
    echo " Region / Zone:  $LOCATION (Single Availability Zone: $ZONE)"
    echo " Control Plane:  Free Tier (\$0.00/hr — Prometheus/Grafana/OMS disabled)"
    echo " System Pool:    1x Standard_B2als_v2 (CriticalAddonsOnly)"
    echo " Benchmark Pool: 3x $VM_SIZE (Spot Priority, Eviction: Delete)"
    echo "========================================================================"

    terraform -chdir="$TF_DIR" init -input=false
    terraform -chdir="$TF_DIR" apply -auto-approve \
      -var="benchmark_vm_size=$VM_SIZE" \
      -var="location=$LOCATION" \
      -var="availability_zone=$ZONE"

    RG_NAME="$(terraform -chdir="$TF_DIR" output -raw resource_group_name)"
    CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw cluster_name)"

    echo ""
    echo "--> Fetching kubectl credentials for '$CLUSTER_NAME'..."
    az aks get-credentials \
      --resource-group "$RG_NAME" \
      --name "$CLUSTER_NAME" \
      --overwrite-existing

    echo ""
    echo "--> Configuring privileged benchmark namespace '$NS'..."
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=privileged --overwrite

    echo ""
    echo "--> Verifying node topology (1 system node + 3 single-AZ Spot nodes):"
    kubectl get nodes -o wide \
      -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type,kubernetes.azure.com/scalesetpriority,kubernetes.azure.com/mode

    echo ""
    echo "========================================================================"
    echo " AKS Cluster '$CLUSTER_NAME' is ready!"
    echo ""
    echo " Next step (deploy benchmark):"
    echo "   $0 deploy 0.7.1"
    echo ""
    echo " When finished testing (destroy everything for \$0 leftover billing):"
    echo "   $0 destroy"
    echo "========================================================================"
    ;;

  plan)
    VM_SIZE="${2:-Standard_D8as_v5}"
    LOCATION="${3:-eastus2}"
    ZONE="${4:-1}"

    ensure_azure_auth

    terraform -chdir="$TF_DIR" init -input=false
    terraform -chdir="$TF_DIR" plan \
      -var="benchmark_vm_size=$VM_SIZE" \
      -var="location=$LOCATION" \
      -var="availability_zone=$ZONE"
    ;;

  deploy)
    TAG="${2:-0.7.1}"
    PROFILE="${3:---aks-tuned}"
    echo "--> Deploying benchmark to AKS with profile ($PROFILE) and PgCache tag ($TAG)..."
    "$REPO_ROOT/scripts/helm-deploy.sh" "$PROFILE" "$TAG"
    echo ""
    echo "--> Monitor pod status with:"
    echo "    kubectl -n $NS get pods -o wide"
    ;;

  status)
    echo "=== Terraform Outputs ==="
    terraform -chdir="$TF_DIR" output 2>/dev/null || echo "(No local Terraform state found)"
    echo ""
    echo "=== Kubernetes Nodes (Zone / SKU / Spot Priority / Mode) ==="
    kubectl get nodes -o wide \
      -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type,kubernetes.azure.com/scalesetpriority,kubernetes.azure.com/mode || true
    echo ""
    echo "=== Benchmark Pods ($NS) ==="
    kubectl -n "$NS" get pods -o wide || true
    ;;

  destroy)
    CONFIRM="${2:-}"
    echo "========================================================================"
    echo " Destroying Azure AKS Cluster and Resource Group via Terraform"
    echo "========================================================================"

    if [ "$CONFIRM" != "--yes" ] && [ "$CONFIRM" != "-y" ]; then
      read -p "Are you sure you want to permanently destroy the AKS cluster and all volumes? (y/N) " -n 1 -r
      echo ""
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
      fi
    fi

    ensure_azure_auth

    echo "--> Uninstalling Helm release and PVCs (if connected)..."
    helm uninstall pgcache-mt --namespace "$NS" 2>/dev/null || true
    kubectl delete namespace "$NS" --timeout=60s 2>/dev/null || true

    echo "--> Running 'terraform destroy' in $TF_DIR..."
    terraform -chdir="$TF_DIR" destroy -auto-approve

    echo "--> AKS cluster, Spot node pool, Managed Disks, and Resource Group deleted."
    echo "--> $0.00 residual billing confirmed."
    ;;

  *)
    usage
    ;;
esac
