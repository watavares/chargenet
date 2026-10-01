# Container Apps environment hosting this environment's processor job and API
resource "azurerm_container_app_environment" "main" {
  name                       = "cae-chargenet-${local.env}"
  location                   = data.azurerm_resource_group.core.location
  resource_group_name        = data.azurerm_resource_group.core.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.tags

  # Azure adds this pay-per-use profile by default; declaring it avoids a permanent diff
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}
