# Day 34 — CloudWatch, Flow Logs and New Relic Correlation

**Level 3+ (AWS CloudOps)** · ~2 hours · Prereqs: Day 33

You now have three separate places where the truth lives: **New Relic** (how the
hosts feel), **CloudWatch** (what the network and the load balancer did), and
**Terraform state** (what exists). An incident is almost always the work of
joining them. This day builds the join.

## What you will be able to do

- Trace one attribute from a Terraform variable to an NRQL `WHERE` clause
- Go from a New Relic alert to the exact instance and the exact flow-log record
- Use `instance_id` as the join key between the two systems
- Explain what a `REJECT` in a flow log means and what it does not mean
- Spot the tag mismatch that produces a permanently critical alert

## The telemetry this stack already ships

| Source | Resource | Where |
| --- | --- | --- |
| VPC flow logs | `aws_flow_log.this` (`traffic_type = "ALL"`) | `terraform/modules/network/main.tf` |
| Flow log destination | `aws_cloudwatch_log_group.flow_log` → `/aws/vpc/<project>-<env>-flow-logs` | same |
| Flow log encryption | `aws_kms_key.logs`, rotation enabled, explicit key policy | same |
| Flow log delivery identity | `aws_iam_role.flow_log` + `aws_iam_role_policy.flow_log` | same |
| ALB access logs | `aws_s3_bucket.alb_logs` + versioning, encryption, lifecycle | `terraform/modules/compute/main.tf` |
| Host metrics + alerts | `newrelic_nrql_alert_condition.agent_not_reporting`, `cpu_high` | `terraform/modules/monitoring/main.tf` |
| Fleet dashboard | `newrelic_one_dashboard.fleet` | same |

Both flow logs and the monitoring module are switchable:
`var.enable_flow_logs` (default `true`) and
`var.enable_monitoring_module` on the `module "monitoring"` block in
`terraform/environments/dev/main.tf`. Know which of your environments have them
off — a dashboard you assume exists and cannot find costs you ten minutes during
an incident.

## The attribute chain, end to end

The NRQL conditions filter on `` `tags.env` ``. Where does that come from? Four
hops, each one a real file in this repository:

```bash
# 1. Terraform emits env_name as a host variable (not `environment` — reserved keyword)
grep -n "env_name" terraform/environments/dev/outputs.tf

# 2. group_vars turns the host variable into an agent label
grep -n -A5 "newrelic_infra_labels" ansible/inventory/group_vars/servers.yml

# 3. the role renders it into the agent config
grep -n -B2 -A4 "labels:" ansible/roles/newrelic_infra/templates/newrelic-infra.yml.j2

# 4. the alert condition filters on it
grep -n "tags.env" terraform/modules/monitoring/main.tf
```

Written out:

```
terraform/environments/dev/outputs.tf      env_name = var.environment
        ↓  (host variable in the generated inventory)
ansible/inventory/group_vars/servers.yml   newrelic_infra_labels: { env: "{{ env_name }}" }
        ↓  (rendered by the role)
/etc/newrelic-infra.yml                    labels: { env: "dev" }
        ↓  (agent reports it)
New Relic                                  tags.env = "dev"
        ↓  (queried by)
terraform/modules/monitoring/main.tf       WHERE `tags.env` = 'dev'
```

**Every hop is a place the chain can break, and none of them are checked by the
same tool.** Terraform validates HCL, Ansible validates YAML, and only a live
query proves the two agree. That is the central observability problem of a
two-tool platform, and it is why this day exists.

## Deliberate failure — the alert that never stops firing

`agent_not_reporting` is defined as:

```hcl
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
```

It is a **missing-data** alert: it fires when the count drops below one. That is
the right design — it catches the host that is up, reachable and silently
unmonitored, which is the failure Ansible cannot see.

Now break it. Deploy a host that lands in the inventory **without** the `servers`
group — a hand-written inventory entry, or a host you added to a different
group. `ansible/inventory/group_vars/servers.yml` never applies, so
`newrelic_infra_labels` is never set, so the agent reports no `env` attribute,
so `` tags.env = 'dev' `` matches nothing.

Symptom: the count is 0, the condition is permanently violated, and you have a
critical alert that fires every evaluation period, forever, on a fleet that is
perfectly healthy.

**Why this is the expensive one.** A permanently firing alert is worse than no
alert. Within a week, everyone has muted the policy, and the *real*
"agent not reporting" event goes into the same muted channel.

**Diagnosis.** Work the chain backwards, one hop at a time:

```bash
# does the agent config on the host actually carry the label?
ansible servers -m slurp -a "src=/etc/newrelic-infra.yml" --limit <host> \
  | base64 -d | grep -A4 labels

# does New Relic see ANY host with that tag?
#   SELECT uniqueCount(entity.name) FROM SystemSample
#   WHERE integrationName = 'com.newrelic.infrastructure' FACET `tags.env`
```

That last query is the one to memorise: **`FACET` on the tag you filter on.** If
the facet returns values but not yours, it is a tag problem, not an agent
problem. If the facet returns nothing at all, it is an agent or license key
problem.

**Fix.** Put the host in the `servers` group so `group_vars` applies, re-run
`ansible-playbook playbooks/newrelic.yml --limit <host>`, and confirm with
`ansible-playbook playbooks/verify.yml --limit <host>`.

