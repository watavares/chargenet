# Environment vending: the platform hands each environment a ready-made box.
# The environment's own pipeline deploys workloads into its resource group but
# cannot change the network or anything outside the box.

resource "azurerm_resource_group" "env" {
  for_each = var.environments

  name     = "rg-chargenet-${each.key}"
  location = var.location
  tags     = merge(local.tags, { env = each.key })
}

# rg-chargenet-dev was first created by the dev layer; take it over without recreating it
import {
  to = azurerm_resource_group.env["dev"]
  id = "/subscriptions/4c952ab8-ce51-49fd-a686-de35331d97af/resourceGroups/rg-chargenet-dev"
}

resource "azurerm_role_assignment" "env_deployer" {
  for_each = var.environments

  scope                = azurerm_resource_group.env[each.key].id
  role_definition_name = "Contributor"
  principal_id         = each.value.deployer_object_id
  principal_type       = "ServicePrincipal"
}

# Identity the environment's workloads run as (no secret: Azure issues its tokens).
# Created here because granting it data access needs role-assignment rights
# the environment's own deploy identity deliberately doesn't have.
resource "azurerm_user_assigned_identity" "workload" {
  for_each = var.environments

  name                = "id-chargenet-${each.key}-workload"
  location            = var.location
  resource_group_name = azurerm_resource_group.env[each.key].name
  tags                = merge(local.tags, { env = each.key })
}

locals {
  # Data-plane roles workloads need inside their own resource group only
  workload_roles = {
    for pair in setproduct(keys(var.environments), [
      "Storage Blob Data Contributor", # processor checkpoints
      "Monitoring Metrics Publisher",  # send rows to Log Analytics via the Logs Ingestion API
    ]) : "${pair[0]}/${pair[1]}" => { env = pair[0], role = pair[1] }
  }
}

resource "azurerm_role_assignment" "workload" {
  for_each = local.workload_roles

  scope                = azurerm_resource_group.env[each.value.env].id
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.workload[each.value.env].principal_id
  principal_type       = "ServicePrincipal"
}

# Network lives in its own resource group, out of reach of the environment's identity
resource "azurerm_resource_group" "env_network" {
  for_each = var.environments

  name     = "rg-chargenet-${each.key}-network"
  location = var.location
  tags     = merge(local.tags, { env = each.key })
}

resource "azurerm_virtual_network" "spoke" {
  for_each = var.environments

  name                = "vnet-chargenet-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.env_network[each.key].name
  address_space       = [each.value.address_space]
  tags                = merge(local.tags, { env = each.key })

  depends_on = [azurerm_network_watcher.main]
}

locals {
  # Per environment: container apps need at least a /23; private endpoints get a /24
  subnets = merge([
    for env, cfg in var.environments : {
      "${env}-apps"              = { env = env, name = "snet-apps", prefix = cidrsubnet(cfg.address_space, 7, 0) }
      "${env}-private-endpoints" = { env = env, name = "snet-private-endpoints", prefix = cidrsubnet(cfg.address_space, 8, 2) }
    }
  ]...)
}

resource "azurerm_subnet" "spoke" {
  for_each = local.subnets

  name                 = each.value.name
  resource_group_name  = azurerm_resource_group.env_network[each.value.env].name
  virtual_network_name = azurerm_virtual_network.spoke[each.value.env].name
  address_prefixes     = [each.value.prefix]
}

# One NSG per subnet. Azure's default rules allow VNet-internal traffic and deny
# all other inbound; specific rules get added as workloads arrive.
resource "azurerm_network_security_group" "spoke" {
  for_each = local.subnets

  name                = "nsg-chargenet-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.env_network[each.value.env].name
  tags                = merge(local.tags, { env = each.value.env })
}

resource "azurerm_subnet_network_security_group_association" "spoke" {
  for_each = local.subnets

  subnet_id                 = azurerm_subnet.spoke[each.key].id
  network_security_group_id = azurerm_network_security_group.spoke[each.key].id
}

# Peering has to exist on both sides before traffic flows
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = var.environments

  name                      = "peer-hub-to-${each.key}"
  resource_group_name       = azurerm_resource_group.platform.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke[each.key].id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each = var.environments

  name                      = "peer-${each.key}-to-hub"
  resource_group_name       = azurerm_resource_group.env_network[each.key].name
  virtual_network_name      = azurerm_virtual_network.spoke[each.key].name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}
