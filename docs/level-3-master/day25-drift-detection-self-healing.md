# Day 25 — Drift Detection and Self-Healing

**Level 3** · ~90 min · Prereqs: Day 24

## What you will be able to do

- Define drift precisely for both tools
- Detect it on a schedule and route it to a human or a remediation
- Decide what to auto-heal and what to escalate
- Prove a host matches Git

## What drift actually is

| | Terraform drift | Ansible drift |
| --- | --- | --- |
| Definition | real infrastructure ≠ state/desired config | host state ≠ playbook's desired state |
| Cause | console changes, autoscaling, another team | someone SSHed in, a package auto-updated, a failed partial run |
| Detection | `terraform plan -detailed-exitcode` | `ansible-playbook --check` reporting `changed` |
| Fix | `terraform apply` | re-run the playbook |

**Drift is not a moral failing.** It is information: either your IaC does not
cover something, or someone had an emergency. Both deserve a response, and neither
deserves a silent revert at 3am.

## Detection: Terraform

```bash
terraform plan -detailed-exitcode -out=tfplan
# exit 0 = no changes
# exit 1 = error
# exit 2 = changes present  <- drift
```

```bash
if terraform plan -detailed-exitcode -no-color > plan.txt; then
  echo "no drift"
else
  rc=$?
  [ "$rc" = "2" ] && { echo "DRIFT DETECTED"; cat plan.txt; }
fi
```

Add `-refresh-only` to distinguish "the world changed" from "the code changed":

```bash
terraform plan -refresh-only    # shows only drift, not pending code changes
```

## Detection: Ansible

`playbooks/drift-check.yml` runs the real roles in check mode:

```yaml
- name: Detect configuration drift
  hosts: servers:lab
  check_mode: true
  roles:
    - role: common
    - role: newrelic_infra
```

```bash
ansible-playbook playbooks/drift-check.yml --limit servers
```

A host showing `changed > 0` has drifted. Parse the recap in CI:

```bash
ansible-playbook playbooks/drift-check.yml --limit servers \
  | tee drift.log
grep -E "changed=[1-9]" drift.log && echo "DRIFT" || echo "clean"
```

### The marker-file trick

`roles/common/tasks/main.yml` writes an audit record:

```yaml
- name: Write configuration marker
  ansible.builtin.copy:
    content: |
      managed_by: ansible
      role: common
      last_applied: "{{ ansible_date_time['iso8601'] }}"
      inventory_group: "{{ group_names | join(',') }}"
    dest: "{{ common_marker_dir }}/common.yml"
    mode: "0644"
```

That file answers "when did Ansible last touch this host, and from which
inventory group?" — which is the first question in every "who changed this?"
conversation. Note it is **intentionally non-idempotent** (the timestamp changes);
that is a deliberate exception to Day 6's rule.

## Remediation: what to automate

| Drift type | Action |
| --- | --- |
| Config file edited by hand | **auto-heal** — re-run the playbook |
| Package auto-updated | auto-heal, but investigate why the repo moved |
| Security group changed in console | **escalate** — someone had a reason |
| Resource deleted by hand | escalate |
| ASG scaled | not drift — the ASG owns that number |
| Unknown resource appears | escalate, possibly adopt with `import` |

Rule: **auto-heal only what is idempotent, low-risk and reversible.** Everything
else becomes a ticket.

## The self-healing loop

```
cron / EventBridge
  └──▶ terraform plan -detailed-exitcode
         ├── 0 -> exit
         └── 2 -> open issue + tag resource "drift-detected"
  └──▶ ansible-playbook drift-check.yml
         └── changed>0 -> ansible-playbook <same roles> (real run)
                          -> notify with the diff
```

Two safety rails:

1. **Alert before you heal, at first.** Run in report-only mode for two weeks.
   You will discover that some "drift" is a legitimate local need, and you will
   add a variable for it.
2. **Never self-heal across environments.** A prod remediation job needs a
   separate, narrower credential.

## Scheduling

GitHub Actions:

```yaml
on:
  schedule:
    - cron: "17 * * * *"      # hourly at :17, not :00 - avoid thundering herd
  workflow_dispatch: {}
```

`workflow_dispatch` matters: you want to run drift detection on demand during an
incident, not wait for the next tick.

## Lab 25.1 — see drift detection work

```bash
cd ansible
ansible-playbook ../labs/local/lab.yml > /dev/null     # converge
ansible-playbook playbooks/drift-check.yml --limit lab
```

The drift play runs in `check_mode: true`. On a converged host it reports
`changed=0`. Now create drift and find it:

```bash
rm -rf ~/tf-ansible-lab
ansible-playbook playbooks/drift-check.yml --limit lab    # changed > 0
```

## Lab 25.2 — build the gate

```bash
cat > /tmp/drift-gate.sh <<'SH'
#!/usr/bin/env bash
set -uo pipefail
cd ansible
ansible-playbook playbooks/drift-check.yml --limit lab | tee /tmp/drift.log >/dev/null
if grep -qE "changed=[1-9]" /tmp/drift.log; then
  echo "DRIFT DETECTED on:"
  grep -E "changed=[1-9]" /tmp/drift.log
  exit 2
fi
echo "no drift"
SH
chmod +x /tmp/drift-gate.sh
bash /tmp/drift-gate.sh; echo "exit=$?"
```

Exit 2 is the signal your scheduler should alert on.

## Lab 25.3 — the deliberate failure: a false positive

Add a timestamp to a lab file and watch drift detection scream forever:

```bash
ansible lab -m copy -a "content='{{ ansible_date_time.iso8601 }}' dest=/tmp/always-changes mode=0644"
```

Every run reports `changed`. That is not drift — it is a non-idempotent task.
Before you build an alerting pipeline, **make your roles idempotent**, or you will
drown in noise and turn the alert off.

## Exercises

1. Add a `--diff` run to the drift gate and attach the diff to the alert.
2. Write the Terraform half of the gate using `-detailed-exitcode`, and make it
   post the plan to a New Relic custom event (Day 26).
3. Add an "auto-heal with a limit" step that remediates at most 10% of hosts per
   run, so a bad playbook cannot rewrite the whole fleet at once.

## Gotchas

- Check mode is a **simulation**. Modules that shell out cannot predict their own
  effect, so `--check` can report no drift while real drift exists.
- Fact caching can hide drift: a cached `ansible_facts` is an hour old.
- Auto-healing a host that a human is actively debugging will destroy their work.
  Add a "maintenance mode" marker file the playbook respects.
- Terraform drift on an ASG's `desired_capacity` is expected — that is why
  `ignore_changes = [desired_capacity]` exists.
- Drift detection requires read credentials; remediation requires write. Do not
  give the detection job write access.

## Check yourself

- [ ] `/tmp/drift-gate.sh` exits 0 when converged and 2 when drifted
- [ ] You can list three drift types that must never be auto-healed
- [ ] Your roles are idempotent enough to alert on

**Next:** [Day 26 — Observability of the Pipeline Itself](day26-observability-pipeline-newrelic.md)
