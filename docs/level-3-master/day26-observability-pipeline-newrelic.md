# Day 26 — Monitoring as Code, and Observability of the Pipeline

**Level 3** · ~2 hours · Prereqs: Day 25

## What you will be able to do

- Define New Relic alerts and dashboards in Terraform
- Close the loop: deploy → marker → dashboards → alert
- Monitor the pipeline itself, not just the hosts
- Query New Relic programmatically to prove data is flowing

## Two things to monitor

1. **The fleet** — the hosts and agents Day 18 installed.
2. **The pipeline** — did the deploy work? Did drift appear? Did the agent install
   succeed on every host?

Most teams do #1 and forget #2. The result: monitoring silently stops being
deployed, and nobody notices until an incident.

## Alerts and dashboards as code

`terraform/modules/monitoring/main.tf` creates:

- an alert policy `${project}-${environment}-fleet`
- **agent-not-reporting** — the alert that catches the failure Ansible cannot see:
  ```
  SELECT uniqueCount(entity.name) FROM SystemSample
  WHERE (integrationName = 'com.newrelic.infrastructure')
    AND `tags.env` = 'dev'
  ```
  `below 1` for 5 minutes → critical.
- **sustained high CPU** — `average(cpuPercent) ... FACET entity.name`
- a dashboard with CPU, memory and host-count widgets

```hcl
resource "newrelic_nrql_alert_condition" "agent_not_reporting" {
  policy_id  = newrelic_alert_policy.this.id
  type       = "static"
  name       = "${local.name_prefix} - agent not reporting"
  critical   = "critical"

  nrql { query = <<-NRQL
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
```

Why in Terraform and not the UI?

- The alert policy exists in **every** environment by construction — no "we forgot
  to set up alerts in staging".
- A PR review catches a threshold change.
- `terraform destroy` on dev cleans up dev's alerts.

The module is optional (`count = var.enable_monitoring_module ? 1 : 0`) so you can
apply the AWS side before you have a New Relic API key.

> **Note:** NRQL entity-attribute names (`tags.env`, `integrationName`) depend on
> your agent version and how attributes are set. Confirm with a query in the UI
> before you rely on a threshold.

## The attributes that make this work

Alerts filter on `tags.env`. Those come from Ansible:

```yaml
# inventory/group_vars/servers.yml
newrelic_infra_labels:
  env: "{{ env_name }}"
  region: "{{ aws_region }}"
  managed_by: ansible
  project: "{{ project }}"
```

and `env_name` came from Terraform (Day 15). **The chain is:**

```
terraform var.environment
  -> output ansible_inventory_json -> env_name host var
  -> group_vars template -> newrelic_infra_labels
  -> /etc/newrelic-infra.yml labels
  -> New Relic tags.env
  -> NRQL WHERE tags.env = 'dev'
```

Break any link and your alerts silently stop matching. That is why the
verification playbook matters.

## Deploy markers

A deployment marker annotates charts so you can see "the error rate rose when
deploy X went out":

```yaml
- name: Register a New Relic deployment marker
  ansible.builtin.uri:
    url: https://api.newrelic.com/v2/applications/{{ nr_app_id }}/deployments.json
    method: POST
    headers:
      X-Api-Key: "{{ newrelic_verify_api_key }}"
    body_format: json
    body:
      deployment:
        revision: "{{ deploy_git_sha }}"
        description: "{{ deploy_description | default('ansible deploy') }}"
    status_code: 201
  delegate_to: localhost
  become: false
  run_once: true
  no_log: true
```

`run_once: true` — one marker per deploy, not one per host.

## Verifying data is arriving (the strongest test)

The NerdGraph API gives you a definitive answer:

```graphql
{
  actor {
    account(id: 1234567) {
      nrql(query: "SELECT latest(timestamp) FROM SystemSample WHERE entity.name = 'my-host' SINCE 10 minutes ago") {
        results
      }
    }
  }
}
```

Empty results → monitoring is broken. This is a far better CI gate than "the
playbook exited 0", and it is the level-4 check from Day 20.

