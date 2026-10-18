mock_provider "azurerm" {
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pgcache-bench/providers/Microsoft.ContainerService/managedClusters/aks-pgcache-bench"
    }
  }
}

run "default_ultra_low_cost_aks_topology" {
  command = plan

  assert {
    condition     = azurerm_resource_group.rg.name == "rg-pgcache-bench"
    error_message = "Default Resource Group name must be 'rg-pgcache-bench'."
  }

  assert {
    condition     = azurerm_resource_group.rg.location == "eastus2"
    error_message = "Default location must be 'eastus2'."
  }

  # 1. Control Plane Zero-Overhead Assertions ($0.00/hr)
  assert {
    condition     = azurerm_kubernetes_cluster.aks.sku_tier == "Free"
    error_message = "AKS control plane sku_tier must default to 'Free' ($0.00/hr)."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.aks.support_plan == "KubernetesOfficial"
    error_message = "AKS support_plan must be 'KubernetesOfficial' ($0.00/hr)."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.aks.cost_analysis_enabled == false
    error_message = "AKS cost_analysis_enabled must be false."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.aks.automatic_upgrade_channel == null && azurerm_kubernetes_cluster.aks.node_os_upgrade_channel == "None"
    error_message = "Automatic cluster and node OS upgrades must be disabled to prevent mid-benchmark node drains."
  }

  # 2. Paid Add-on Disabling Assertions (No Prometheus, No Grafana, No OMS/Log Analytics, No Defender, No Policy)
  assert {
    condition     = length(azurerm_kubernetes_cluster.aks.oms_agent) == 0
    error_message = "oms_agent (Container Insights / Log Analytics) must be omitted."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.aks.monitor_metrics) == 0
    error_message = "monitor_metrics (Azure Managed Prometheus) must be omitted."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.aks.microsoft_defender) == 0
    error_message = "microsoft_defender must be omitted."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.aks.azure_policy_enabled == false && azurerm_kubernetes_cluster.aks.http_application_routing_enabled == false && azurerm_kubernetes_cluster.aks.image_cleaner_enabled == false && azurerm_kubernetes_cluster.aks.open_service_mesh_enabled == false && azurerm_kubernetes_cluster.aks.oidc_issuer_enabled == false && azurerm_kubernetes_cluster.aks.workload_identity_enabled == false
    error_message = "All optional AKS add-ons must be explicitly disabled."
  }

  # 3. Minimal Storage CSI Driver Assertions
  assert {
    condition     = azurerm_kubernetes_cluster.aks.storage_profile[0].disk_driver_enabled == true && azurerm_kubernetes_cluster.aks.storage_profile[0].file_driver_enabled == false && azurerm_kubernetes_cluster.aks.storage_profile[0].blob_driver_enabled == false && azurerm_kubernetes_cluster.aks.storage_profile[0].snapshot_controller_enabled == false
    error_message = "Only disk_driver_enabled should be true in storage_profile."
  }

  # 4. Network Profile Assertions (Azure CNI Overlay + 1 Outbound IP, No NAT Gateway)
  assert {
    condition     = azurerm_kubernetes_cluster.aks.network_profile[0].network_plugin == "azure" && azurerm_kubernetes_cluster.aks.network_profile[0].network_plugin_mode == "overlay" && azurerm_kubernetes_cluster.aks.network_profile[0].load_balancer_sku == "standard" && azurerm_kubernetes_cluster.aks.network_profile[0].outbound_type == "loadBalancer" && azurerm_kubernetes_cluster.aks.network_profile[0].load_balancer_profile[0].managed_outbound_ip_count == 1
    error_message = "Network profile must use Azure CNI Overlay with standard loadBalancer and 1 outbound IP."
  }

  # 5. Mandatory 1-Node System Pool Assertions
  assert {
    condition     = azurerm_kubernetes_cluster.aks.default_node_pool[0].name == "system" && azurerm_kubernetes_cluster.aks.default_node_pool[0].node_count == 1 && azurerm_kubernetes_cluster.aks.default_node_pool[0].vm_size == "Standard_B2als_v2" && azurerm_kubernetes_cluster.aks.default_node_pool[0].only_critical_addons_enabled == true && azurerm_kubernetes_cluster.aks.default_node_pool[0].zones == toset(["1"]) && azurerm_kubernetes_cluster.aks.default_node_pool[0].os_disk_size_gb == 30
    error_message = "Default system pool must be 1x Standard_B2als_v2 in zone 1 with only_critical_addons_enabled = true and 30 GiB OS disk."
  }

  # 6. Dedicated 3-Node Single-AZ Spot Benchmark Pool Assertions
  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.benchmark.name == "benchspot" && azurerm_kubernetes_cluster_node_pool.benchmark.mode == "User" && azurerm_kubernetes_cluster_node_pool.benchmark.priority == "Spot" && azurerm_kubernetes_cluster_node_pool.benchmark.eviction_policy == "Delete" && azurerm_kubernetes_cluster_node_pool.benchmark.spot_max_price == -1 && azurerm_kubernetes_cluster_node_pool.benchmark.node_count == 3 && azurerm_kubernetes_cluster_node_pool.benchmark.vm_size == "Standard_D8as_v5" && azurerm_kubernetes_cluster_node_pool.benchmark.zones == toset(["1"]) && azurerm_kubernetes_cluster_node_pool.benchmark.os_disk_type == "Managed" && azurerm_kubernetes_cluster_node_pool.benchmark.os_disk_size_gb == 30 && azurerm_kubernetes_cluster_node_pool.benchmark.node_labels["bench-pool"] == "spot"
    error_message = "Benchmark node pool must be 3x Spot Standard_D8as_v5 in zone 1 with Delete eviction policy."
  }
}

