# Terraform + Ansible: 30 Days from Zero to Master

A hands-on curriculum built around **this repository**. Every lesson points at real
files here, and every lab command is one you can run.

> **Rule of the course:** you do not understand a tool until you have watched it
> fail. Each day ends with a deliberate failure and the diagnosis.

## How this course is organised

| Level | Days | Outcome |
| --- | --- | --- |
| **Level 1 — Foundations** | 1–10 | You can write playbooks and roles, and plan/apply Terraform by hand |
| **Level 2 — Integration** | 11–20 | You can provision with Terraform and configure with Ansible as one pipeline |
| **Level 3 — Master** | 21–30 | You run it at fleet scale: secure, tested, drift-free, observable, self-healing |

**Time budget:** 1–2 hours per day. Days 10, 20 and 30 are capstones — budget 3–4 hours.

**Prerequisites:** read [`docs/00-prerequisites.md`](docs/00-prerequisites.md) once, before Day 1.

## The one diagram to memorise

```
        ┌──────────────┐   terraform apply    ┌──────────────────────┐
 Git ──▶│  Terraform   │ ───────────────────▶ │  AWS: VPC, subnets,  │
        │  (WHAT       │                      │  SGs, ASG, ALB, IAM  │
        │   EXISTS)    │ ◀──── state file ─── │                      │
        └──────┬───────┘                      └──────────┬───────────┘
               │                                         │
               │ terraform output ansible_inventory_json │
               ▼                                         │
        ┌──────────────┐      ansible-playbook           │
        │   Ansible    │ ────────────────────────────────┘
        │  (HOW IT IS  │      SSH / user_data bootstrap
        │  CONFIGURED) │  ──▶ New Relic agents installed,
        └──────────────┘      configured, verified
```

Terraform answers **"what exists?"**. Ansible answers **"how is it configured?"**.
The bridge between them is `terraform/environments/dev/outputs.tf` — Day 15.

## Curriculum

### Level 1 — Foundations (Days 1–10)

| Day | Title | You will be able to | Lab proof |
| --- | --- | --- | --- |
| [1](docs/level-1-foundations/day01-setup-and-mental-model.md) | Setup & mental model | Install both tools, explain push vs pull | `ansible --version` + `ansible localhost -m ping` |
| [2](docs/level-1-foundations/day02-inventory-and-ad-hoc.md) | Inventory & ad-hoc | Model hosts/groups, run one-off commands | `ansible-inventory --graph` |
| [3](docs/level-1-foundations/day03-playbooks-and-yaml.md) | Playbooks & YAML | Write a playbook, use `--check` and `--diff` | lab playbook runs twice, second time `changed=0` |
| [4](docs/level-1-foundations/day04-variables-and-vault.md) | Variables & Vault | Explain precedence, encrypt a secret | `ansible-vault view` + precedence experiment |
| [5](docs/level-1-foundations/day05-loops-conditionals-blocks.md) | Loops, conditionals, blocks | Loop, branch, and rescue from failure | `rescued=1` in the recap |
| [6](docs/level-1-foundations/day06-handlers-idempotency-tags.md) | Handlers, idempotency, tags | Restart only on change, run a slice | handler fires once, second run `changed=0` |
| [7](docs/level-1-foundations/day07-roles-anatomy.md) | Roles anatomy | Build a role with defaults/handlers/meta | `ansible-playbook --list-tasks` shows role prefixes |
| [8](docs/level-1-foundations/day08-templates-jinja2.md) | Templates & Jinja2 | Render config files safely | rendered file parses as YAML |
| [9](docs/level-1-foundations/day09-terraform-basics.md) | Terraform basics | init/plan/apply/destroy, read HCL | plan shows the exact create count |
| [10](docs/level-1-foundations/day10-terraform-state-and-capstone.md) | State & Level 1 capstone | Inspect/move/import state; ship a local lab | capstone checklist |

### Level 2 — Integration (Days 11–20)

