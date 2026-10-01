output "hub_vnet_id" {
  description = "Spoke VNets peer to this."
  value       = azurerm_virtual_network.hub.id
}
