variable "env" {
  description = "Environment name (dev, acc, prod). Must match a resource group vended by infra/platform."
  type        = string
}

variable "images" {
  description = "Container images by app; this module uses `processor` and `api`."
  type        = map(string)
}

variable "ingestion" {
  description = "This environment's reader on the shared IoT Hub, from the platform's field_ingestion output."
  type = object({
    connection_string = string
    consumer_group    = string
  })
  sensitive = true
}

variable "alert_email" {
  description = "Where station alerts are sent."
  type        = string
}

variable "alerts_enabled" {
  description = "Whether station alert rules are active. Only production should page anyone."
  type        = bool
  default     = false
}

variable "purge_protection" {
  description = "Key Vault purge protection. On for production; off where environments are torn down and rebuilt."
  type        = bool
  default     = false
}
