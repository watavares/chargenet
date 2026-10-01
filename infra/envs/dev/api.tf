# Public, read-only status API. Exposure decision: docs/decisions/0001-public-status-api.md

# Vended by infra/platform with Log Analytics Reader on this resource group only
data "azurerm_user_assigned_identity" "api" {
  name                = "id-chargenet-${local.env}-api"
  resource_group_name = data.azurerm_resource_group.core.name
}

resource "azurerm_container_app" "api" {
  name                         = "ca-api-${local.env}"
  resource_group_name          = data.azurerm_resource_group.core.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.api.id]
  }

  ingress {
    external_enabled           = true
    target_port                = 8000
    allow_insecure_connections = false # HTTPS only; plain HTTP is redirected

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Scales to zero when idle (a few seconds' cold start); one replica caps cost
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "api"
      image  = var.images["api"]
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = data.azurerm_user_assigned_identity.api.client_id
      }
      env {
        name  = "WORKSPACE_ID"
        value = azurerm_log_analytics_workspace.main.workspace_id
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/healthz"
      }
    }
  }

  tags = local.tags
}
