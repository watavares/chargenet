# Telemetry path: IoT Hub -> processor (scheduled job) -> Log Analytics table.

# Vended by infra/platform with data roles on this resource group
data "azurerm_user_assigned_identity" "workload" {
  name                = "id-chargenet-${local.env}-workload"
  resource_group_name = data.azurerm_resource_group.core.name
}

# The processor's own read position in IoT Hub, independent of any other reader
resource "azurerm_iothub_consumer_group" "processor" {
  name                   = "processor"
  iothub_name            = azurerm_iothub.main.name
  eventhub_endpoint_name = "events"
  resource_group_name    = data.azurerm_resource_group.core.name
}

# Read-only access to device messages (ServiceConnect), nothing else
resource "azurerm_iothub_shared_access_policy" "processor" {
  name                = "processor"
  resource_group_name = data.azurerm_resource_group.core.name
  iothub_name         = azurerm_iothub.main.name
  service_connect     = true
}

# Checkpoints: how far the processor has read in each partition
resource "azurerm_storage_account" "checkpoints" {
  name                     = "stchargenet${local.env}${substr(data.azurerm_client_config.current.subscription_id, 0, 4)}"
  location                 = data.azurerm_resource_group.core.location
  resource_group_name      = data.azurerm_resource_group.core.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  shared_access_key_enabled       = false # Entra ID (managed identity) only
  allow_nested_items_to_be_public = false

  tags = local.tags
}

resource "azurerm_storage_container" "checkpoints" {
  name               = "checkpoints"
  storage_account_id = azurerm_storage_account.checkpoints.id
}

# Custom table the rows land in. Defined with azapi: azurerm can't set a table schema.
resource "azapi_resource" "telemetry_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "StationTelemetry_CL"
  parent_id = azurerm_log_analytics_workspace.main.id

  body = {
    properties = {
      plan            = "Analytics"
      retentionInDays = 30
      schema = {
        name = "StationTelemetry_CL"
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "StationId", type = "string" },
          { name = "SiteId", type = "string" },
          { name = "Status", type = "string" },
          { name = "PowerKw", type = "real" },
          { name = "EnergyKwh", type = "real" },
          { name = "ErrorCode", type = "string" },
          { name = "EnqueuedTime", type = "datetime" },
        ]
      }
    }
  }
}

# Logs Ingestion API: the endpoint the processor posts to, and the rule mapping
# the posted JSON onto the table
resource "azurerm_monitor_data_collection_endpoint" "main" {
  name                = "dce-chargenet-${local.env}"
  location            = data.azurerm_resource_group.core.location
  resource_group_name = data.azurerm_resource_group.core.name
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "telemetry" {
  name                        = "dcr-chargenet-${local.env}-telemetry"
  location                    = data.azurerm_resource_group.core.location
  resource_group_name         = data.azurerm_resource_group.core.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.main.id

  destinations {
    log_analytics {
      name                  = "workspace"
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
    }
  }

  stream_declaration {
    stream_name = "Custom-StationTelemetry"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "StationId"
      type = "string"
    }
    column {
      name = "SiteId"
      type = "string"
    }
    column {
      name = "Status"
      type = "string"
    }
    column {
      name = "PowerKw"
      type = "real"
    }
    column {
      name = "EnergyKwh"
      type = "real"
    }
    column {
      name = "ErrorCode"
      type = "string"
    }
    column {
      name = "EnqueuedTime"
      type = "datetime"
    }
  }

  data_flow {
    streams       = ["Custom-StationTelemetry"]
    destinations  = ["workspace"]
    output_stream = "Custom-StationTelemetry_CL"
    transform_kql = "source"
  }

  tags = local.tags

  depends_on = [azapi_resource.telemetry_table]
}

resource "azurerm_container_app_job" "processor" {
  name                         = "caj-processor-${local.env}"
  location                     = data.azurerm_resource_group.core.location
  resource_group_name          = data.azurerm_resource_group.core.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption"

  replica_timeout_in_seconds = 120
  replica_retry_limit        = 0

  # Two minutes after each simulator run, so fresh messages are picked up promptly
  schedule_trigger_config {
    cron_expression          = "2-59/5 * * * *"
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.workload.id]
  }

  secret {
    name = "eventhub-connection-string"
    value = join(";", [
      "Endpoint=${azurerm_iothub.main.event_hub_events_endpoint}",
      "SharedAccessKeyName=${azurerm_iothub_shared_access_policy.processor.name}",
      "SharedAccessKey=${azurerm_iothub_shared_access_policy.processor.primary_key}",
      "EntityPath=${azurerm_iothub.main.event_hub_events_path}",
    ])
  }

  template {
    container {
      name   = "processor"
      image  = var.images["processor"]
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "EVENTHUB_CONNECTION_STRING"
        secret_name = "eventhub-connection-string"
      }
      env {
        name  = "CONSUMER_GROUP"
        value = azurerm_iothub_consumer_group.processor.name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = data.azurerm_user_assigned_identity.workload.client_id
      }
      env {
        name  = "CHECKPOINT_ACCOUNT_URL"
        value = azurerm_storage_account.checkpoints.primary_blob_endpoint
      }
      env {
        name  = "CHECKPOINT_CONTAINER"
        value = azurerm_storage_container.checkpoints.name
      }
      env {
        name  = "DCE_ENDPOINT"
        value = azurerm_monitor_data_collection_endpoint.main.logs_ingestion_endpoint
      }
      env {
        name  = "DCR_IMMUTABLE_ID"
        value = azurerm_monitor_data_collection_rule.telemetry.immutable_id
      }
      env {
        name  = "DCR_STREAM"
        value = "Custom-StationTelemetry"
      }
    }
  }

  tags = local.tags
}
