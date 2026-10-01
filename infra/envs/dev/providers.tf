terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # For Azure features azurerm doesn't model yet (custom Log Analytics table schema)
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateat1234" # must match bootstrap/bootstrap.ps1 -sa
    container_name       = "tfstate"
    key                  = "dev.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Purging needs subscription-level rights this layer doesn't have
      purge_soft_delete_on_destroy = false
    }
    storage {
      # Storage accounts here have shared keys disabled, and this identity has no
      # data-plane role, so only use the management API for storage
      data_plane_available = false
    }
  }
  subscription_id = "4c952ab8-ce51-49fd-a686-de35331d97af"

  # This identity only has rights on its resource group; the platform layer
  # registers resource providers at subscription level
  resource_provider_registrations = "none"
}

provider "azapi" {
  subscription_id = "4c952ab8-ce51-49fd-a686-de35331d97af"
}
