# Day 36 — Cost, Budgets and Governance

**Level 3+ (AWS CloudOps)** · ~90 min · Prereqs: Day 35

Day 28 covered cost *tags*. This day covers the other 90%: knowing what this
stack actually costs, which knob moves the number most, and how you find out
before the bill does.

## What you will be able to do

- Name the six cost drivers in this stack and rank them
- Explain the single highest-leverage variable in the repository
- Set budgets and alerts that fire before the month ends
- Find unallocated spend caused by a tag that was never activated
- Reason about the cost of observability itself

## What this stack costs, in order

Using the dev defaults in `terraform/environments/dev/variables.tf`
(`t3.micro`, `min_size = 1`, `max_size = 3`, `desired_capacity = 2`):

| # | Driver | Where it is set | Rough behaviour |
| --- | --- | --- | --- |
| 1 | **NAT gateway** | `single_nat_gateway` in `terraform/modules/network/variables.tf` | Hourly charge per gateway **plus** per-GB processed. Usually the largest non-compute line in a small stack. |
| 2 | **ALB** | `aws_lb.this` in `terraform/modules/compute/main.tf` | Hourly plus LCU. Does not go to zero when idle. |
| 3 | **EC2** | `var.instance_type`, ASG sizes | Proportional to fleet size; the only line that scales down cleanly. |
| 4 | **CloudWatch Logs** | `var.flow_log_retention_days` (default **365**) | Ingestion plus storage, and storage is charged for the whole retention period. |
| 5 | **S3** | ALB access logs, `var.alb_access_log_retention_days` | Small, but grows without the lifecycle rule. |
| 6 | **Public IPv4 / EIP** | `aws_eip.nat`, the bastion | Per-address hourly. Adds up across environments. |

Two of those are decisions already made for you in this repo, and both are worth
knowing about:

```hcl
# terraform/environments/dev/main.tf
module "network" {
  enable_nat_gateway = true
  single_nat_gateway = var.environment != "prod"
}
```

Read that carefully: **only `prod` gets a NAT gateway per AZ.** `dev` and
`staging` share one. That single expression is the difference between a dev
environment you can leave running and one you cannot. It is also a real
availability trade-off — one NAT means one AZ failure takes outbound traffic
with it — and for dev that is the right trade.

The second:

```hcl
# terraform/modules/network/variables.tf
variable "flow_log_retention_days" {
  description = "CloudWatch retention for flow logs. 365 satisfies CKV_AWS_338."
  type        = number
  default     = 365
}
```

365 days satisfies the policy check. It is also, for most teams, far more flow
log history than anyone has ever queried. The correct answer is not to disable
flow logs — Day 34 showed what they are worth during an incident — it is to make
retention an explicit, reviewed number per environment: 30 days in dev, 365 in
prod, and a sentence in the PR explaining why.

## Deliberate failure — the tag that does nothing

You have done everything right. `common_tags` carries `CostCenter` and `Owner`,
set from `var.cost_center` and `var.owner` in
`terraform/environments/dev/main.tf`, and the ASG propagates them to instances:

```hcl
dynamic "tag" {
  for_each = merge(local.common_tags, {
    Name            = "${local.name_prefix}-app"
    ansible_managed = "true"
  })
  content {
    key                 = tag.key
    value               = tag.value
    propagate_at_launch = true
  }
}
```

You open Cost Explorer, group by `CostCenter`, and get one enormous bar labelled
**"Not allocated"** next to a tiny bar for `sre-001`.

**Diagnosis.** Tags exist on resources the moment you apply them. They do not
appear in **cost reports** until you activate them as *cost allocation tags* in
the Billing console — a separate, manual, account-level step that Terraform
cannot do for you. Until then the data is collected and unused.

Two secondary causes produce the same picture:

- **Timing.** Cost allocation tags apply from the activation date **forward**.
  Historical spend is not retro-tagged, so the first month always looks wrong.
- **Coverage.** Tags reach EC2 and the ASG. They do not automatically reach
  every line item — some managed services do not support tagging at all, and
  account-level charges never will.

**Fix.** Activate the tag, then verify coverage rather than assuming it:

- Group by `CostCenter` and check the *percentage* allocated, not just the bars.
- Any service that cannot be tagged needs an account- or environment-level
  split instead.

**Prevention.** Add "activate cost allocation tags" to the environment bootstrap
checklist, next to "enable Security Hub" and "set the budget". It belongs in the
same list because it is the same class of thing: an account-level setting that
Terraform in this repo does not manage, and therefore nobody owns.

## Governance: budgets, anomalies and the human in the loop

A budget without an alert is a spreadsheet. Three tiers, cheapest first:

