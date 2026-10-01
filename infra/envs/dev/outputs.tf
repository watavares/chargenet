output "dashboard_url" {
  description = "Station network workbook in the Azure portal."
  value       = "https://portal.azure.com/#@${data.azurerm_client_config.current.tenant_id}/resource${azurerm_application_insights_workbook.stations.id}/workbook"
}