| Day | Title | You will be able to | Lab proof |
| --- | --- | --- | --- |
| [11](docs/level-2-integration/day11-terraform-modules.md) | Modules | Build reusable modules with typed inputs/outputs | `tools/hcl_parse_check.py` passes |
| [12](docs/level-2-integration/day12-remote-state-and-locking.md) | Remote state & locking | Configure S3+DynamoDB, recover a lock | `terraform force-unlock` demo |
| [13](docs/level-2-integration/day13-aws-networking.md) | AWS networking | VPC, subnets, NAT, route tables, SGs | checkov network checks pass |
| [14](docs/level-2-integration/day14-aws-compute-and-asg.md) | Compute & ASG | Launch template, ASG, ALB, IAM roles | plan shows rolling refresh |
| [15](docs/level-2-integration/day15-terraform-ansible-integration.md) | **The bridge** | Turn Terraform output into Ansible inventory | `bash labs/local/mock_bridge.sh` |
| [16](docs/level-2-integration/day16-bootstrap-userdata-proxyjump.md) | Bootstrap & ProxyJump | Split user_data vs Ansible, jump via bastion | `wait_for_connection` succeeds |
| [17](docs/level-2-integration/day17-collections-and-galaxy.md) | Collections & Galaxy | Pin dependencies, compare official NR role | `ansible-galaxy install -r requirements.yml` |
| [18](docs/level-2-integration/day18-newrelic-agents-end-to-end.md) | New Relic end-to-end | Infra + APM + integrations, verified | `playbooks/verify.yml` green |
| [19](docs/level-2-integration/day19-cicd-pipeline.md) | CI/CD | Plan on PR, apply on merge, OIDC auth | workflow lint passes |
| [20](docs/level-2-integration/day20-testing-and-capstone.md) | Testing & capstone | Test IaC at four levels | all four test layers green |

### Level 3 — Master (Days 21–30)

| Day | Title | You will be able to | Lab proof |
| --- | --- | --- | --- |
| [21](docs/level-3-master/day21-multi-environment-architecture.md) | Multi-environment | Structure dev/staging/prod without duplication | one module, three envs |
| [22](docs/level-3-master/day22-terraform-advanced-patterns.md) | Advanced Terraform | for_each vs count, move/import blocks | refactor without destroy |
| [23](docs/level-3-master/day23-ansible-at-scale.md) | Ansible at scale | serial, async, delegation, fact caching | 500-host simulation |
| [24](docs/level-3-master/day24-security-and-compliance.md) | Security & compliance | Least privilege, vault, justified skips | `.checkov.yaml` audit |
| [25](docs/level-3-master/day25-drift-detection-self-healing.md) | Drift & self-healing | Detect and remediate drift on a schedule | drift job reports a change |
| [26](docs/level-3-master/day26-observability-pipeline-newrelic.md) | Observability | Dashboards/alerts as code, deploy markers | NerdGraph query returns data |
| [27](docs/level-3-master/day27-gitops-and-delivery.md) | GitOps & delivery | Atlantis-style PR automation, rollback | apply approval flow |
| [28](docs/level-3-master/day28-cost-scale-and-module-versioning.md) | Cost & module versioning | Semver modules, plan-noise reduction, tags | versioned module reference |
| [29](docs/level-3-master/day29-troubleshooting-masterclass.md) | Troubleshooting | Diagnose 15 real failures | reproduce and fix each |
| [30](docs/level-3-master/day30-master-capstone.md) | Master capstone | Build the whole platform solo | capstone rubric |

## Running the labs

Three tiers, in increasing order of realism:

```bash
# 1. No cloud, no root, no internet. Every Level 1 lab.
cd ansible && ansible-playbook ../labs/local/lab.yml

# 2. The Terraform -> Ansible bridge, using a sample state file.
bash labs/local/mock_bridge.sh

# 3. Real cloud. From Day 12 onwards.
terraform/scripts/deploy.sh dev
```

## Verification status of this repository

See [`docs/VERIFICATION.md`](docs/VERIFICATION.md) for exactly which commands were
run against this code and what they returned — including what could **not** be
verified in an offline sandbox (provider downloads, `terraform plan`, the New
Relic package repository).
