# Day 9 — Terraform Basics: HCL, Providers, Resources

**Level 1** · ~90 min · Prereqs: Day 8

## What you will be able to do

- Read and write HCL blocks
- Run the init → plan → apply → destroy lifecycle
- Explain what state is and why it is sacred
- Tell the difference between a syntactically valid and a schema-valid config

## The mental model

Terraform is a **reconciliation loop**:

```
your .tf files  ──┐
                  ├──▶ plan ──▶ apply ──▶ real infrastructure
terraform.tfstate ┘
```

- Your `.tf` files describe the **desired** state.
- `terraform.tfstate` records what Terraform believes it **created**.
- `plan` computes the difference. `apply` performs it.

Ansible, by contrast, asks the machine what it currently looks like. Terraform
asks its own notebook. That is why Terraform can delete things Ansible never
would, and why a lost state file is a bad day.

## HCL in 10 minutes

```hcl
# 1. provider: which API, which version
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"          # pessimistic constraint: >= 5.0, < 6.0
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# 2. variable: typed input
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

# 3. resource: a thing to manage
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = { Name = "my-vpc" }
}

# 4. output: exported value
output "vpc_id" {
  value = aws_vpc.this.id
}
```

Block types you will meet: `terraform`, `provider`, `variable`, `resource`,
`data`, `locals`, `output`, `module`, `moved`, `import`.

`tools/hcl_parse_check.py` prints the count of each in this repo — run it in
Lab 9.3.

### Expressions

```hcl
locals {
  name_prefix = "${var.project}-${var.environment}"

  # for expression over a list -> map
  public_subnets = {
    for idx, az in var.availability_zones : az => var.public_subnet_cidrs[idx]
  }

  # conditional
  nat_gateways = var.single_nat_gateway ? { (var.availability_zones[0]) = "x" } : {}
}
```

That is real code from `terraform/modules/network/main.tf`.

## The lifecycle

```bash
cd terraform/environments/dev

terraform init          # download providers, configure backend
terraform validate      # syntax + provider schema, no cloud calls
terraform plan          # what will change
terraform apply         # do it
terraform destroy       # undo it
```

Useful flags:

```bash
terraform plan -out=tfplan          # save the plan
terraform apply tfplan              # apply exactly that plan (CI does this)
terraform plan -target=aws_vpc.this # limit scope (emergency use only)
terraform plan -refresh=false       # skip the API round trip
terraform show -json tfplan         # machine-readable diff
terraform console                   # evaluate expressions interactively
```

## Lab 9.1 — read the real modules

```bash
cd Newrelic-agentinstallansible
cat terraform/modules/network/variables.tf      # typed inputs with descriptions
cat terraform/modules/network/main.tf | head -60
cat terraform/modules/network/outputs.tf
```

Notice: every variable has a `description`, every `type` is explicit, and
`map_public_ip_on_launch = false` has a comment explaining why. **Terraform code
without descriptions is a liability** — in six months you will not remember what
`single_nat_gateway` meant.

## Lab 9.2 — the lifecycle without an AWS account

You cannot run `apply` without credentials, but you can practise everything else.
Install the CLI and run:

```bash
cd terraform/environments/dev
terraform init -backend=false
```

`-backend=false` skips the remote state configuration so `init` works offline.
`terraform plan` still needs to download the AWS provider, which requires network
access to `registry.terraform.io`.

## Lab 9.3 — validate HCL offline

```bash
python3 tools/hcl_parse_check.py
```

Real output:

```
ok   terraform/environments/dev/main.tf  (4 blocks)
ok   terraform/modules/network/main.tf  (15 blocks)
       resource.aws_cloudwatch_log_group, resource.aws_default_security_group,
       resource.aws_eip, resource.aws_flow_log, resource.aws_iam_role, ...
ok   terraform/modules/security/main.tf  (11 blocks)
...
HCL PARSE OK: 21 file(s), 221 declared block(s)
```

**Know this tool's limit.** A parser proves the file is valid HCL. It does not
know the AWS provider's schema, so it happily accepts arguments that do not
exist. That gap is Day 9's deliberate failure.

## Lab 9.4 — the deliberate failure (a real one)

`aws_instance` has `monitoring` as a **boolean argument**:

```hcl
resource "aws_instance" "bastion" {
  monitoring = true          # correct
}
```

`aws_launch_template` has `monitoring` as a **block**:

```hcl
resource "aws_launch_template" "this" {
  monitoring {
    enabled = true           # correct
  }
}
```

Write the block form on `aws_instance` and:

- `tools/hcl_parse_check.py` → **passes** (it is valid HCL)
- `terraform validate` → **fails** ("Blocks of type monitoring are not expected here")
- `checkov` → **fails** CKV_AWS_126

This exact mistake was in this repository's bastion and was caught by checkov,
not by the HCL parser. Lesson: **you need a schema-aware check**, and if you
cannot run `terraform validate` locally, run checkov.

## Lab 9.5 — security scanning as a proxy for validate

```bash
checkov --config-file .checkov.yaml
```

Real output from this repo:

```
Passed checks: 110, Failed checks: 0
```

Every skip in `.checkov.yaml` carries a written justification — that discipline
is Day 24.

## Exercises

1. Add an `output` to `terraform/modules/network/outputs.tf` exporting the
   number of private subnets, then confirm it parses.
2. Add a variable without a `type` and see how Terraform infers it. Why is that
   dangerous?
3. Change `required_version = ">= 1.6.0"` to `"~> 1.6"` in one module. Explain the
   difference in plain English.

## Gotchas

- `terraform.tfstate` may contain secrets (passwords, keys in plain text). Never
  commit it. `.gitignore` here covers it.
- `terraform destroy` destroys what the **state** knows about, not what your
  `.tf` files describe.
- `-auto-approve` in a terminal is how people delete production. Use it only in
  CI, on a saved plan.
- Provider version drift (`~> 5.0` resolving to a new 5.x) can change behaviour.
  Commit `.terraform.lock.hcl`.

## Check yourself

- [ ] You can explain state vs desired state
- [ ] `python3 tools/hcl_parse_check.py` passes and you know what it does *not* prove
- [ ] You can name the difference between `monitoring = true` and `monitoring { enabled = true }`

**Next:** [Day 10 — State & Level 1 Capstone](day10-terraform-state-and-capstone.md)
