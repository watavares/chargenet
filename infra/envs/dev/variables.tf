variable "images" {
  description = "Container images by app (simulator, processor, api), set by the pipeline's build job."
  type        = map(string)
}

variable "alert_email" {
  description = "Where station alerts are sent. Set via the ALERT_EMAIL GitHub environment variable."
  type        = string
}

variable "alerts_enabled" {
  description = "Whether station alert rules are active. Only production should page anyone."
  type        = bool
  default     = false
}
