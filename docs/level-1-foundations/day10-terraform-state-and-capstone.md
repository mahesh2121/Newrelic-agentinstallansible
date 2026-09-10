# Day 10 — Terraform State and the Level 1 Capstone

**Level 1** · ~2–3 hours · Prereqs: Day 9

## What you will be able to do

- Inspect, move, import and untrack resources in state
- Explain why locking exists and how to recover a stuck lock
- Design the boundary between Terraform and Ansible
- Complete the Level 1 capstone

## State: what is actually in the file

```bash
terraform state list
terraform state show 'module.compute.aws_autoscaling_group.this'
terraform show -json
```

A state file is JSON with four sections that matter:

| Section | Content |
| --- | --- |
| `version`, `serial`, `lineage` | bookkeeping; `lineage` identifies *which* state this is |
| `outputs` | your `output` blocks — **this is what Day 15 uses for the Ansible bridge** |
| `resources` | every managed resource with all its attributes |
| `terraform_version` | the version that last wrote it |

`labs/local/sample.tfstate.json` in this repo is a realistic example, including
an `outputs.ansible_inventory_json` block. Open it — you will use it in Level 2.

## State operations

```bash
# rename without destroying
terraform state mv aws_instance.old aws_instance.new

# adopt something created by hand or by another tool
terraform import aws_instance.legacy i-0abc123

# stop managing something without deleting it
terraform state rm aws_instance.old

# find what drifted
terraform plan -refresh-only
```

Modern Terraform also has **`moved` and `import` blocks** in HCL, which are
reviewable in a PR instead of being one-off commands someone ran from a laptop:

```hcl
moved {
  from = aws_instance.web
  to   = aws_instance.app
}

import {
  to = aws_instance.legacy
  id = "i-0abc123"
}
```

Day 22 covers when to prefer blocks over commands.

## Locking

Two applies at once corrupt state. Locking prevents it:

- **Local state:** no locking. Two people on the same directory = corruption.
- **S3 backend:** a DynamoDB (or S3-native) lock record.

```
Error acquiring the state lock
Lock Info:
  ID:        1a2b3c...
  Path:      newrelic-fleet/dev/terraform.tfstate
  Operation: OperationTypeApply
  Who:       someone@laptop
  Version:   1.9.0
  Created:   2026-09-10 12:00:00 +0000 UTC
```

Recovery, in order of preference:

1. Find who holds it and ask them to stop.
2. If the process is dead: `terraform force-unlock <LOCK_ID>`.
3. **Never** delete the lock record by hand without confirming the process is dead.

## The Terraform / Ansible boundary

The question every team gets wrong at first: *how much should user_data do?*

```
Terraform owns                    Ansible owns
──────────────────────────────    ──────────────────────────────
VPC, subnets, route tables        packages, config files, services
security groups, IAM roles        users, SSH keys, sudoers
launch template, ASG, ALB         New Relic agents and integrations
key pair                          hardening, patching
outputs -> inventory              verification and reporting
```

**user_data owns exactly one thing: make the host reachable by Ansible.**

It runs once per instance and is never re-run, so it cannot maintain state. The
template in `terraform/modules/compute/templates/user_data.sh.tpl` does three
things: append SSH keys, log to `/var/log/user-data.log`, and drop a marker file
`/var/tmp/ansible-bootstrap-complete` that `playbooks/bootstrap.yml` can wait for.
Day 16 goes deeper.

## Lab 10.1 — inspect a state file offline

```bash
python3 - <<'PY'
import json
s = json.load(open("labs/local/sample.tfstate.json"))
print("serial   :", s["serial"])
print("lineage  :", s["lineage"])
print("outputs  :", list(s["outputs"]))
hosts = s["outputs"]["ansible_inventory_json"]["value"]["all"]["children"]["servers"]["hosts"]
print("hosts    :", len(hosts))
for name, hv in hosts.items():
    print(f"  {name:34s} {hv['ansible_host']:12s} {hv['availability_zone']}")
PY
```

You should see 3 hosts. That is the raw material of Day 15.

## Lab 10.2 — the full Ansible side, end to end

```bash
cd ansible
ansible-playbook ../labs/local/lab.yml        # 1st run: changed=4
ansible-playbook ../labs/local/lab.yml        # 2nd run: changed=0
ansible-lint                                  # must pass
ansible-playbook playbooks/site.yml --list-tasks
```

Expected from the second run:

```
lab-local : ok=5  changed=0  unreachable=0  failed=0  rescued=1  ignored=0
```

(`rescued=1` is the deliberate-failure demo, not a problem.)

## Lab 10.3 — prove the whole repo is healthy

```bash
cd Newrelic-agentinstallansible
ansible-lint -c ansible/.ansible-lint ansible/       # or: cd ansible && ansible-lint
yamllint .
checkov --config-file .checkov.yaml
python3 tools/hcl_parse_check.py
bash labs/local/mock_bridge.sh
```

All five should pass. That is this repository's CI (Day 19).

## Level 1 capstone

Build, from scratch, in a directory of your own:

1. An inventory with three groups: `web`, `db`, `monitoring` (where `monitoring`
   contains both).
2. A role `webserver` with `defaults/`, `tasks/`, `handlers/`, `templates/`,
   `meta/` that writes an nginx-style config and would restart a service on change.
3. A role `agent` that writes a fake monitoring config to
   `~/capstone/etc/agent.yml` with mode `0600`, using variables for at least four
   settings.
4. A playbook `site.yml` that applies both roles to `monitoring`.
5. A Terraform file that declares two variables, one resource, and an `output`
   exporting a dict shaped like an Ansible inventory.

**Acceptance criteria — all must hold:**

- [ ] `ansible-playbook site.yml` runs twice; second run `changed=0`
- [ ] `ansible-lint` passes on your directory
- [ ] The rendered config file is mode `0600`
- [ ] Changing one variable in `group_vars` changes the rendered file
- [ ] `python3 tools/hcl_parse_check.py yourdir` parses your HCL
- [ ] You can explain, out loud, why the agent restart is a handler and not a task

If any box is unticked, re-read the relevant day. Do not start Level 2 with a
shaky Level 1 — Level 2 assumes every habit above is automatic.

## Exercises

1. Write `moved` and `import` blocks for a resource you renamed. Explain why the
   block form is safer in a team.
2. Corrupt `labs/local/sample.tfstate.json` (delete a brace) and observe how
   `ansible/inventory/terraform.py` reports the failure.
3. Add an output to `terraform/environments/dev/outputs.tf` that exports only the
   bastion host as an inventory fragment.

## Gotchas

- `terraform state rm` does not delete the resource; it just forgets it. The next
  `apply` will try to create a duplicate.
- Workspaces share one backend path prefix. Mixing workspace state with
  per-environment directories is a common source of confusion (Day 21).
- `terraform output` on an unapplied config returns nothing — the bridge in
  Day 15 depends on a successful apply.

## Check yourself

- [ ] All five verification commands pass
- [ ] Capstone acceptance criteria all ticked
- [ ] You can state the Terraform/Ansible boundary in one sentence

**Next:** [Day 11 — Terraform Modules](../level-2-integration/day11-terraform-modules.md)