**Prevention.** Add an assertion that runs in the pipeline, not in your head —
every host in the generated inventory must be a member of `servers`, and the
rendered agent config must contain an `env` label. Two greps, run after
`terraform/scripts/tf_to_inventory.py`.

## Joining the two systems

The generated inventory carries `instance_id` and `availability_zone` per host —
both come from the `app_hosts` map in
`terraform/environments/dev/outputs.tf`. That is your join key.

New Relic alert: *"host `newrelic-fleet-dev-app-3f9c21` stopped reporting at
14:07."*

```bash
# 1. host variable -> instance id
ansible newrelic-fleet-dev-app-3f9c21 -m debug -a "var=instance_id"

# 2. instance id -> ENI / private IP
aws ec2 describe-instances --instance-ids i-0abc123 \
  --query 'Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddress'

# 3. ENI -> flow logs, in CloudWatch Logs Insights
```

```sql
fields @timestamp, srcAddr, dstAddr, dstPort, action, logStatus
| filter (srcAddr = '10.0.1.23' or dstAddr = '10.0.1.23')
| sort @timestamp desc
| limit 100
```

Run that against the log group named by the `flow_log_group_name` output in
`terraform/environments/dev/outputs.tf`.

Reading the result:

| `action` | What it means | What it does **not** mean |
| --- | --- | --- |
| `ACCEPT` | A security group and NACL allowed it | That the connection succeeded at the application layer |
| `REJECT` | A security group refused it | Which rule did it — flow logs do not carry rule IDs. Compare against `terraform/modules/security/main.tf` by port and direction. |

For the agent specifically, the relevant flow is **outbound 443**, which
`aws_vpc_security_group_egress_rule.app_https_out` in
`terraform/modules/security/main.tf` allows. Nothing inbound is opened for
monitoring — that is the sentence you give security review.

If agent traffic is missing from the flow logs entirely while other egress
appears, suspect the route, not the agent: private subnets egress through
`aws_nat_gateway.this`, and the NAT public IPs are exported as
`nat_gateway_public_ips` in `terraform/environments/dev/outputs.tf` — allowlist
those in New Relic if you ever lock down ingest.

## ALB access logs: the third witness

`aws_s3_bucket.alb_logs` in `terraform/modules/compute/main.tf` collects load
balancer access logs, with a lifecycle rule so they expire. Use them when the
question is "did the request arrive, and what did we answer?" — a question
neither flow logs nor New Relic can answer precisely.

The three-way split is worth memorising:

- **New Relic** — how the host and application *felt*.
- **Flow logs** — what the network *permitted*.
- **ALB access logs** — what the client *received*.

## Lab (no AWS account required)

1. Prove the attribute chain with the four greps at the top of this page. Each
   must return something.

2. Render the agent config the lab produces and inspect the labels:

   ```bash
   bash labs/local/mock_bridge.sh
   ```

   The script parses the rendered file with a YAML loader — the same assertion
   that caught the invalid-YAML bug recorded in `docs/VERIFICATION.md`.

3. Run the fleet verification against the lab group:

   ```bash
   cd ansible && ansible-playbook playbooks/verify.yml --limit lab
   ```

4. Confirm the flow log group name is exported:

   ```bash
   grep -n -A3 'output "flow_log_group_name"' terraform/environments/dev/outputs.tf
   ```

## Exercises

1. Add the two pipeline assertions from the prevention step, and make them fail
   loudly.
2. Add a dead-man's-switch condition: alert when a heartbeat **is** present and
   stops, so a missing-data alert cannot silently become a permanent one.
3. Write a CloudWatch Logs Insights query that finds every `REJECT` on port 443
   in the last hour, and decide whether it belongs in a dashboard or an alert.
4. Add an `availability_zone` widget to `newrelic_one_dashboard.fleet` so you can
   see an AZ imbalance during an incident.

## Gotchas

- `newrelic_one_dashboard` is fully declarative: widgets added by hand in the UI
  are destroyed on the next apply.
- A typo in NRQL produces **silence**, not an error. Test every query in the UI
  before you put it in Terraform.
- The role renders `labels:` — the legacy spelling — alongside
  `custom_attributes`. The template comment says to remove it once the migration
  is complete. Until then, both exist and dashboards may depend on either.
- Flow logs are sampled/aggregated per interval; you will not see one record per
  packet. `logStatus = SKIPDATA` or `NODATA` in the results is normal and means
  exactly what it says.
- CloudWatch Logs retention here defaults to 365 days
  (`var.flow_log_retention_days`). That satisfies the policy check and is
  expensive. Day 36 makes it a budget decision rather than a default.
- An EU New Relic account needs `region = "EU"` on the provider and a matching
  `newrelic_account_region` in `ansible/inventory/group_vars/all.yml`. Mismatched
  regions produce two empty systems and no error.

## Check yourself

- [ ] You can name the four hops of the attribute chain and the file for each
- [ ] You know the one NRQL query that separates a tag problem from an agent problem
- [ ] You can go from an alert to a flow-log record in under five minutes
- [ ] You can explain why a permanently firing alert is worse than none

**Next:** [Day 35 — Patching, Maintenance Windows and Change Control](day35-patching-maintenance-and-change-control.md)