```bash
curl -s https://api.newrelic.com/graphql \
  -H "API-Key: $NEW_RELIC_API_KEY" -H "Content-Type: application/json" \
  -d '{"query":"{ actor { account(id: 1234567) { nrql(query: \"SELECT uniqueCount(entity.name) FROM SystemSample SINCE 10 minutes ago\") { results } } } }"}'
```

## Monitoring the pipeline itself

Ship your CI runs to New Relic as custom events:

```yaml
- name: Report pipeline result to New Relic
  ansible.builtin.uri:
    url: https://insights-collector.newrelic.com/v1/accounts/{{ account_id }}/events
    method: POST
    headers:
      X-Insert-Key: "{{ newrelic_insights_insert_key }}"
      Content-Type: application/json
    body_format: json
    body:
      - eventType: PipelineRun
        repository: "{{ github_repository }}"
        sha: "{{ github_sha }}"
        environment: "{{ env_name }}"
        result: "{{ 'success' if pipeline_failed | default(false) | ternary('failed','success') }}"
        drift_detected: "{{ drift_found | default(false) | bool }}"
        duration_seconds: "{{ pipeline_duration }}"
  delegate_to: localhost
  become: false
  no_log: true
```

Then alert on `SELECT percentage(count(*), WHERE result = 'failed') FROM
PipelineRun` — "deploys are failing more often this week" is a signal you cannot
get from anywhere else.

## Lab 26.1 — read the monitoring module

```bash
cd Newrelic-agentinstallansible
cat terraform/modules/monitoring/main.tf
python3 tools/hcl_parse_check.py terraform/modules/monitoring
```

Real output:

```
ok   terraform/modules/monitoring/main.tf  (5 blocks)
       resource.newrelic_alert_destination, resource.newrelic_alert_policy,
       resource.newrelic_nrql_alert_condition, resource.newrelic_one_dashboard
```

## Lab 26.2 — trace the attribute chain

Prove each link exists in code:

```bash
grep -n "env_name" terraform/environments/dev/outputs.tf
grep -n "newrelic_infra_labels" ansible/inventory/group_vars/servers.yml
grep -n "labels" ansible/roles/newrelic_infra/templates/newrelic-infra.yml.j2
grep -n "tags.env" terraform/modules/monitoring/main.tf
```

Four greps, one chain. If any returns nothing, the chain is broken.

## Lab 26.3 — the deliberate failure: a silently wrong NRQL

Change the alert query's filter to `tags.enviornment = 'dev'` (typo) and think it
through: the query is syntactically valid, the condition is created
successfully, and it **never fires** because no entity has that attribute. Then
consider `below 1` — with a typo, `uniqueCount` is null, and "null below 1" is not
true, so the alert is permanently silent.

This is the most common monitoring-as-code failure: a typo that produces silence,
not an error. Defences:

- Assert on the query result in CI (the NerdGraph call above).
- Add a **dead-man's switch**: an alert that fires when a heartbeat *is* present.
- Periodically review "conditions that have never fired".

## Exercises

1. Add a NRQL condition for memory above 90%.
2. Add a dead-man's-switch condition: alert if `HeartbeatSample` is *missing*.
3. Write a playbook that queries NerdGraph for every host in inventory and fails
   on any host with no data in the last 10 minutes.
4. Add a dashboard widget showing the last deploy time from `PipelineRun` events.

## Gotchas

- `newrelic_one_dashboard` is fully declarative — widgets you add by hand in the
  UI are destroyed on the next apply.
- NRQL alert conditions have rate limits; dozens of conditions per policy can be
  slow to evaluate.
- EU accounts need `region = "EU"` on the provider, or you create resources in
  the wrong account region and see nothing.
- Deployment markers need the numeric **application ID**, not the name.
- Insights insert keys are write-only credentials. Treat them as secrets, but
  note they cannot read your data.

## Check yourself

- [ ] You can trace the attribute chain with four greps
- [ ] You know why a typo in NRQL produces silence rather than an error
- [ ] You can query NerdGraph and interpret empty results

**Next:** [Day 27 — GitOps & Delivery](day27-gitops-and-delivery.md)
