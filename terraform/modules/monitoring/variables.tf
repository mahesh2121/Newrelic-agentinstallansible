variable "project" {
  description = "Project name, used to name the alert policy and dashboard."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "account_id" {
  description = "New Relic account ID that owns the policy and dashboard."
  type        = number
}

variable "notification_channel_ids" {
  description = "Destination IDs (Slack, PagerDuty, email) for the alert policy."
  type        = list(number)
  default     = []
}

variable "cpu_critical_threshold" {
  description = "CPU percent that triggers a critical alert."
  type        = number
  default     = 90
}

variable "agent_not_reporting_minutes" {
  description = "Minutes without agent data before alerting."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Free-form tags rendered into the dashboard metadata."
  type        = map(string)
  default     = {}
}
