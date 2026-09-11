# Day 21 — Multi-Environment Architecture

**Level 3** · ~90 min · Prereqs: Day 20

## What you will be able to do

- Structure dev/staging/prod with zero duplicated logic
- Choose between workspaces, directories and stacks
- Keep environments *different* where they should be and *identical* where they must be

## The core tension

Environments must be **identical in shape** (so a dev test means something) and
**different in size** (so dev is cheap). Teams get this wrong in two opposite
directions:

- **Over-DRY:** one config with 40 `if env == prod` branches. Nobody can predict
  what prod will do.
- **Copy-paste:** three folders that were identical in March and are not now.

The answer: **one implementation, three value sets.**

## This repo's layout

```
terraform/
├── modules/
│   ├── network/    security/    compute/    monitoring/
└── environments/
    ├── dev/        main.tf  variables.tf  outputs.tf  providers.tf  terraform.tfvars.example
    ├── staging/    main.tf (thin wrapper around ../dev)  terraform.tfvars.example
    └── prod/       terraform.tfvars.example
```

`terraform/environments/staging/main.tf` is 40 lines and contains no logic:

```hcl
module "stack" {
  source      = "../dev"

  environment              = "staging"
  vpc_cidr                 = "10.20.0.0/16"
  instance_type            = "t3.small"
  min_size                 = 2
  max_size                 = 4
  desired_capacity         = 2
  enable_monitoring_module = true
  ...
}
```

Everything else is inherited. A change to `dev/main.tf` reaches staging
automatically, which is exactly what you want — with one exception below.

## Three options compared

| Approach | How | Pros | Cons |
| --- | --- | --- | --- |
| **Workspaces** | `terraform workspace new prod` | one directory | one state path prefix, easy to fat-finger, IAM granularity is poor, `terraform.tfvars` is shared |
| **Directories** (this repo) | `environments/<env>/` | separate state, separate IAM, obvious blast radius | slight duplication of the root module |
| **Stacks / component reuse** | module called N times from one root | maximal DRY | one state file per stack → coupled blast radius |

**Recommendation: directories.** The duplication is a 40-line `main.tf`; the
isolation is worth far more. Workspaces are fine for *the same environment*
across regions or tenants, not for dev→prod.

## What should differ between environments

| Dimension | dev | staging | prod |
| --- | --- | --- | --- |
| Instance type/size | small | medium | as sized |
| NAT gateways | 1 (shared) | 1 | one per AZ |
| Monitoring module | optional | on | on |
| Deletion protection | off | on | on |
| ALB deletion protection | off | on | on |
| Log retention | 30 days | 90 | 365 |
| CIDR | 10.0.0.0/16 | 10.20.0.0/16 | 10.10.0.0/16 |
| Bastion allowed CIDRs | your VPN | VPN | VPN + break-glass |

This repo encodes the NAT decision in one line:

```hcl
single_nat_gateway = var.environment != "prod"
```

Resist the temptation to add 20 more lines like that. **If a behaviour must
differ, make it a variable with a per-environment value, not an inline
conditional.**

## What must never differ

- Module versions and provider versions
- Tagging scheme
- IAM permission boundaries
- Encryption settings
- The *set* of resources (a resource that exists only in prod is a resource that
  has never been tested)

## The Ansible side

```
ansible/inventory/
├── hosts.yml                 static groups (servers, lab, newrelic_infra)
├── generated/dev.yml         <- Terraform output, git-ignored
├── group_vars/all.yml        shared: region, project, base packages
├── group_vars/servers.yml    real hosts: packages, labels
├── group_vars/lab.yml        local lab: flags off, paths in $HOME
└── group_vars/vault.yml      encrypted secrets
```

Environment differences live in **generated inventory + group_vars**, never in
roles. If you find `when: env_name == 'prod'` inside a role, stop and move that
decision into a variable.

## Naming, tagging and cost

`terraform/environments/dev/providers.tf`:

```hcl
provider "aws" {
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      CostCenter  = var.cost_center
    }
  }
}
```

`default_tags` applies to every resource without any module code. This is the
single highest-leverage line for cost reporting: without `Environment` and
`CostCenter`, your monthly bill is one number with no owners.

## Lab 21.1 — inspect the layout

```bash
cd Newrelic-agentinstallansible
find terraform/environments -type f | sort
echo "--- staging main.tf line count ---"
wc -l terraform/environments/staging/main.tf
echo "--- logic in staging? ---"
grep -nE "count|for_each|\? |if " terraform/environments/staging/main.tf
```

`wc -l` should report roughly 40 lines and the grep should return almost nothing.
That emptiness is the design.

## Lab 21.2 — verify all environments parse

```bash
python3 tools/hcl_parse_check.py terraform/environments
```

Real output:

```
ok   terraform/environments/dev/main.tf  (4 blocks)
ok   terraform/environments/dev/outputs.tf  (35 blocks)
ok   terraform/environments/dev/providers.tf  (2 blocks)
ok   terraform/environments/dev/variables.tf  (19 blocks)
ok   terraform/environments/staging/main.tf  (10 blocks)
HCL PARSE OK
```

Note `prod/` has only a `terraform.tfvars.example` — it reuses the same root.
Adding a prod directory with its own `main.tf` is a decision to make
deliberately, not by copying.

## Lab 21.3 — the deliberate failure

Copy `dev/main.tf` into a new `prod/main.tf` and edit one thing (say, the instance
type). Now `grep -n instance_type terraform/environments/*/main.tf`:

Two files, one difference, and no way to tell whether the other 60 lines are still
in sync. In six months nobody will know. Delete the copy and use tfvars.

## Exercises

1. Create `terraform/environments/prod/main.tf` as a thin wrapper like staging's,
   with 3 AZs and monitoring always on.
2. Add a `terraform/environments/README.md` table documenting every intentional
   difference between environments, and make CI fail if a difference is not in the
   table. (Hard — worth attempting.)
3. Move the `single_nat_gateway` conditional out of `main.tf` into a per-env
   tfvars value. What do you gain?

## Gotchas

- A module referenced by `source = "../dev"` shares dev's `providers.tf`. If dev
  and prod need different provider configurations, that breaks — give each
  environment its own root.
- Workspaces and `count`/`for_each` interact badly: `terraform workspace select`
  changes nothing about resource addresses, so people assume isolation they do not
  have.
- `terraform.tfvars` is not the only way to set values: `-var-file` per
  environment is more explicit in CI.
- Generated inventories must be per-environment
  (`inventory/generated/dev.yml`) or a prod run can target dev hosts.

## Check yourself

- [ ] You can justify directories over workspaces in two sentences
- [ ] `staging/main.tf` contains no business logic
- [ ] You can list what must never differ between environments

**Next:** [Day 22 — Advanced Terraform Patterns](day22-terraform-advanced-patterns.md)
