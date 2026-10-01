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

variable "images" {
  description = "Container images by app, set by the pipeline's build job. Platform uses `simulator`."
  type        = map(string)
}

variable "station_count" {
  description = "Simulated stations. Each sends one message per run (every 5 minutes)."
  type        = number
  default     = 10

  # IoT Hub Free tier allows 8,000 messages/day: 288 runs/day x 27 stations is the ceiling
  validation {
    condition     = var.station_count >= 1 && var.station_count <= 25
    error_message = "Keep station_count between 1 and 25 to stay within the IoT Hub Free tier."
  }
}

variable "budget_amount" {
  description = "Monthly subscription budget, in the billing currency."
  type        = number
  default     = 20
}
