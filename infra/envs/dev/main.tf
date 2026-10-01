locals {
  env  = "dev"
  tags = { project = "chargenet", env = local.env, owner = "andre" }
}

resource "azurerm_resource_group" "core" {
  name     = "rg-chargenet-${local.env}"
  location = "northeurope"
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-chargenet-${local.env}"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}
