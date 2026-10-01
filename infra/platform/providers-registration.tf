# Resource providers environments need. Environment identities only have rights
# on their resource group, so registering at subscription level happens here.
resource "azurerm_resource_provider_registration" "container_apps" {
  name = "Microsoft.App"
}
