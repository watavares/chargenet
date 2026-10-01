# The field: one fleet of stations and the single ingestion point they report to.
# Shared by every environment, like DNS. Each environment reads the same message
# stream through its own consumer group and read-only key, so no environment can
# consume or affect another's messages. See docs/decisions/0002-shared-ingestion.md.

resource "azurerm_resource_group" "field" {
  name     = "rg-chargenet-field"
  location = var.location
  tags     = merge(local.tags, { env = "field" })
}

# Free tier: 8,000 messages/day, and only one per subscription
resource "azurerm_iothub" "field" {
  name                = "iot-chargenet-${substr(data.azurerm_subscription.current.subscription_id, 0, 4)}"
  location            = var.location
  resource_group_name = azurerm_resource_group.field.name

  sku {
    name     = "F1"
    capacity = 1
  }

  # Free tier only allows 2 partitions (the provider defaults to 4)
  event_hub_partition_count = 2

  tags = merge(local.tags, { env = "field" })
}

# Per environment: its own read position in the stream, and a key that can
# only read device messages (ServiceConnect)
resource "azurerm_iothub_consumer_group" "env" {
  for_each = var.environments

  name                   = each.key
  iothub_name            = azurerm_iothub.field.name
  eventhub_endpoint_name = "events"
  resource_group_name    = azurerm_resource_group.field.name
}

resource "azurerm_iothub_shared_access_policy" "env" {
  for_each = var.environments

  name                = "reader-${each.key}"
  resource_group_name = azurerm_resource_group.field.name
  iothub_name         = azurerm_iothub.field.name
  service_connect     = true
}

# ---- Station simulator: stands in for chargers on the road ----

resource "azurerm_log_analytics_workspace" "field" {
  name                = "log-chargenet-field"
  location            = var.location
  resource_group_name = azurerm_resource_group.field.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = merge(local.tags, { env = "field" })
}

# Interim: the subscription allows one Container Apps environment per region until
# its quota is raised, and dev's holds it. The simulator runs there meanwhile;
# once the quota allows, it gets its own environment here again
# (cae-chargenet-field, logging to log-chargenet-field).
data "azurerm_container_app_environment" "field" {
  name                = "cae-chargenet-dev"
  resource_group_name = "rg-chargenet-dev"
}

# Gateway-style credential: may register devices and connect as them, but
# can't read or change hub configuration
resource "azurerm_iothub_shared_access_policy" "simulator" {
  name                = "simulator"
  resource_group_name = azurerm_resource_group.field.name
  iothub_name         = azurerm_iothub.field.name

  registry_read  = true
  registry_write = true
  device_connect = true
}

resource "azurerm_container_app_job" "simulator" {
  name                         = "caj-simulator"
  location                     = var.location
  resource_group_name          = azurerm_resource_group.field.name
  container_app_environment_id = data.azurerm_container_app_environment.field.id
  workload_profile_name        = "Consumption"

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
      image  = var.images["simulator"]
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

  tags = merge(local.tags, { env = "field" })
}
