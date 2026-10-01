# Telemetry store: checkpoint storage, the Log Analytics table, and the Logs
# Ingestion API endpoint and rule the processor writes through.
# The processor job itself returns once ingestion moves to the shared field layer.

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
