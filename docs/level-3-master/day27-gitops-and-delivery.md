# Day 27 — GitOps and Delivery Automation

**Level 3** · ~90 min · Prereqs: Day 26

## What you will be able to do

- Design an apply-on-approval workflow
- Implement plan-on-PR with a reviewable artifact
- Roll back Terraform and Ansible changes
- Decide what belongs in git and what must not

## The delivery model

```
developer                PR                       main
   │                      │                         │
   ├─▶ branch + PR ───────▶ plan posted as comment  │
   │                      │ artifact: tfplan        │
   │   human approves ────▶                         │
   │                      └─▶ merge ───────────────▶ apply tfplan
   │                                                │
   │                                                ├─▶ generate inventory
   │                                                ├─▶ ansible-playbook site.yml
   │                                                └─▶ verify + deploy marker
```

Four properties:

1. **The reviewed plan is the applied plan.** No re-planning between approval and
   apply. `terraform/scripts/deploy.sh` applies a saved plan file for exactly
   this reason.
2. **A human approves.** Not a chatbot reaction — a branch-protection review.
3. **Everything is an artifact.** The plan, the generated inventory, the Ansible
   recap. When something breaks at 2am, these are what you read.
4. **Rollback is a revert.** Not a manual `terraform apply` with different values.

## Tooling options

| Tool | Model | Notes |
| --- | --- | --- |
| **Atlantis** | PR-driven, self-hosted | plan on PR, `atlantis apply` comment, locking built in |
| **Terraform Cloud / HCP** | SaaS | run tasks, drift detection, policy as code |
| **env0 / Spacelift / Scalr** | SaaS | cost estimation, OPA policies |
| **Plain GitHub Actions** | DIY | what this repo ships |

For a small team, GitHub Actions plus a saved plan artifact gets you 80% of the
value. Move to Atlantis when you have more than ~3 environments or need
per-PR locking.

## Plan on PR

```yaml
- name: Terraform plan
  working-directory: terraform/environments/${{ inputs.environment }}
  run: terraform plan -input=false -no-color -out=tfplan

- name: Save the plan as an artifact
  uses: actions/upload-artifact@v4
  with:
    name: tfplan-${{ inputs.environment }}-${{ github.sha }}
    path: terraform/environments/${{ inputs.environment }}/tfplan
    retention-days: 7

- name: Human-readable plan for the PR
  working-directory: terraform/environments/${{ inputs.environment }}
  run: terraform show -no-color tfplan > plan.txt
```

Post `plan.txt` as a PR comment. Reviewers read the plan, not the diff.

### The destroy guard

```bash
terraform show -json tfplan > plan.json
python3 - <<'PY'
import json, sys
plan = json.load(open("plan.json"))
deletes = [c["address"] for c in plan.get("resource_changes", [])
           if "delete" in c["change"]["actions"]]
if deletes:
    print("This plan DESTROYS:", *deletes, sep="\n  ")
    sys.exit(1)
print("No destroys.")
PY
```

Require an explicit label (`approved-destroy`) to bypass. Most "production
outage via Terraform" stories are an unreviewed destroy.

## Apply on merge

```bash
terraform/scripts/deploy.sh dev
```

The script is the contract:

```bash
terraform init -input=false
terraform plan -input=false -out=tfplan
terraform apply -input=false -auto-approve tfplan
tf_to_inventory.py -o ansible/inventory/generated/${ENV}.yml
ansible-playbook playbooks/site.yml --limit "${ENV}" --diff
```

`-input=false` everywhere: a prompt in CI hangs the job until it times out.

## Concurrency control

Two deploys to the same environment at once is how state gets corrupted:

```yaml
concurrency:
  group: deploy-${{ inputs.environment }}
  cancel-in-progress: false      # never kill a running apply
```

`cancel-in-progress: false` is essential — cancelling an apply mid-way leaves
partial infrastructure and a lock.

## Rollback

### Ansible

Git revert the change, re-run the playbook. Ansible's declarative model means
"revert and apply" is a real rollback.

Exceptions:

- A package downgrade needs an explicit version pin, not a revert.
- A reboot cannot be un-done.
- A deleted file is gone unless you kept a backup.

### Terraform

- **Revert the commit** and apply. Correct for config changes.
- **State surgery** for "this resource must not be touched": `terraform state rm`
  or a `removed` block (Day 22).
- **Never** hand-edit a state file.

### The uncomfortable truth

Some changes are not reversible: destroyed data, sent emails, deleted S3 buckets
without versioning. For those, the control is **prevention** (destroy guards,
deletion protection, versioning), not rollback.

## What belongs in git

| Belongs | Does not belong |
| --- | --- |
| `.tf`, `.tfvars.example`, modules | `terraform.tfvars` with real values |
| `terraform.tfstate.lock.hcl`? no — | `terraform.tfstate` (secrets in plaintext) |
| `.terraform.lock.hcl` (provider hashes) | `.terraform/` (provider binaries) |
| playbooks, roles, inventory structure | `inventory/generated/*.yml` (regenerable) |
| `requirements.yml` | `collections/` (regenerable) |
| `.facts/`? no — | `.facts/` (host details) |
| CI workflows | CI secrets |

The repo's `.gitignore` encodes this table.

## Lab 27.1 — read the deploy script

```bash
cd Newrelic-agentinstallansible
cat terraform/scripts/deploy.sh
```

Find the four stages, the `DRY_RUN` escape hatch, and the `TF_BIN` fallback from
`terraform` to `tofu`.

## Lab 27.2 — dry run it

```bash
DRY_RUN=1 bash terraform/scripts/deploy.sh dev
```

Without credentials it fails at `terraform init`/`plan` — which is the correct
behaviour, and the point: the script has no path that silently succeeds.

## Lab 27.3 — the deliberate failure

Remove `-input=false` from the apply line and imagine running it in CI with an
unapplied backend change:

```
terraform apply
Acquiring state lock...
Do you want to perform these actions? (yes/no)
```

The job waits. GitHub Actions has a 6-hour limit; your pipeline has a 30-minute
one. Meanwhile the lock is held. `-input=false` converts a hang into an immediate
error.

## Exercises

1. Add PR comment posting of `plan.txt` using `gh pr comment`.
2. Add a required label `approved-destroy` to bypass the destroy guard.
3. Write a rollback runbook for "a bad playbook ran against prod 10 minutes ago",
   including how you would prove the rollback worked.
4. Add an approval gate (`environment: production` with required reviewers) to the
   workflow.

## Gotchas

- `terraform apply -auto-approve` without a plan file re-plans. That defeats the
  review. Always `apply tfplan`.
- Artifacts expire (`retention-days`). For audit purposes, also push the plan to
  object storage.
- `concurrency` groups are per-workflow-file by default; include the environment
  in the group name.
- A revert commit that includes a `moved` block can re-trigger the move in the
  wrong direction. Review reverts of refactors especially carefully.
- Generated inventory in git causes merge conflicts on every deploy. Ignore it.

## Check yourself

- [ ] You can explain why the applied plan must be the reviewed plan
- [ ] `DRY_RUN=1` stops before apply
- [ ] You have a written rollback runbook

**Next:** [Day 28 — Cost, Scale & Module Versioning](day28-cost-scale-and-module-versioning.md)