1. **Cost budget** with a forecast alert at 80% of the monthly figure. This is
   the one that catches "someone left the prod stack running".
2. **Anomaly detection** on the account. Catches the shape of a problem — a
   steady line that suddenly steps up — before any threshold is crossed.
3. **Usage budget** on the specific line that worries you. Here, that is
   CloudWatch Logs ingestion, because it scales with traffic you do not control.

Route all three to the same place the New Relic alerts go. An alert that lands
somewhere nobody reads is a cost, not a control.

### The governance questions this stack forces

| Question | Where the answer lives |
| --- | --- |
| Who owns this spend? | `var.owner`, `var.cost_center` in `terraform/environments/dev/variables.tf` |
| Which environment is this? | `var.environment`, also the ASG tag and the `tags.env` label |
| Is this host managed? | The `ansible_managed = "true"` tag, propagated at launch |
| Why does staging cost more than dev? | `terraform/environments/staging/main.tf` — `t3.small`, `min_size = 2` |

That last row is the one to notice: **staging is deliberately bigger than dev**,
and the file says so. When cost questions come in, the answer is a commit, not a
memory.

## The cost of observability

Monitoring is not free, and it is the line item teams forget to govern:

- **Agent verbosity.** `newrelic_verbosity: 0` and
  `newrelic_infra_log_level: info` in
  `ansible/inventory/group_vars/all.yml` and
  `ansible/roles/newrelic_infra/defaults/main.yml`. Turning verbosity to 3 during
  a debug session multiplies log volume. Turn it back; make that a task in the
  incident runbook (Day 37).
- **Attribute cardinality.** Every key in `newrelic_infra_labels` becomes a
  queryable attribute on every sample. Four stable labels (`env`, `region`,
  `managed_by`, `project`) are cheap. A request ID is not a label.
- **Dashboard widgets.** `newrelic_one_dashboard.fleet` runs four queries on
  every page load, per viewer. Dashboards nobody closes are a real bill.
- **NRQL alert conditions.** Each condition is evaluated continuously. Dozens per
  policy get slow, and slow conditions mean slow alerts.

## Lab (no AWS account required)

1. List the cost-relevant variables and their defaults in one view:

   ```bash
   grep -n -A4 'variable "instance_type"\|variable "min_size"\|variable "max_size"\|variable "desired_capacity"\|variable "cost_center"\|variable "owner"' \
     terraform/environments/dev/variables.tf
   ```

2. Confirm the NAT decision and which environments it applies to:

   ```bash
   grep -n -B2 -A2 'single_nat_gateway' terraform/environments/dev/main.tf
   grep -n 'environment' terraform/environments/staging/main.tf | head -3
   ```

3. See the tag propagation that cost reporting depends on:

   ```bash
   grep -n -A12 'dynamic "tag"' terraform/modules/compute/main.tf
   ```

4. Compare dev and staging sizing, and say which one should cost more:

   ```bash
   diff <(grep -n 'instance_type\|_size' terraform/environments/dev/variables.tf) \
        <(grep -n 'instance_type\|_size' terraform/environments/staging/main.tf)
   ```

## Exercises

1. Set `flow_log_retention_days` per environment and defend each number in the
   PR description.
2. Add a budget with a forecast alert and route it to the same channel as the
   `agent_not_reporting` condition.
3. Write the "activate cost allocation tags" step into the environment bootstrap
   checklist, with the person who owns it named.
4. Estimate this stack's monthly cost from the resource list, then compare
   against a real bill and explain every difference over 20%.

## Gotchas

- A stopped instance still costs money for its EBS volumes and any attached
  Elastic IP. "Terminate" and "stop" are not synonyms.
- `ignore_changes = [desired_capacity]` on the ASG means a scale-up someone did
  by hand survives every `terraform apply`. That is correct behaviour and a
  standing cost surprise.
- Snapshots and AMIs are invisible in a resource list and visible on a bill.
- Cross-AZ data transfer between the ALB and the app tier is billed. It is small
  per GB and relentless.
- A dev environment that is never destroyed is the most common source of
  unexplained spend. Terraform makes teardown one command; nothing makes you run
  it.
- Destroying an environment does not delete the S3 buckets holding logs if they
  have a deletion blocker, and it does not delete the CloudWatch log groups'
  historical cost.

## Check yourself

- [ ] You can rank the six cost drivers and say which variable controls the top one
- [ ] You know why a correctly tagged resource can still show as unallocated
- [ ] You can name the three budget tiers and what each catches
- [ ] You know which observability settings are currently cheap, and which knob makes them expensive

**Next:** [Day 37 — Compliance, Incidents and the CloudOps Capstone](day37-compliance-incidents-and-cloudops-capstone.md)
