# Station alerts: KQL queries over StationTelemetry_CL, evaluated every 15 minutes.
# One alert per station (dimension on StationId); each resolves itself when the
# station recovers. Only production pages anyone; elsewhere the rules exist but
# are disabled (disabled rules aren't billed).

resource "azurerm_monitor_action_group" "oncall" {
  name                = "ag-chargenet-${local.env}"
  resource_group_name = data.azurerm_resource_group.core.name
  short_name          = "chargenet"

  email_receiver {
    name                    = "oncall"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  tags = local.tags
}

# Every reading in the last 20 minutes (at least two) says Faulted
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "station_faulted" {
  name                 = "alert-chargenet-${local.env}-station-faulted"
  display_name         = "Station faulted"
  description          = "A charging station has reported Faulted continuously for 15+ minutes."
  resource_group_name  = data.azurerm_resource_group.core.name
  location             = data.azurerm_resource_group.core.location
  scopes               = [azurerm_log_analytics_workspace.main.id]
  severity             = 1
  enabled              = var.alerts_enabled
  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"

  criteria {
    query                   = <<-KQL
      StationTelemetry_CL
      | where TimeGenerated > ago(20m)
      | summarize Readings = count(), Faulted = countif(Status == "Faulted"), ErrorCode = take_any(ErrorCode) by StationId, SiteId
      | where Readings >= 2 and Faulted == Readings
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    dimension {
      name     = "StationId"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.oncall.id]
  }

  tags = local.tags

  depends_on = [azapi_resource.telemetry_table]
}

# Seen in the last day, but nothing for 20 minutes (5-minute cadence plus
# processing and ingestion delay). Also fires for every station if the
# simulator or processor stops, which is the point.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "station_silent" {
  name                 = "alert-chargenet-${local.env}-station-silent"
  display_name         = "Station silent"
  description          = "A charging station that was reporting has sent nothing for 20+ minutes."
  resource_group_name  = data.azurerm_resource_group.core.name
  location             = data.azurerm_resource_group.core.location
  scopes               = [azurerm_log_analytics_workspace.main.id]
  severity             = 2
  enabled              = var.alerts_enabled
  evaluation_frequency = "PT15M"
  window_duration      = "P1D"

  criteria {
    query                   = <<-KQL
      StationTelemetry_CL
      | summarize LastSeen = max(TimeGenerated) by StationId, SiteId
      | where LastSeen < ago(20m)
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    dimension {
      name     = "StationId"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.oncall.id]
  }

  tags = local.tags

  depends_on = [azapi_resource.telemetry_table]
}
