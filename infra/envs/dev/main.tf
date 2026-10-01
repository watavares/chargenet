# Dev environment: the shared environment module with dev's settings.

# This environment's reader on the shared IoT Hub (see ADR 0002)
data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateat1234"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
    use_azuread_auth     = true
  }
}

module "environment" {
  source = "../../modules/environment"

  env              = "dev"
  images           = var.images
  ingestion        = data.terraform_remote_state.platform.outputs.field_ingestion["dev"]
  alert_email      = var.alert_email
  alerts_enabled   = false # only production pages anyone
  purge_protection = false # dev is torn down and rebuilt
}

# Resources created before the module existed: same objects, new addresses.
# Safe to delete these blocks once applied.
moved {
  from = azurerm_log_analytics_workspace.main
  to   = module.environment.azurerm_log_analytics_workspace.main
}
moved {
  from = azurerm_key_vault.main
  to   = module.environment.azurerm_key_vault.main
}
moved {
  from = azurerm_container_app_environment.main
  to   = module.environment.azurerm_container_app_environment.main
}
moved {
  from = azurerm_storage_account.checkpoints
  to   = module.environment.azurerm_storage_account.checkpoints
}
moved {
  from = azurerm_storage_container.checkpoints
  to   = module.environment.azurerm_storage_container.checkpoints
}
moved {
  from = azapi_resource.telemetry_table
  to   = module.environment.azapi_resource.telemetry_table
}
moved {
  from = azurerm_monitor_data_collection_endpoint.main
  to   = module.environment.azurerm_monitor_data_collection_endpoint.main
}
moved {
  from = azurerm_monitor_data_collection_rule.telemetry
  to   = module.environment.azurerm_monitor_data_collection_rule.telemetry
}
moved {
  from = azurerm_monitor_action_group.oncall
  to   = module.environment.azurerm_monitor_action_group.oncall
}
moved {
  from = azurerm_monitor_scheduled_query_rules_alert_v2.station_faulted
  to   = module.environment.azurerm_monitor_scheduled_query_rules_alert_v2.station_faulted
}
moved {
  from = azurerm_monitor_scheduled_query_rules_alert_v2.station_silent
  to   = module.environment.azurerm_monitor_scheduled_query_rules_alert_v2.station_silent
}
moved {
  from = azurerm_application_insights_workbook.stations
  to   = module.environment.azurerm_application_insights_workbook.stations
}
moved {
  from = azurerm_container_app.api
  to   = module.environment.azurerm_container_app.api
}
