# ============================================================================
# Ultra-Low-Cost Azure Kubernetes Service (AKS) Benchmark Configuration
#
# Designed to eliminate every hidden Azure Portal cost trap while preserving
# the exact 3-node single-AZ Spot hardware topology required by the benchmark:
#
#   1. Control Plane: sku_tier = "Free" ($0.00/hr vs $0.10/hr Standard tier)
#   2. Zero Paid Add-ons:
#      - NO Azure Monitor / Container Insights / Log Analytics (oms_agent)
#      - NO Azure Managed Prometheus (monitor_metrics) & NO Managed Grafana
#      - NO Microsoft Defender for Containers (microsoft_defender)
#      - NO Azure Policy, Cost Analysis, Service Mesh, or NAT Gateway
#   3. System Pool (1 node):
#      - Azure AKS forbids Spot priority on the mandatory default system pool.
#      - Uses 1 small burstable node (Standard_B2als_v2) with
#        only_critical_addons_enabled = true (CriticalAddonsOnly taint) so only
#        kube-system and metrics-reader run there.
#   4. Benchmark User Pool (3 Spot nodes, Single AZ):
#      - 3x Spot nodes (Standard_D8as_v5 — 8 vCPU, 32 GiB RAM, or
#        Standard_E4s_v5 / Standard_D4as_v5) pinned to a single Availability
#        Zone for ~160 us inter-node RTT and $0 cross-AZ data transfer.
# ============================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # ── 1. Control Plane Cost Optimization ($0.00/hr) ─────────────────────────
  # Azure Portal defaults to "Standard" ($0.10/hr = ~$73/month).
  # "Free" tier provides the exact same Kubernetes API server for $0.00/hr.
  sku_tier              = var.sku_tier
  cost_analysis_enabled = false

  # ── 2. Disable All Costly Observability, Security & Policy Add-ons ────────
  # Azure Portal enables Container Insights (Log Analytics), Managed Prometheus,
  # Managed Grafana, and Defender by default. Not only do these charge per GB
  # ingested and per vCore, their DaemonSets steal CPU and pollute p99 latency.
  # Note: oms_agent, monitor_metrics, microsoft_defender, key_vault_secrets_provider,
  # service_mesh_profile, and web_app_routing blocks are intentionally omitted.
  azure_policy_enabled              = false
  http_application_routing_enabled  = false
  image_cleaner_enabled             = false
  open_service_mesh_enabled         = false
  oidc_issuer_enabled               = false
  workload_identity_enabled         = false
  local_account_disabled            = false
  role_based_access_control_enabled = true

  # ── 3. Minimal Storage CSI Profile ────────────────────────────────────────
  # Only enable Azure Disk CSI driver (required for origin & loadgen PVCs).
  # Disable Azure Files, Blob CSI, and Volume Snapshot controller pods.
  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = false
    blob_driver_enabled         = false
    snapshot_controller_enabled = false
  }

  # ── 4. Minimal Default System Node Pool (1 Small Node, Critical Addons) ───
  # Azure AKS requires the default node pool to have mode = "System" and
  # forbids priority = "Spot" on it. We provision a single tiny node with
  # only_critical_addons_enabled = true so benchmark pods NEVER land here.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    node_count                   = 1
    auto_scaling_enabled         = false
    zones                        = var.availability_zone != "" ? [var.availability_zone] : null
    only_critical_addons_enabled = true
    os_disk_type                 = "Managed"
    os_disk_size_gb              = var.os_disk_size_gb
    os_sku                       = "Ubuntu"
    temporary_name_for_rotation  = "sysrot"
    tags                         = var.tags
  }

  # ── 5. Network Profile (Azure CNI Overlay + Single Outbound IP) ───────────
  # Avoids Managed NAT Gateway (~$33/mo + per-GB fee) and avoids VNet IP exhaustion.
  # Benchmark pods use hostNetwork: true to communicate directly over node IPs.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"

    load_balancer_profile {
      managed_outbound_ip_count = 1
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# ── 6. Dedicated 3-Node Spot Benchmark Pool (Single Availability Zone) ──────
# Runs origin (PostgreSQL 17), pgcache, and loadgen (pgbench) — strictly 1 pod
# per physical node via podAntiAffinity, all inside the same Availability Zone.
resource "azurerm_kubernetes_cluster_node_pool" "benchmark" {
  name                  = "benchspot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  mode                  = "User"
  vm_size               = var.benchmark_vm_size
  node_count            = var.benchmark_node_count
  auto_scaling_enabled  = false

  # Spot configuration: ~75%-88% discount off pay-as-you-go VM rates.
  # "Delete" eviction policy ensures evicted VMs and their OS disks are deleted
  # immediately rather than remaining allocated and billing for storage.
  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = var.spot_max_price

  # Single Availability Zone placement:
  # 1. Eliminates $0.01/GB cross-AZ bandwidth charges in Azure
  # 2. Guarantees low, uniform inter-node RTT (~160 us) across Path A and Path B
  zones = var.availability_zone != "" ? [var.availability_zone] : null

  os_disk_type    = var.os_disk_type
  os_disk_size_gb = var.os_disk_size_gb
  os_sku          = "Ubuntu"

  # Azure automatically adds label 'kubernetes.azure.com/scalesetpriority=spot'
  # and taint 'kubernetes.azure.com/scalesetpriority=spot:NoSchedule'.
  # We also attach a custom label for explicit pool selection.
  node_labels = {
    "bench-pool" = "spot"
  }

  tags = var.tags
}
