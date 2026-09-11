# Day 22 — Advanced Terraform Patterns

**Level 3** · ~2 hours · Prereqs: Day 21

## What you will be able to do

- Choose `for_each` vs `count` and refactor between them without destroying
- Use `moved`, `import` and `removed` blocks
- Use provider aliases and `terraform_data`
- Read a plan and predict what will happen

## `for_each` vs `count`, revisited

Day 11 covered the basics. The deeper rules:

```hcl
# GOOD: keyed by a stable identifier
resource "aws_subnet" "private" {
  for_each          = local.private_subnets     # map: az => cidr
  availability_zone = each.key
  cidr_block        = each.value
}

# BAD: keyed by position
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  cidr_block        = var.private_subnet_cidrs[count.index]
}
```

Refactoring between them changes addresses
(`aws_subnet.private[0]` → `aws_subnet.private["ap-south-1a"]`), which Terraform
reads as destroy + create. Use a `moved` block:

```hcl
moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["ap-south-1a"]
}
moved {
  from = aws_subnet.private[1]
  to   = aws_subnet.private["ap-south-1b"]
}
```

`moved` blocks are **reviewable in a PR**. That is the whole argument for
preferring them over `terraform state mv`.

## `import` blocks

Adopt existing resources without a CLI command:

```hcl
import {
  to = aws_instance.legacy
  id = "i-0abc123def456"
}
```

`terraform plan` then shows the import. Once applied, delete the block (or leave
it — Terraform is idempotent about imports).

Use cases: adopting hand-made resources, splitting a monolithic state, recovering
from a `state rm`.

## `removed` blocks (Terraform 1.7+)

Stop managing a resource **without deleting it**:

```hcl
removed {
  from = aws_instance.legacy

  lifecycle {
    destroy = false
  }
}
```

The pre-1.7 equivalent was `terraform state rm`, which leaves no trace in git.

## Conditional resources and optional modules

Three idioms in this repo:

```hcl
# 1. optional module
module "monitoring" {
  source = "../../modules/monitoring"
  count  = var.enable_monitoring_module ? 1 : 0
}

# 2. optional resource inside a module
resource "aws_nat_gateway" "this" {
  for_each = var.enable_nat_gateway ? local.nat_gateways : {}
}

# 3. optional nested block
dynamic "route" {
  for_each = var.enable_nat_gateway ? [1] : []
  content {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[each.key].id
  }
}
```

Idiom 2 (`for_each = ... : {}`) is the cleanest: an empty map creates nothing, and
no `count` indexing leaks into references.

## Provider aliases

For multi-region or multi-account:

```hcl
provider "aws" {
  alias  = "eu"
  region = "eu-west-1"
}

resource "aws_s3_bucket" "dr_copy" {
  provider = aws.eu
  bucket   = "my-dr-bucket"
}
```

Also used for multi-account New Relic:

```hcl
provider "newrelic" {
  alias      = "eu_account"
  account_id = var.newrelic_eu_account_id
  region     = "EU"
}
```

## `terraform_data`

The replacement for `null_resource` — a resource that stores arbitrary data and
can trigger replacements:

```hcl
resource "terraform_data" "agent_config_version" {
  input = filesha256("${path.module}/templates/newrelic-infra.yml.j2")
}

resource "aws_launch_template" "this" {
  # ...
  lifecycle {
    replace_triggered_by = [terraform_data.agent_config_version]
  }
}
```

That pattern — *change the config template, replace the instances* — is how you
push Ansible-managed configuration into an immutable-infrastructure world.

## Reading a plan like a professional

```bash
terraform plan -no-color | tee plan.txt
```

Look for, in this order:

1. **The summary line.** `Plan: 3 to add, 1 to change, 2 to destroy.` Any destroy
   needs a reason.
2. **`-/+ destroy and then create replacement`** — read the `# forces
   replacement` line. That tells you *which attribute* caused it.
3. **`(known after apply)`** — values Terraform cannot compute yet. These can cause
   a second apply to be needed.
4. **`~ update in-place`** — safe, but check the diff.

Force-replacement classics: changing a subnet's AZ, an instance's AMI, a VPC's
CIDR, or an S3 bucket's name.

## Lab 22.1 — predict the plan

Read `terraform/modules/network/main.tf` and answer before running anything:

1. You add a third AZ to `availability_zones` and a third CIDR to
   `public_subnet_cidrs`. How many resources are created? How many destroyed?
2. You remove the **first** AZ. Same questions.
3. You set `single_nat_gateway = false`. What is created, and what is the ongoing
   cost difference?

Then verify with `terraform plan` if you have credentials, or by reading the
`for_each` keys.

Answers: (1) 3 created (2 subnets per AZ = 2 public + 2 private... be precise: 2
subnets, 1 route table association), 0 destroyed. (2) 2 destroyed, 0 recreated —
because `for_each` is keyed by AZ. With `count`, (2) would destroy and recreate
everything.

## Lab 22.2 — parse and count blocks

```bash
python3 tools/hcl_parse_check.py | grep -E "outputs.tf|variables.tf"
```

`terraform/environments/dev/outputs.tf` reports 35 blocks — that is the bridge
surface. `variables.tf` reports 19.

## Lab 22.3 — the deliberate failure

Add this to a scratch module and parse it:

```hcl
resource "aws_instance" "x" {
  monitoring {
    enabled = true
  }
}
```

```bash
python3 tools/hcl_parse_check.py scratch/     # PASSES
checkov -d scratch --framework terraform       # FAILS CKV_AWS_126
```

The parser says the file is fine. It is not: `monitoring` is a boolean on
`aws_instance`, and `terraform validate` would reject it. This is the concrete
limit of parsing without a schema.

## Exercises

1. Convert `aws_route_table.private` from `for_each` to `count` and write the
   `moved` blocks needed to refactor back.
2. Add `replace_triggered_by` to the launch template using `terraform_data` and a
   hash of the user_data template.
3. Write an `import` block for a VPC you created by hand, and a `removed` block
   that forgets it without deleting it.

## Gotchas

- `for_each` cannot use values that are unknown at plan time (e.g. an attribute
  of a resource being created). Use `count` or split the apply.
- `moved` blocks only apply to resources in the same state file.
- `replace_triggered_by` with an ASG replaces the template, not the instances —
  you still need an instance refresh.
- Deleting a `moved` block before every consumer has applied can cause a destroy.

## Check yourself

- [ ] You can explain why `for_each` keyed by AZ prevents outages
- [ ] You can write `moved`, `import` and `removed` blocks
- [ ] You can name the four things to look for in a plan

**Next:** [Day 23 — Ansible at Scale](day23-ansible-at-scale.md)
