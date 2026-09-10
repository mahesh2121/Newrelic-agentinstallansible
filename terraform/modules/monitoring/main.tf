# Monitoring as code. The agents are installed by Ansible; the alerts and
# dashboards that make the data useful are versioned here, right next to the
# infrastructure they observe. Day 26 walks through this module.
locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "newrelic_alert_policy" "this" {
  name   = "${local.name_prefix}-fleet"
  account_id = var.account_id
}

resource "newrelic_alert_destination" "noop" {
  count = length(var.notification_channel_ids) == 0 ? 1 : 0

  name       = "${local.name_prefix}-placeholder"
  account_id = var.account_id
  type       = "EVENT"
  active     = true
}

# Condition 1: an agent stopped reporting. This is the alert that catches the
# failure mode Ansible cannot see - the host is up, the agent is silently dead.
resource "newrelic_nrql_alert_condition" "agent_not_reporting" {
  account_id           = var.account_id
  policy_id            = newrelic_alert_policy.this.id
  type                 = "static"
  name                 = "${local.name_prefix} - agent not reporting"
  description          = "No infrastructure data received from a monitored host"
  critical             = "critical"
  violation_time_limit = "TWENTY_FOUR_HOURS"

  nrql {
    query = <<-NRQL
      SELECT uniqueCount(entity.name) FROM SystemSample
      WHERE (integrationName = 'com.newrelic.infrastructure')
        AND `tags.env` = '${var.environment}'
    NRQL
  }

  term {
    operator              = "below"
    threshold             = 1
    threshold_occurrences = "all"
    duration              = var.agent_not_reporting_minutes
    priority              = "critical"
  }
}

# Condition 2: saturation. The classic "host is alive but unhappy".
resource "newrelic_nrql_alert_condition" "cpu_high" {
  account_id           = var.account_id
  policy_id            = newrelic_alert_policy.this.id
  type                 = "static"
  name                 = "${local.name_prefix} - sustained high CPU"
  description          = "CPU above ${var.cpu_critical_threshold}% for 5 minutes"
  critical             = "critical"
  violation_time_limit = "TWENTY_FOUR_HOURS"

  nrql {
    query = <<-NRQL
      SELECT average(cpuPercent) FROM SystemSample
      WHERE `tags.env` = '${var.environment}'
      FACET entity.name
    NRQL
  }

  term {
    operator              = "above"
    threshold             = var.cpu_critical_threshold
    threshold_occurrences = "all"
    duration              = 5
    priority              = "critical"
  }
}

resource "newrelic_one_dashboard" "fleet" {
  account_id = var.account_id
  name       = "${local.name_prefix} fleet"

  page {
    name = "Overview"

    widget_markdown {
      title  = "Managed by Ansible"
      row    = 1
      column = 1
      width  = 4
      height = 3
      text   = "Hosts in this fleet are provisioned by Terraform and configured by Ansible. Attributes come from `newrelic_infra_labels`."
    }

    widget_nrql {
      title  = "CPU by host"
      row    = 1
      column = 5
      width  = 4
      height = 3

      nrql_query {
        account_ids = [var.account_id]
        query       = "SELECT average(cpuPercent) FROM SystemSample WHERE `tags.env` = '${var.environment}' FACET entity.name TIMESERIES"
      }
    }

    widget_nrql {
      title  = "Memory by host"
      row    = 1
      column = 9
      width  = 4
      height = 3

      nrql_query {
        account_ids = [var.account_id]
        query       = "SELECT average(memoryUsedPercent) FROM StorageSample WHERE `tags.env` = '${var.environment}' FACET entity.name TIMESERIES"
      }
    }

    widget_nrql {
      title  = "Host count"
      row    = 2
      column = 1
      width  = 4
      height = 3

      nrql_query {
        account_ids = [var.account_id]
        query       = "SELECT uniqueCount(entity.name) FROM SystemSample WHERE `tags.env` = '${var.environment}'"
      }
    }
  }
}
