locals {
  tags = { project = "chargenet", env = "platform", owner = "andre" }
}

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "platform" {
  name     = "rg-chargenet-platform"
  location = var.location
  tags     = local.tags
}

# Azure auto-creates this RG and watcher with the first VNet in a region, but
# untagged, which the tag policy would deny. Owning them here keeps them tagged.
resource "azurerm_resource_group" "network_watcher" {
  name     = "NetworkWatcherRG"
  location = var.location
  tags     = local.tags
}

resource "azurerm_network_watcher" "main" {
  name                = "NetworkWatcher_${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network_watcher.name
  tags                = local.tags
}

# Hub of the hub-spoke network: shared connectivity for all environments.
# Each environment's spoke VNet peers to this; the VPN gateway lands here in Phase 3.
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-chargenet-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags

  depends_on = [azurerm_network_watcher.main]
}

# Reserved for the Phase 3 VPN gateway; Azure requires this exact name
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.0.0/27"]
}
