# Runs the station simulator on a schedule. Not VNet-integrated on purpose: the
# simulator stands in for chargers in the field, which reach IoT Hub over the internet.
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

resource "azurerm_container_app_job" "simulator" {
  name                         = "caj-simulator-${local.env}"
  location                     = data.azurerm_resource_group.core.location
  resource_group_name          = data.azurerm_resource_group.core.name
  container_app_environment_id = azurerm_container_app_environment.main.id

  replica_timeout_in_seconds = 120
  replica_retry_limit        = 0

  schedule_trigger_config {
    cron_expression          = "*/5 * * * *"
    parallelism              = 1
    replica_completion_count = 1
  }

  secret {
    name  = "iothub-connection-string"
    value = azurerm_iothub_shared_access_policy.simulator.primary_connection_string
  }

  template {
    container {
      name   = "simulator"
      image  = var.simulator_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "IOTHUB_CONNECTION_STRING"
        secret_name = "iothub-connection-string"
      }
      env {
        name  = "STATION_COUNT"
        value = tostring(var.station_count)
      }
    }
  }

  tags = local.tags
}
