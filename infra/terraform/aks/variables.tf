variable "subscription_id" {
  description = "Azure Subscription ID (optional if ARM_SUBSCRIPTION_ID environment variable is set)."
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "Name of the Azure Resource Group for the ephemeral benchmark cluster."
  type        = string
  default     = "rg-pgcache-bench"
}

variable "cluster_name" {
  description = "Name of the Azure Kubernetes Service (AKS) cluster."
  type        = string
  default     = "aks-pgcache-bench"
}

variable "location" {
  description = "Azure region for the cluster and Spot node pool (eastus2 and eastus offer deep Spot capacity and low Spot pricing)."
  type        = string
  default     = "eastus2"
}

variable "availability_zone" {
  description = "Single Availability Zone for all nodes to eliminate $0.01/GB cross-AZ bandwidth charges and inter-AZ latency spikes (~160 us RTT). Set to empty string (\"\") in regions without AZ support."
  type        = string
  default     = "1"
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS. Leave null to use the region's default stable release."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "AKS control plane pricing tier. MUST be 'Free' ($0.00/hr) to avoid the $0.10/hr (~$73/mo) Standard control plane management fee."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be 'Free' ($0/hr) or 'Standard'."
  }
}

variable "system_vm_size" {
  description = "VM SKU for the mandatory 1-node system pool (Azure AKS forbids Spot on the default system pool). Standard_B2als_v2 (2 vCPU, 4 GiB RAM) or Standard_B2s minimizes cost (~$0.018-$0.035/hr) while only_critical_addons_enabled keeps benchmark pods off it."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "benchmark_vm_size" {
  description = "VM SKU for the 3-node Spot user pool. Defaults to Standard_D8as_v5 (8 vCPU, 32 GiB RAM, matching README.md Section 7.1). Use Standard_E4s_v5 (4 vCPU, 32 GiB RAM) or Standard_D4as_v5 (4 vCPU, 16 GiB RAM) on subscriptions with tighter Spot vCPU quotas."
  type        = string
  default     = "Standard_D8as_v5"
}

variable "benchmark_node_count" {
  description = "Number of dedicated Spot worker nodes for the benchmark (3 nodes: 1 for origin, 1 for pgcache, 1 for loadgen via podAntiAffinity)."
  type        = number
  default     = 3

  validation {
    condition     = var.benchmark_node_count >= 3
    error_message = "At least 3 benchmark worker nodes are required so origin, pgcache, and loadgen each get a dedicated physical node via podAntiAffinity."
  }
}

variable "spot_max_price" {
  description = "Maximum hourly price per Spot VM (-1 means cap at standard on-demand price while paying the live Spot market rate, typically 75%-88% off)."
  type        = number
  default     = -1
}

variable "os_disk_type" {
  description = "OS disk type for the Spot benchmark node pool ('Managed' works on all VM SKUs including Standard_D8as_v5 and Standard_E4s_v5; set to 'Ephemeral' for $0 OS disk cost when using 'd'-series VMs with local temp/NVMe storage like Standard_D8ads_v5 or Standard_E4ds_v5)."
  type        = string
  default     = "Managed"

  validation {
    condition     = contains(["Managed", "Ephemeral"], var.os_disk_type)
    error_message = "os_disk_type must be either 'Managed' or 'Ephemeral'."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB (30 GiB is the minimum Linux OS disk size on AKS, cutting Azure Portal's 128 GiB default OS disk cost by 76%)."
  type        = number
  default     = 30

  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 2048
    error_message = "os_disk_size_gb must be at least 30 GiB (the minimum Linux OS disk size supported by Azure AKS)."
  }
}

variable "tags" {
  description = "Resource tags applied to all provisioned Azure resources."
  type        = map(string)
  default = {
    project     = "pgcache-bench-multi-tenant"
    environment = "benchmark-ephemeral"
    managed_by  = "terraform"
  }
}
