# Guardrails enforced on the whole subscription, using Azure's built-in policies.
# Effect is Deny: non-compliant creates and updates are rejected up front.

data "azurerm_policy_definition" "allowed_locations" {
  display_name = "Allowed locations"
}

data "azurerm_policy_definition" "allowed_locations_rg" {
  display_name = "Allowed locations for resource groups"
}

data "azurerm_policy_definition" "require_tag_rg" {
  display_name = "Require a tag on resource groups"
}

data "azurerm_policy_definition" "not_allowed_types" {
  display_name = "Not allowed resource types"
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Resources only in ${var.location}"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = data.azurerm_policy_definition.allowed_locations.id
  parameters           = jsonencode({ listOfAllowedLocations = { value = [var.location] } })
}

resource "azurerm_subscription_policy_assignment" "allowed_locations_rg" {
  name                 = "allowed-locations-rg"
  display_name         = "Resource groups only in ${var.location}"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = data.azurerm_policy_definition.allowed_locations_rg.id
  parameters           = jsonencode({ listOfAllowedLocations = { value = [var.location] } })
}

# Tags drive cost reporting per project and environment
resource "azurerm_subscription_policy_assignment" "require_tag_rg" {
  for_each = toset(["project", "env"])

  name                 = "require-tag-rg-${each.key}"
  display_name         = "Resource groups must have a '${each.key}' tag"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = data.azurerm_policy_definition.require_tag_rg.id
  parameters           = jsonencode({ tagName = { value = each.key } })
}

# Nothing gets exposed to the internet by accident. The Phase 3 VPN gateway
# will need a policy exemption for its public IP.
resource "azurerm_subscription_policy_assignment" "deny_public_ip" {
  name                 = "deny-public-ip"
  display_name         = "No public IP addresses"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = data.azurerm_policy_definition.not_allowed_types.id
  parameters = jsonencode({
    listOfResourceTypesNotAllowed = { value = ["Microsoft.Network/publicIPAddresses"] }
  })
}