run "ephemeral_os_disk_with_d_series_spot_sku" {
  command = plan

  variables {
    benchmark_vm_size = "Standard_E4ds_v5"
    os_disk_type      = "Ephemeral"
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.benchmark.vm_size == "Standard_E4ds_v5" && azurerm_kubernetes_cluster_node_pool.benchmark.os_disk_type == "Ephemeral"
    error_message = "d-series v5 SKUs (Standard_E4ds_v5) must support os_disk_type = 'Ephemeral'."
  }
}

run "reject_ephemeral_os_disk_on_diskless_v5_sku" {
  command = plan

  variables {
    benchmark_vm_size = "Standard_D8as_v5"
    os_disk_type      = "Ephemeral"
  }

  expect_failures = [
    azurerm_kubernetes_cluster_node_pool.benchmark,
  ]
}

run "reject_ephemeral_os_disk_on_diskless_e4s_v5_sku" {
  command = plan

  variables {
    benchmark_vm_size = "Standard_E4s_v5"
    os_disk_type      = "Ephemeral"
  }

  expect_failures = [
    azurerm_kubernetes_cluster_node_pool.benchmark,
  ]
}

run "reject_invalid_sku_tier" {
  command = plan

  variables {
    sku_tier = "Premium"
  }

  expect_failures = [
    var.sku_tier,
  ]
}

run "reject_fewer_than_three_benchmark_nodes" {
  command = plan

  variables {
    benchmark_node_count = 2
  }

  expect_failures = [
    var.benchmark_node_count,
  ]
}

run "reject_os_disk_smaller_than_30gb" {
  command = plan

  variables {
    os_disk_size_gb = 20
  }

  expect_failures = [
    var.os_disk_size_gb,
  ]
}

run "verify_outputs_on_mock_apply" {
  command = apply

  assert {
    condition     = output.resource_group_name == "rg-pgcache-bench" && output.cluster_name == "aks-pgcache-bench" && output.sku_tier == "Free" && output.benchmark_vm_size == "Standard_D8as_v5" && output.benchmark_node_count == 3 && output.get_credentials_command == "az aks get-credentials --resource-group rg-pgcache-bench --name aks-pgcache-bench --overwrite-existing"
    error_message = "All Terraform outputs must resolve accurately on apply."
  }
}
