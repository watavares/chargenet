variable "location" {
  description = "The only region resources may be created in."
  type        = string
  default     = "northeurope"
}

variable "budget_email" {
  description = "Where budget alerts are sent. Set via the BUDGET_EMAIL GitHub environment variable."
  type        = string
}

variable "budget_amount" {
  description = "Monthly subscription budget, in the billing currency."
  type        = number
  default     = 20
}
