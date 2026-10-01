output "status_url" {
  description = "Public status page."
  value       = module.environment.status_url
}

output "dashboard_url" {
  description = "Station network workbook in the Azure portal."
  value       = module.environment.dashboard_url
}
