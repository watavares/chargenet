variable "images" {
  description = "Container images by app, set by the pipeline's build job."
  type        = map(string)
}

variable "alert_email" {
  description = "Where station alerts are sent. Set via the ALERT_EMAIL GitHub environment variable."
  type        = string
}
