# Device ingestion: stations connect here over MQTT (TLS, port 8883).
# Free tier: 8,000 messages/day, one per subscription.
resource "azurerm_iothub" "main" {
  name                = "iot-chargenet-${local.env}-${substr(data.azurerm_client_config.current.subscription_id, 0, 4)}"
  location            = data.azurerm_resource_group.core.location
  resource_group_name = data.azurerm_resource_group.core.name

  sku {
    name     = "F1"
    capacity = 1
  }

  # Free tier only allows 2 partitions (the provider defaults to 4)
  event_hub_partition_count = 2

  tags = local.tags
}

# Gateway-style credential for the simulator: may register devices and connect
# as any of them, but can't read or change hub configuration.
resource "azurerm_iothub_shared_access_policy" "simulator" {
  name                = "simulator"
  resource_group_name = data.azurerm_resource_group.core.name
  iothub_name         = azurerm_iothub.main.name

  registry_read  = true
  registry_write = true
  device_connect = true
}
