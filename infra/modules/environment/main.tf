# One ChargeNet environment: telemetry pipeline, alerts, dashboard, status API and
# Key Vault, deployed into the resource group the platform vends for it.

locals {
  env  = var.env
  tags = { project = "chargenet", env = local.env, owner = "andre" }
}

data "azurerm_client_config" "current" {}

# Vended by infra/platform; this module deploys into it
data "azurerm_resource_group" "core" {
  name = "rg-chargenet-${local.env}"
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-chargenet-${local.env}"
  location            = data.azurerm_resource_group.core.location
  resource_group_name = data.azurerm_resource_group.core.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Secrets that can't be replaced by managed identity or OIDC (VPN keys, device certs).
# Access is by Azure RBAC, not vault access policies. Network access is closed until
# a private endpoint is added; the control plane (this resource) is unaffected.
resource "azurerm_key_vault" "main" {
  name                = "kv-chargenet-${local.env}-${substr(data.azurerm_client_config.current.subscription_id, 0, 4)}"
  location            = data.azurerm_resource_group.core.location
  resource_group_name = data.azurerm_resource_group.core.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = var.purge_protection

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = local.tags
}
