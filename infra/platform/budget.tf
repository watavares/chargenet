# Email alerts as spend approaches the monthly budget. Alerts only: Azure
# budgets never stop or delete resources.
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-chargenet-monthly"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = "2026-10-01T00:00:00Z"
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      threshold      = notification.value
      threshold_type = "Actual"
      operator       = "GreaterThanOrEqualTo"
      contact_emails = [var.budget_email]
    }
  }

  # Early warning: projected to exceed the budget by month end
  notification {
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThanOrEqualTo"
    contact_emails = [var.budget_email]
  }
}
