# Day 32 — EC2 and ASG Operations

**Level 3+ (AWS CloudOps)** · ~2 hours · Prereqs: Day 31

Level 2 built the ASG. This day is about the ten things you actually do to it in
production, and the two that will bite you.

## What you will be able to do

- Replace, scale and refresh instances without an outage
- Read the ASG configuration in `terraform/modules/compute/main.tf` and predict
  what AWS will do to your hosts
- Diagnose a host that boots but never becomes healthy
- Explain why an edit to `user_data` reaches nothing until you say so

## What the ASG is actually configured to do

From `terraform/modules/compute/main.tf`:

```hcl
resource "aws_autoscaling_group" "this" {
  name_prefix         = "${local.name_prefix}-asg-"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  target_group_arns = [aws_lb_target_group.this.arn]
  health_check_type = "ELB"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}
```

Five lines in that block decide your operational life:

| Setting | What it means at 3 a.m. |
| --- | --- |
| `health_check_type = "ELB"` | A host is unhealthy when the **load balancer** says so, not when EC2 says so. A host with a dead application gets replaced even though the OS is fine. |
| `version = "$Latest"` | New instances always get the newest launch template version. **Running instances never change.** |
| `instance_refresh` / `Rolling` / `50` | A refresh replaces instances in waves, keeping half healthy. With `min_size = 1` in dev, 50% rounds up to one healthy instance at all times. |
| `ignore_changes = [desired_capacity]` | Terraform will not fight autoscaling. If the ASG scaled to 3, `terraform apply` will not drag it back to `desired_capacity`. |
| `create_before_destroy` | Replacing the ASG builds the new one first. Combined with `name_prefix`, that is why the ASG name has a random suffix. |

`ignore_changes = [desired_capacity]` is the one that surprises people. It means
`terraform plan` is **not** a complete description of your fleet size. To know
how many hosts exist, ask AWS — which is exactly what
`terraform/environments/dev/outputs.tf` does with `data.aws_instances.app`.

## The ten operations

### 1. How many hosts do I have, right now?

```bash
cd terraform/environments/dev
terraform output ansible_hostnames
terraform output autoscaling_group_name
```

Both come from `terraform/environments/dev/outputs.tf`. The second is the filter
the inventory uses; the first is the literal answer.

### 2. Give me an Ansible inventory of the live fleet

```bash
terraform/scripts/tf_to_inventory.py -o ansible/inventory/generated/dev.yml
cd ansible && ansible-inventory -i inventory/generated/dev.yml --graph
```

The generated file is git-ignored and carries a `GENERATED FILE - DO NOT EDIT`
banner. Manual edits are lost on the next run — put permanent host variables in
`ansible/inventory/group_vars/servers.yml` instead.

### 3. Reach a new host

```bash
cd ansible && ansible-playbook playbooks/bootstrap.yml --limit servers
```

`ansible/playbooks/bootstrap.yml` uses `wait_for_connection` with
`timeout: "{{ bootstrap_wait_timeout }}"` (600 seconds, from
`ansible/inventory/group_vars/all.yml`), then `raw` to test connectivity *before*
gathering facts — because a fresh Ubuntu instance may not have Python yet.

### 4. Replace one unhealthy host

Terminate it. The ASG replaces it, and the replacement comes from `$Latest`:

```bash
aws ec2 terminate-instances --instance-ids i-0123456789abcdef
```

This is the correct answer far more often than people expect. The hosts are
stateless by design; the agent configuration is in Git, applied by
`ansible/playbooks/newrelic.yml`.

### 5. Scale up for a known event

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name newrelic-fleet-dev-asg-xxxx \
  --desired-capacity 6 --max-size 8
```

Terraform will not undo it (`ignore_changes`), and Day 36 covers why you should
still record the intent somewhere.

### 6. Roll a change to every host

Editing the launch template does nothing to running instances. Start a refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name newrelic-fleet-dev-asg-xxxx
```

### 7. Patch

`ansible/playbooks/patch.yml` — Day 35.

### 8. Check for drift

```bash
cd ansible && ansible-playbook playbooks/drift-check.yml --limit servers --diff
```

### 9. Retire a host cleanly

```bash
cd ansible && ansible-playbook playbooks/decommission.yml --limit 10.0.1.23
```

`ansible/playbooks/decommission.yml` refuses to run without `--limit`. That
assertion is the cheapest guardrail in the repository.

### 10. Prove monitoring survived

```bash
cd ansible && ansible-playbook playbooks/verify.yml --limit servers
```

## Deliberate failure — the change that reached nothing

This is the failure that costs the most hours, and it fails *silently*.

You find a typo in `terraform/modules/compute/templates/user_data.sh.tpl`. You
fix it, commit, and run:

```bash
DRY_RUN=1 terraform/scripts/deploy.sh dev
```

The plan shows `aws_launch_template.this` will be updated **in-place**. You apply
it. Then you SSH to a host and the marker file is still missing.

**Diagnosis.** Three facts combine:

