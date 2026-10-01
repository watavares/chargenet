# Network dashboard: an Azure Monitor Workbook over StationTelemetry_CL.
# Open it from the `dashboard_url` output, or Azure portal > Monitor > Workbooks.

locals {
  workspace_id = lower(azurerm_log_analytics_workspace.main.id)

  # Latest reading per station; one that stopped reporting shows as Silent
  latest_status = <<-KQL
    StationTelemetry_CL
    | summarize arg_max(TimeGenerated, *) by StationId
    | extend Status = iff(TimeGenerated < ago(20m), "Silent", Status)
  KQL

  # Common settings for every KQL item in the workbook
  kql = {
    version                 = "KqlItem/1.0"
    size                    = 0
    queryType               = 0
    resourceType            = "microsoft.operationalinsights/workspaces"
    crossComponentResources = [local.workspace_id]
  }

  workbook = {
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "header"
        content = {
          json = "## ChargeNet ${local.env}: station network\nLive telemetry from simulated truck charging stations. Status is the latest reading per station; **Silent** means no report for 20+ minutes."
        }
      },
      {
        type = 9
        name = "parameters"
        content = {
          version = "KqlParameterItem/1.0"
          style   = "pills"
          parameters = [{
            id         = "b1f6c0d2-6a3e-4c1e-9a43-1c2d3e4f5a60"
            version    = "KqlParameterItem/1.0"
            name       = "TimeRange"
            label      = "Time range"
            type       = 4
            isRequired = true
            value      = { durationMs = 86400000 }
            typeSettings = {
              allowCustom = true
              selectableValues = [
                { durationMs = 3600000 },
                { durationMs = 14400000 },
                { durationMs = 86400000 },
                { durationMs = 604800000 },
              ]
            }
          }]
        }
      },
      {
        type = 3
        name = "status-tiles"
        content = merge(local.kql, {
          title         = "Network status now"
          query         = "${local.latest_status}| summarize Stations = count() by Status"
          timeContext   = { durationMs = 86400000 }
          visualization = "tiles"
          tileSettings = {
            showBorder   = false
            titleContent = { columnMatch = "Status", formatter = 1 }
            leftContent  = { columnMatch = "Stations", formatter = 12, formatOptions = { palette = "auto" } }
          }
        })
      },
      {
        type = 3
        name = "station-board"
        content = merge(local.kql, {
          title         = "Station board"
          query         = <<-KQL
            ${local.latest_status}| extend Health = case(
                Status == "Faulted", "🔴 Faulted",
                Status == "Silent", "⚫ Silent",
                Status == "Charging", "🔵 Charging",
                "🟢 Available")
            | project Station = StationId, Site = SiteId, Health, PowerKw, ErrorCode, LastSeen = TimeGenerated
            | order by Station asc
          KQL
          timeContext   = { durationMs = 86400000 }
          visualization = "table"
        })
      },
      {
        type        = 3
        name        = "power-per-site"
        customWidth = "50"
        content = merge(local.kql, {
          title                    = "Power drawn per site (MW)"
          query                    = <<-KQL
            StationTelemetry_CL
            | summarize PowerMW = round(sum(PowerKw) / 1000, 2) by SiteId, bin(TimeGenerated, 5m)
          KQL
          timeContextFromParameter = "TimeRange"
          visualization            = "timechart"
        })
      },
      {
        type        = 3
        name        = "energy-per-site"
        customWidth = "50"
        content = merge(local.kql, {
          title                    = "Energy delivered per site (kWh)"
          query                    = <<-KQL
            StationTelemetry_CL
            | summarize EnergyKwh = round(sum(EnergyKwh), 0) by SiteId
            | order by EnergyKwh desc
          KQL
          timeContextFromParameter = "TimeRange"
          visualization            = "barchart"
        })
      },
      {
        type = 3
        name = "fault-history"
        content = merge(local.kql, {
          title                    = "Fault history"
          noDataMessage            = "No faults in this period."
          query                    = <<-KQL
            StationTelemetry_CL
            | where Status == "Faulted"
            | summarize From = min(TimeGenerated), To = max(TimeGenerated), Readings = count()
                by StationId, SiteId, ErrorCode, Incident = bin(TimeGenerated, 1h)
            | project-away Incident
            | order by From desc
          KQL
          timeContextFromParameter = "TimeRange"
          visualization            = "table"
        })
      },
      {
        type        = 3
        name        = "pipeline-throughput"
        customWidth = "50"
        content = merge(local.kql, {
          title                    = "Pipeline: messages per 5 minutes"
          query                    = <<-KQL
            StationTelemetry_CL
            | summarize Messages = count() by bin(TimeGenerated, 5m)
          KQL
          timeContextFromParameter = "TimeRange"
          visualization            = "timechart"
        })
      },
      {
        type        = 3
        name        = "pipeline-latency"
        customWidth = "50"
        content = merge(local.kql, {
          title                    = "Pipeline: station-to-table delay (minutes)"
          query                    = <<-KQL
            StationTelemetry_CL
            | extend DelayMin = (ingestion_time() - TimeGenerated) / 1m
            | summarize Average = round(avg(DelayMin), 1), P95 = round(percentile(DelayMin, 95), 1) by bin(TimeGenerated, 1h)
          KQL
          timeContextFromParameter = "TimeRange"
          visualization            = "timechart"
        })
      },
    ]
    fallbackResourceIds = [local.workspace_id]
  }
}

resource "azurerm_application_insights_workbook" "stations" {
  # Workbook names must be GUIDs; derive a stable one so it never gets recreated
  name                = uuidv5("url", "https://github.com/watavares/chargenet/workbooks/stations-${local.env}")
  resource_group_name = data.azurerm_resource_group.core.name
  location            = data.azurerm_resource_group.core.location
  display_name        = "ChargeNet ${local.env}: station network"
  source_id           = local.workspace_id
  category            = "workbook"
  data_json           = jsonencode(local.workbook)
  tags                = local.tags
}
