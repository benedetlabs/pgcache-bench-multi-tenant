terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.110.0, < 5.0.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {
    resource_group {
      # Allow 'terraform destroy' to cleanly delete the Resource Group even if
      # Kubernetes PVC disks or dynamic cloud resources were created inside it.
      prevent_deletion_if_contains_resources = false
    }
  }
}
