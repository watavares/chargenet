variable "location" {
  description = "The only region resources may be created in."
  type        = string
  default     = "northeurope"
}

variable "budget_email" {
  description = "Where budget alerts are sent. Set via the BUDGET_EMAIL GitHub environment variable."
  type        = string
}

variable "environments" {
  description = <<-EOT
    Environments the platform vends: each gets a resource group, a spoke VNet peered
    to the hub, and Contributor on its resource group for its deploy identity.
  EOT
  type = map(object({
    address_space      = string # a /16 per environment
    deployer_object_id = string # object ID of sp-chargenet-github-<env>
  }))
  default = {
    dev = {
      address_space      = "10.1.0.0/16"
      deployer_object_id = "19c1e59a-9717-4fd3-8088-ec55c032cf46"
    }
  }
}

variable "budget_amount" {
  description = "Monthly subscription budget, in the billing currency."
  type        = number
  default     = 20
}
