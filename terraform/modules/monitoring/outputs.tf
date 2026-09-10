output "alert_policy_id" {
  description = "ID of the New Relic alert policy."
  value       = newrelic_alert_policy.this.id
}

output "dashboard_guid" {
  description = "GUID of the generated fleet dashboard."
  value       = newrelic_one_dashboard.fleet.guid
}
