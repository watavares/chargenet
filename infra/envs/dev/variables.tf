variable "images" {
  description = "Container images by app (simulator, processor, api), set by the pipeline's build job."
  type        = map(string)
}

variable "alert_email" {
  description = "Where station alerts are sent. Set via the ALERT_EMAIL GitHub environment variable."
  type        = string
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
