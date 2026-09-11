# Day 11 — Terraform Modules

**Level 2** · ~90 min · Prereqs: Day 10

## What you will be able to do

- Design a module's interface (inputs, outputs, version)
- Use `for_each` correctly and avoid the count-index trap
- Wire modules together in an environment root
- Decide when a module is *not* the right answer

## Why modules

Copy-pasting a VPC into three environments guarantees three *different* VPCs
within a month. A module gives you one implementation and three sets of values.

This repository has four:

```
terraform/modules/
├── network/      VPC, subnets, IGW, NAT, route tables, flow logs, default SG
├── security/     bastion / app / ALB security groups and their rules
├── compute/      key pair, IAM, launch template, ASG, ALB, bastion
└── monitoring/   New Relic alert policy, NRQL conditions, dashboard
```

## A module's contract

### Inputs — typed, described, defaulted

```hcl
variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}
```

Rules:

- **Every** variable has `description` and `type`. Non-negotiable.
- Defaults are for things you would accept unchanged. A required variable has no
  `default` — Terraform then prompts/errors, which is what you want.
- Validate at the boundary:
  ```hcl
  validation {
    condition     = contains(["US", "EU"], var.newrelic_region)
    error_message = "newrelic_region must be US or EU."
  }
  ```

### Outputs — deliberate and documented

Outputs are the module's public API. `terraform/modules/network/outputs.tf`
exports `vpc_id`, subnet ID maps keyed by AZ, and NAT egress IPs. Note that last
one: **the egress IPs are what you allowlist in New Relic**, so exporting them
saves an hour of debugging later.

### Versions

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
```

Every module in this repo has `versions.tf`. Constraints belong in the module,
not only in the root — otherwise a consumer with an incompatible provider gets a
confusing failure at apply time.

## The `for_each` lesson that matters

`terraform/modules/network/main.tf`:

```hcl
public_subnets = {
  for idx, az in var.availability_zones : az => var.public_subnet_cidrs[idx]
}

resource "aws_subnet" "public" {
  for_each   = local.public_subnets
  cidr_block = each.value
  availability_zone = each.key
}
```

`for_each` is keyed by the **AZ name**, not by an index. Consequences:

- Add a third AZ → only new resources are created.
- Remove the *first* AZ → only that AZ's resources are destroyed.

With `count`, the resource addresses are `aws_subnet.public[0]`, `[1]`, `[2]`.
Removing the first element shifts every index and Terraform proposes to **destroy
and recreate** the remaining subnets. On a real VPC, that is an outage.

Rule: **`count` for "how many", `for_each` for "which ones".** If the set has
meaningful names, use `for_each`.

## Wiring modules in an environment root

`terraform/environments/dev/main.tf` is thin on purpose:

```hcl
module "network" {
  source      = "../../modules/network"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  ...
}

module "security" {
  source = "../../modules/security"
  vpc_id = module.network.vpc_id            # module -> module wiring
  ...
}

module "compute" {
  source                  = "../../modules/compute"
  subnet_ids              = values(module.network.private_subnet_ids)
  alb_subnet_ids          = values(module.network.public_subnet_ids)
  security_group_ids      = [module.security.app_security_group_id]
  alb_security_group_id   = module.security.alb_security_group_id
  bastion_subnet_id       = values(module.network.public_subnet_ids)[0]
  ...
}

module "monitoring" {
  source = "../../modules/monitoring"
  count  = var.enable_monitoring_module ? 1 : 0     # optional module
  ...
}
```

Two patterns worth stealing:

1. **Optional module via `count`.** You can `apply` the AWS side before you have
   a New Relic API key.
2. **No logic in the root.** If you find yourself writing a `locals` block with
   business rules in the root module, that logic belongs in a module.

## When *not* to build a module

- It is used once and will stay used once.
- The wrapper adds variables without adding decisions (the "pass-through module"
  anti-pattern: 20 variables that are each just handed to the provider).
- You are abstracting before you have three real cases. Abstraction guessed too
  early is worse than duplication.

A good heuristic: **write it twice, extract on the third.**

## Lab 11.1 — read the interfaces

```bash
cd Newrelic-agentinstallansible
for m in network security compute monitoring; do
  echo "=== $m ==="
  grep -c "^variable" terraform/modules/$m/variables.tf
  grep "^output" terraform/modules/$m/outputs.tf
done
```

Count inputs and list outputs for each. That is the module's surface area; keep
it as small as you can.

## Lab 11.2 — verify structure

```bash
python3 tools/hcl_parse_check.py terraform/modules
```

Real output includes:

```
ok   terraform/modules/network/main.tf  (15 blocks)
       resource.aws_cloudwatch_log_group, resource.aws_default_security_group,
       resource.aws_eip, resource.aws_flow_log, resource.aws_iam_role,
       resource.aws_iam_role_policy, resource.aws_internet_gateway,
       resource.aws_nat_gateway, resource.aws_route_table,
       resource.aws_route_table_association, resource.aws_subnet, resource.aws_vpc
ok   terraform/modules/monitoring/main.tf  (5 blocks)
       resource.newrelic_alert_destination, resource.newrelic_alert_policy,
       resource.newrelic_nrql_alert_condition, resource.newrelic_one_dashboard
HCL PARSE OK: 21 file(s), 221 declared block(s)
```

## Lab 11.3 — the deliberate failure

Change `for_each` to `count` in `aws_subnet.public` and watch what happens to the
addresses:

```hcl
resource "aws_subnet" "public" {
  count      = length(var.public_subnet_cidrs)
  cidr_block = var.public_subnet_cidrs[count.index]
}
```

Then `terraform plan` after removing the first AZ: every remaining subnet shows
`-/+ destroy and then create replacement`. Revert. On a real VPC you just
practised an outage without touching the cloud.

## Exercises

1. Add a `database` module that creates a private subnet group and a
   `aws_db_subnet_group`, wired into `environments/dev`.
2. Add a `validation` block to `modules/network/variables.tf` requiring that
   `public_subnet_cidrs` and `availability_zones` have the same length.
3. Export the bastion's inventory fragment from the `compute` module (it already
   exists as `bastion_inventory_host`). Consume it in `environments/dev`.

## Gotchas

- Module outputs are **not** available during plan of a resource that depends on
  them if the value is unknown (`known after apply`). This is why some wiring
  forces a second apply.
- `count`/`for_each` on a module makes every output a list/map — use
  `module.x[0].y` or `module.x["key"].y`.
- Changing a module's `source` from a local path to a registry version changes
  state addresses. Use `moved` blocks.

## Check yourself

- [ ] You can explain `for_each` vs `count` with the subnet example
- [ ] `tools/hcl_parse_check.py terraform/modules` passes
- [ ] You know the three cases where a module is the wrong answer

**Next:** [Day 12 — Remote State & Locking](day12-remote-state-and-locking.md)
