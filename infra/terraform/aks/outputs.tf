output "resource_group_name" {
  description = "Name of the provisioned Azure Resource Group."
  value       = azurerm_resource_group.rg.name
}

output "cluster_name" {
  description = "Name of the provisioned AKS cluster."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "cluster_id" {
  description = "Azure Resource Manager ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.aks.id
}

output "location" {
  description = "Azure region where the cluster is deployed."
  value       = azurerm_kubernetes_cluster.aks.location
}

output "availability_zone" {
  description = "Single Availability Zone used for node placement."
  value       = var.availability_zone
}

output "kubernetes_version" {
  description = "Kubernetes version running on the AKS control plane."
  value       = azurerm_kubernetes_cluster.aks.kubernetes_version
}

output "sku_tier" {
  description = "AKS control plane pricing tier ('Free' = $0.00/hr)."
  value       = azurerm_kubernetes_cluster.aks.sku_tier
}

output "system_vm_size" {
  description = "VM SKU of the 1-node system pool."
  value       = var.system_vm_size
}

output "benchmark_vm_size" {
  description = "VM SKU of the 3-node Spot benchmark pool."
  value       = azurerm_kubernetes_cluster_node_pool.benchmark.vm_size
}

output "benchmark_node_count" {
  description = "Number of Spot nodes in the benchmark pool."
  value       = azurerm_kubernetes_cluster_node_pool.benchmark.node_count
}

output "get_credentials_command" {
  description = "Azure CLI command to merge cluster credentials into ~/.kube/config."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
}

output "kube_config_raw" {
  description = "Raw kubeconfig for kubectl authentication."
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}
