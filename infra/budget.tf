# -----------------------------------------------------------------------------
# Monthly cost guardrail
# -----------------------------------------------------------------------------
# Created only when a destination email exists — a budget with no subscriber is
# just a silent no-op resource. Note that budget notifications send a
# confirmation-free SNS-less email straight from AWS Budgets; nothing to accept.
#
# This covers AWS spend only (EC2 + EBS). OpenRouter token spend is tracked
# separately from the per-run NDJSON cost field (`openbuilder cost`).
# -----------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  count = var.enable_budget && var.budget_alert_email != "" ? 1 : 0

  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-monthly-budget"
  })
}
