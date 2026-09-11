# AWS CloudOps — Level 3+

**Days 31–37 · operating the platform in AWS**

The main course ([`TUTORIAL.md`](../../TUTORIAL.md)) takes you from zero to a
working Terraform + Ansible + New Relic platform in 30 days. It ends at "you can
build it".

This track starts there. Seven days on the part that has no tutorial and no
certification: **running it**.

## Why this is a separate track

Level 3 is about *correctness* — does the code do what it says, is it tested, is
it secure, does it converge. CloudOps is about *consequences* — what happens at
2 a.m., what the bill looks like, what you tell an auditor, and what you do when
the tool you trust is silently wrong.

The distinction shows up everywhere:

| Level 3 asks | CloudOps asks |
| --- | --- |
| Does `patch.yml` work? | What happens if it reboots the whole fleet? |
| Is the launch template correct? | How do running instances ever get the fix? |
| Is the state in S3? | What do you do the day it is gone? |
| Does the NRQL condition parse? | What if the tag it filters on never arrives? |
| Does checkov pass? | What did you skip to make it pass? |
| Are the tags applied? | Are they *activated* for cost reporting? |
| Is there an alert? | Is anyone still listening to it? |

Same repository, different questions. Nothing here replaces Level 3; every day
below assumes you finished it.

## Prerequisites

- [Day 30 — Master Capstone](../level-3-master/day30-master-capstone.md) done, or
  equivalent experience
- [`docs/00-prerequisites.md`](../00-prerequisites.md) still applies — every lab
  here runs without an AWS account unless it says otherwise
- Familiarity with `make verify` in the [`Makefile`](../../Makefile); several days
  add checks to it

## The seven days

| Day | Title | The one thing you will not forget | Time |
| --- | --- | --- | --- |
| [31](day31-aws-identity-and-access.md) | AWS Identity and Access | There are three identities — operator, pipeline, instance — and only the instance is in this repo | ~90 min |
| [32](day32-ec2-and-asg-operations.md) | EC2 and ASG Operations | A launch template edit changes **nothing** until you start an instance refresh | ~2 h |
| [33](day33-state-storage-backup-and-recovery.md) | State, Storage, Backup and Recovery | Losing the state loses *control*, not infrastructure | ~2 h |
| [34](day34-cloudwatch-newrelic-correlation.md) | CloudWatch, Flow Logs and New Relic | Four hops between a Terraform variable and an NRQL `WHERE` clause — and no single tool checks all four | ~2 h |
| [35](day35-patching-maintenance-and-change-control.md) | Patching, Maintenance and Change Control | `failed_when: false` is a decision that some failure does not matter | ~90 min |
| [36](day36-cost-budgets-and-governance.md) | Cost, Budgets and Governance | A correctly tagged resource still reports as unallocated until you activate the tag | ~90 min |
| [37](day37-compliance-incidents-and-cloudops-capstone.md) | Compliance, Incidents and Capstone | Every global scanner skip hides more than you meant it to | ~3 h |

Budget ~14 hours. Days 32, 33, 34 and 37 are the ones worth doing twice.

## How to work through it

Each day follows the same shape, matching the rest of the course:

1. **What you will be able to do** — the outcome, stated as abilities.
2. **What this stack actually does** — read the real resource, not a summary of it.
3. **A deliberate failure** — break something on purpose and diagnose it. The
   rule from `TUTORIAL.md` still holds: *you do not understand a tool until you
   have watched it fail.*
4. **A lab** — runnable commands, most of which need no cloud account.
5. **Exercises, gotchas, check yourself.**

Two things differ from Level 3:

- **Every day produces a finding about this repository.** Not a hypothetical — a
  real gap, with the file and line. They are collected in the table below, and
  fixing them is the highest-value work in the track.
- **Every day asks you to write a check.** The capstone grades you on how many of
  your claims are *automatically* verified. That number is the point.

## Findings this track surfaces

Each of these is real, in this repository, on the branch you are reading. They are
not bugs so much as decisions that were made implicitly and deserve to be made
explicitly:

| Day | Finding | Where |
| --- | --- | --- |
| 31 | The instance role grants `s3:GetObject` that nothing in the repo consumes, and has no SSM permission — so Session Manager does not work | `terraform/modules/compute/main.tf` |
| 31 | Rotating `ssh_public_key` or `ansible_ssh_authorized_keys` reaches running hosts only via a rebuild, because `user_data` runs once | `terraform/modules/compute/templates/user_data.sh.tpl` |
| 32 | The ASG sets no `health_check_grace_period`, so a slow-booting host can be terminated in a loop | `terraform/modules/compute/main.tf` |
| 32 | `version = "$Latest"` means template changes are invisible until an instance refresh is started | same |
| 33 | No `prevent_destroy` anywhere, and the state-bucket hardening pattern exists only on the ALB log bucket | `terraform/modules/compute/main.tf` |
| 34 | The `agent_not_reporting` condition is a missing-data alert: a tag mismatch makes it fire forever instead of never | `terraform/modules/monitoring/main.tf` |
| 35 | The last task of `patch.yml` has `failed_when: false`, so a dead agent still reports `failed=0` | `ansible/playbooks/patch.yml` |
| 36 | `flow_log_retention_days` defaults to 365 in every environment to satisfy a policy check | `terraform/modules/network/variables.tf` |
| 37 | `CKV_AWS_24` is skipped globally, so an open bastion SSH rule passes `make scan` | `.checkov.yaml` |

None of these is urgent. All of them are the kind of thing that turns into an
incident when nobody wrote them down.

## What you need

For the labs, the same toolchain as the main course — see
[`docs/VERIFICATION.md`](../VERIFICATION.md) for the pinned versions used to
validate this repository:

```bash
python3 -m pip install --user ansible-core
cd ansible && ansible lab -m ping
```

For the AWS-specific exercises (marked as such in each day) you need an account
and credentials for it. Nothing in the track requires you to spend money, and the
`DRY_RUN=1` mode of `terraform/scripts/deploy.sh` exists precisely so you can
stop before `apply`:

```bash
DRY_RUN=1 terraform/scripts/deploy.sh dev
```

## Verify the docs themselves

This repository has a check for exactly the failure mode tutorials are prone to —
telling you to look at a file that does not exist:

```bash
python3 tools/docs_path_check.py
```

Run it after editing anything in this folder. Every repo path referenced in these
seven days resolves to a real file, and that is a deliberate constraint: if a
day tells you to read something, you can read it.

## Where to go after

| Direction | Next |
| --- | --- |
| Prove you retained Level 1–3 | [`docs/CHECKPOINTS.md`](../CHECKPOINTS.md) |
| See what was actually validated | [`docs/VERIFICATION.md`](../VERIFICATION.md) |
| Re-read the integration core | [`docs/level-2-integration/day15-terraform-ansible-integration.md`](../level-2-integration/day15-terraform-ansible-integration.md) |
| Go deeper on the failures | [`docs/level-3-master/day29-troubleshooting-masterclass.md`](../level-3-master/day29-troubleshooting-masterclass.md) |
| Certifications | AWS Certified SysOps Administrator – Associate; HashiCorp Certified: Terraform Associate |

---

**Start with [Day 31 — AWS Identity and Access](day31-aws-identity-and-access.md).**