1. `user_data` runs once, at instance creation. It is not a configuration
   management tool and never re-runs.
2. The ASG references `version = "$Latest"`, which resolves **at instance launch
   time**, not continuously.
3. Updating a launch template does **not** start an instance refresh. AWS only
   starts one if you ask, or if you configure a scaling policy to.

So the fix landed in the template, and every running instance is still running
the old one. Nothing is broken — nothing *happened*.

**Fix.**

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name newrelic-fleet-dev-asg-xxxx \
  --preferences MinHealthyPercentage=50
```

**Prevention.** Make the invisible visible:

- Assert in CI that a launch-template change in the plan is accompanied by a
  refresh step in the runbook.
- Or better: keep `user_data` so small that a stale copy never matters. This
  repo already does that — the template only appends SSH keys and writes
  `/var/tmp/ansible-bootstrap-complete`. Everything else is Ansible, and Ansible
  re-runs.

The general rule: **anything that must stay true belongs in Ansible; anything
that must happen once belongs in `user_data`.** Day 16 argued this; Day 32 is
where you feel it.

## Diagnosing a host that boots but never becomes healthy

`health_check_type = "ELB"` means the target group decides. Work the chain from
the outside in:

| Step | Command / place | What a failure tells you |
| --- | --- | --- |
| 1. Is the instance running? | `aws ec2 describe-instance-status` | An EC2 problem, not an app problem |
| 2. Did `user_data` finish? | `/var/log/user-data.log` on the host | Bootstrap crashed; the marker file will be absent |
| 3. Is the target registered? | `aws elbv2 describe-target-health` | The app is not listening on the target group port |
| 4. Is the app answering? | The ALB target group health check path | Application-level failure |
| 5. Did Ansible ever run? | `ansible/playbooks/verify.yml` | The pipeline never reached this host |

Note step 2: the template redirects everything with
`exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1` and ends by
writing `/var/tmp/ansible-bootstrap-complete`. Both exist precisely so you can
answer "did bootstrap finish?" with one command instead of guessing.

### A gap to close

The ASG sets no `health_check_grace_period`. The default is 300 seconds. A host
that takes longer than that to pass the ELB health check — slow boot, slow
package install — can be terminated and replaced, repeatedly, in a loop that
looks exactly like "the ASG is flapping". If you see an instance churning, check
the grace period before you check anything else, and set it explicitly so the
value is in Git rather than in AWS's defaults.

## Lab (no AWS account required)

1. Confirm the ASG health check type and the launch template version pin without
   opening the console:

   ```bash
   grep -n 'health_check_type\|version *= *"\$Latest"\|instance_refresh' \
     terraform/modules/compute/main.tf
   ```

2. Prove the inventory bridge works against the checked-in state fixture:

   ```bash
   terraform/scripts/tf_to_inventory.py \
     --state-file labs/local/sample.tfstate.json --stdout
   ```

   Three hosts come out, each with `instance_id`, `availability_zone` and
   `env_name` attached. Those host variables are what Day 34 uses to join AWS
   data to New Relic data.

3. Run the whole bridge end to end:

   ```bash
   bash labs/local/mock_bridge.sh
   ```

4. Show what `bootstrap.yml` would wait for:

   ```bash
   cd ansible && ansible-playbook playbooks/bootstrap.yml --syntax-check
   grep -n 'bootstrap_wait_timeout' inventory/group_vars/all.yml
   ```

## Exercises

1. Add `health_check_grace_period` to the ASG with a value justified in a
   comment, and explain in the PR why 300 is wrong for this stack.
2. Change `version = "$Latest"` to `$Default`, and write down what you now have
   to do to roll a change. Which is safer, and for whom?
3. Write a runbook for "the ASG is flapping" that a new on-call engineer can
   follow without asking you a question.
4. Add a scheduled scaling action for a nightly batch window, and make it
   Terraform-managed so the schedule is reviewable.

## Gotchas

- `$Latest` and `$Default` are resolved at launch, not continuously. Neither is
  a deployment mechanism.
- `terminate-instance-lifecycle` with `--should-decrement-desired-capacity`
  permanently shrinks the fleet. That is a capacity decision, not a reboot.
- Termination protection is **not** set on the app instances in this module.
  For the bastion, that is worth adding — losing it means losing your only SSH
  path.
- An instance refresh in progress blocks another one. Check
  `describe-instance-refreshes` before you assume your refresh was ignored.
- `data.aws_instances.app` in `terraform/environments/dev/outputs.tf` filters on
  `instance_state_names = ["running", "pending"]`. A host in `stopping`
  disappears from the inventory, which is correct but can look like data loss.

## Check yourself

- [ ] You can state, without looking, why a launch template edit changes nothing
- [ ] You can name the command that actually rolls a change
- [ ] You know the five ASG settings that decide your 3 a.m.
- [ ] You can trace a never-healthy host through all five steps

**Next:** [Day 33 — State, Storage, Backup and Recovery](day33-state-storage-backup-and-recovery.md)
