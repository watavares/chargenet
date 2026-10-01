output "hub_vnet_id" {
  description = "Spoke VNets peer to this."
  value       = azurerm_virtual_network.hub.id
}

# Read by each environment through terraform_remote_state. Sensitive: the state
# file holding it is protected by RBAC on the state storage account.
output "field_ingestion" {
  description = "Per environment: Event Hub-compatible connection string (read-only key) and consumer group."
  sensitive   = true
  value = {
    for env in keys(var.environments) : env => {
      connection_string = join(";", [
        "Endpoint=${azurerm_iothub.field.event_hub_events_endpoint}",
        "SharedAccessKeyName=${azurerm_iothub_shared_access_policy.env[env].name}",
        "SharedAccessKey=${azurerm_iothub_shared_access_policy.env[env].primary_key}",
        "EntityPath=${azurerm_iothub.field.event_hub_events_path}",
      ])
      consumer_group = azurerm_iothub_consumer_group.env[env].name
    }
  }
}
