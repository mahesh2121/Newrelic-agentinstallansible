# Day 28 — Cost, Plan Noise and Module Versioning

**Level 3** · ~90 min · Prereqs: Day 27

## What you will be able to do

- Attribute every dollar to a team and an environment
- Reduce plan noise so reviews are meaningful
- Version and publish internal modules
- Reason about state size and plan performance

## Cost: tags first, everything else second

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

Modules also add their own tags:

```hcl
common_tags = merge(var.tags, {
  Module      = "network"
  Project     = var.project
  Environment = var.environment
  ManagedBy   = "terraform"
})
```

`ManagedBy = terraform` is the tag that finds **unmanaged** spend: query your bill
for resources without it and you have a list of things to adopt or delete.

### The costs people forget

| Item | Why it surprises |
| --- | --- |
| NAT gateway | hourly **plus** per-GB. A private subnet with chatty agents is a real bill |
| VPC flow logs | CloudWatch ingestion + storage; 365-day retention adds up |
| Detailed monitoring | per-instance, per-metric |
| ALB | hourly + LCU |
| EIP on a stopped instance | hourly charge for an idle EIP |
| Cross-AZ traffic | every request from ALB to a target in another AZ |
| New Relic ingest | custom attributes multiply event size |

That last one is worth internalising: **every custom attribute you add to the
agent increases ingest volume.** Three useful attributes beat twenty speculative
ones.

### Reducing NAT cost with a gateway endpoint

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.this.id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  tags = local.common_tags
}
```

S3 traffic no longer traverses NAT. If your agents or deploy scripts pull from S3,
this pays for itself immediately.

## Plan noise

A plan with 400 lines of noise hides the 3 lines that matter. Sources and fixes:

| Noise | Fix |
| --- | --- |
| ASG `desired_capacity` | `ignore_changes = [desired_capacity]` |
| Launch template versions | `create_before_destroy` + `"$Latest"` |
| Data sources re-resolving | pin AMIs; avoid `most_recent = true` |
| Provider default changes | pin provider versions, commit the lock file |
| Tag ordering | use consistent `merge()` order |
| `known after apply` cascades | split into two applies for genuinely dependent resources |

This repo already uses:

```hcl
lifecycle {
  create_before_destroy = true
  ignore_changes        = [desired_capacity]
}
```

### Pinning the AMI

```hcl
variable "ami_id" {
  description = "AMI to launch. Leave empty to use the latest Ubuntu LTS."
  type        = string
  default     = ""
}
```

`most_recent = true` is convenient in dev and dangerous in prod: a new AMI appears
overnight and your next scale-out uses an untested image. Pin per environment and
bump deliberately, with a plan you review.

## Module versioning

Three stages of maturity:

```hcl
# 1. local path - one repo, one team
source = "../../modules/network"

# 2. git ref - shared across repos, pinned to a tag
source = "git::https://github.com/yourorg/terraform-modules.git//network?ref=v1.4.0"

# 3. private registry - versioned, documented, discoverable
source  = "app.terraform.io/yourorg/network/aws"
version = "~> 1.4"
```

Rules:

- **Semver.** Breaking = major (removing an output, renaming a variable, changing
  a resource address). New optional variable = minor. Bug fix = patch.
- **Never** point `main` at a branch in production config. `ref=v1.4.0` or nothing.
- **CHANGELOG per module.** A breaking change without a changelog entry is a trap
  for the next team.
- Changing a resource address inside a module is a breaking change for every
  consumer's state — ship `moved` blocks with it.

### Publishing checklist

- [ ] `versions.tf` with provider constraints
- [ ] every variable has `description` and `type`
- [ ] every output has `description`
- [ ] `README.md` with inputs/outputs table and an example
- [ ] `examples/` directory that actually applies
- [ ] CHANGELOG entry
- [ ] tag `vX.Y.Z`

## State size and performance

Symptoms of a state file that has grown too large: slow plans, `terraform apply`
timeouts, CI memory pressure.

| Cause | Fix |
| --- | --- |
| thousands of resources in one state | split by lifecycle/domain (network vs app vs data) |
| huge `user_data` blobs | `templatefile` + `filesha256` instead of inline |
| data sources storing full objects | narrow the query |
| many environments in one state | one state per environment (Day 21) |

Rule of thumb: keep a single state under ~2,000 resources. Above that, split by
**blast radius**, not by convenience — you want the network state to change rarely
and independently of the app state.

```bash
terraform state list | wc -l
du -h terraform.tfstate
```

## Lab 28.1 — audit tags

```bash
cd Newrelic-agentinstallansible
grep -rn "common_tags\|default_tags" terraform/ | head -20
```

Every resource in every module should resolve through one of these. A resource
with hard-coded tags is a resource missing from your cost report.

## Lab 28.2 — count your interface surface

```bash
for m in network security compute monitoring; do
  printf "%-12s inputs=%-3s outputs=%s\n" "$m" \
    "$(grep -c '^variable' terraform/modules/$m/variables.tf)" \
    "$(grep -c '^output'   terraform/modules/$m/outputs.tf)"
done
```

Real counts in this repo (verify yourself with the command above):

| Module | Inputs | Outputs |
| --- | --- | --- |
| network | 12 | 6 |
| security | 6 | 3 |
| compute | 29 | 9 |
| monitoring | 7 | 2 |

`compute` has by far the largest surface, and that is a smell worth discussing:
is it one module or three (compute, loadbalancer, bastion)? Splitting it would
make each easier to version independently.

## Lab 28.3 — the deliberate failure

Change an output name in `modules/network/outputs.tf` from `vpc_id` to
`vpc_identifier` and grep for consumers:

```bash
grep -rn "module.network.vpc_id" terraform/
```

Two call sites break. That is a **major** version bump for the module — and if
your consumers pin `~> 1.4`, they will not see it until they choose to. That is
the point of pinning: breaking changes arrive on your schedule, not upstream's.

Revert the rename.

## Exercises

1. Add the S3 gateway endpoint to the network module and export its ID.
2. Split `modules/compute` into `compute` and `loadbalancer`, with `moved` blocks
   so consumers' state survives.
3. Write a CHANGELOG for `modules/network` covering the changes made in this
   course (flow logs, default SG, KMS key).
4. Add a CI job that fails when a module's variable set changes without a
   CHANGELOG entry.

## Gotchas

- `default_tags` and resource-level `tags` merge; conflicts are resolved in favour
  of the resource-level tag, which can silently override your cost centre.
- Removing a tag can force replacement on some resources. Check the plan.
- Git-sourced modules are re-downloaded on every `init` unless cached. Set
  `TF_PLUGIN_CACHE_DIR` and cache `.terraform/modules` in CI.
- A module `ref` pointing at a **branch** means `terraform init -upgrade` changes
  your infrastructure. Never do this for prod.

## Check yourself

- [ ] You can name five cost items people forget
- [ ] You know why `desired_capacity` is in `ignore_changes`
- [ ] You can state the module publishing checklist

**Next:** [Day 29 — Troubleshooting Masterclass](day29-troubleshooting-masterclass.md)
