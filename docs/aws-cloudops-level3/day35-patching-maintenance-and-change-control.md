# Day 35 — Patching, Maintenance Windows and Change Control

**Level 3+ (AWS CloudOps)** · ~90 min · Prereqs: Day 34

Day 23 covered the *mechanics* of running Ansible across many hosts. This day is
about the operational wrapper: when changes are allowed, how a change window
works on an autoscaling fleet, and what you do when a change goes wrong.

## What you will be able to do

- Run a rolling patch that cannot take the fleet down, and explain why
- Choose between patching in place and replacing instances
- Define a change window that autoscaling will respect
- Roll back an Ansible change and a Terraform change, differently
- Find the one task in this repo that can hide a failure

## The patching playbook

`ansible/playbooks/patch.yml` is short enough to hold in your head:

```yaml
- name: Patch managed hosts in batches
  hosts: servers
  gather_facts: true
  serial: 2
  tags: patch
  tasks:
    - name: Upgrade security packages (Debian)
      ansible.builtin.apt:
        upgrade: safe
        update_cache: true
        cache_valid_time: 3600
      when: ansible_facts['pkg_mgr'] == 'apt'

    - name: Upgrade security packages (RedHat)
      ansible.builtin.dnf:
        name: "*"
        update_only: true
        security: true
        state: present
      when: ansible_facts['pkg_mgr'] in ['dnf', 'yum']

    - name: Check whether a reboot is required
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: patch_reboot_required

    - name: Reboot patched host and wait for it to return
      ansible.builtin.reboot:
        reboot_timeout: 600
        post_reboot_delay: 20
      when: patch_reboot_required['stat']['exists']

    - name: Ensure New Relic agent came back after reboot
      ansible.builtin.service:
        name: newrelic-infra
        state: started
      failed_when: false
```

Four decisions worth defending:

| Decision | Why |
| --- | --- |
| `serial: 2` | At most two hosts are patched at once. The rest keep serving. |
| `upgrade: safe` / `update_only: true, security: true` | Security updates only. `state: latest` would pull new packages and fail `ansible-lint`'s `package-latest` rule — and it would be right to fail it. |
| `stat` then `reboot` when the marker exists | Reboots only when the distro says one is needed, instead of always. |
| `reboot` module, not `command: reboot` | It waits for the host to come back, with `post_reboot_delay` so the agent has time to start. |

### `serial` and the blast radius

`serial: 2` on a fleet of 10 means five batches. On a fleet of 2 it means
**everything at once**. That is the trap: the same playbook is safe at 50 hosts
and unsafe at 2.

The correct setting for an autoscaling fleet is a percentage, not a number:

```yaml
serial: "25%"
```

Now the blast radius is proportional to the fleet, and the ASG's
`min_healthy_percentage = 50` (set in `terraform/modules/compute/main.tf`) and
the playbook's `serial` are two limits doing the same job. Pick one to be
authoritative and write down which. If Ansible reboots 25% at a time while the
ASG considers below 50% healthy to be a failure, you are fine. If the two
numbers ever cross, the ASG starts replacing hosts that Ansible is mid-reboot
on — and the resulting log is genuinely confusing.

## Deliberate failure — the task that cannot fail

Look at the last task again:

```yaml
    - name: Ensure New Relic agent came back after reboot
      ansible.builtin.service:
        name: newrelic-infra
        state: started
      failed_when: false
```

`failed_when: false` means this task reports `ok` whether the agent is running,
dead, or not installed at all. Now imagine the sequence: a kernel update reboots
the host, the agent fails to start, and `patch.yml` finishes with
`failed=0`.

The patch window closes. The report says success. And you now have hosts that are
patched, healthy according to the load balancer, and **invisible to monitoring** —
the exact failure the `agent_not_reporting` condition exists to catch, arriving
in a batch, at a time when everyone has gone home.

**Why it is written this way.** It is not a mistake so much as a compromise: the
playbook targets `hosts: servers`, and during the local lab the agent is not
installed at all (`newrelic_infra_install_packages: false` in
`ansible/inventory/group_vars/lab.yml`). Without `failed_when: false`, the lab
run would fail on a host that was never supposed to have the agent.

**The fix is not to delete it.** It is to separate "did the patch apply?" from
"is the host observable?" — they are different questions with different owners:

```bash
ansible-playbook playbooks/patch.yml --limit servers
ansible-playbook playbooks/verify.yml --limit servers   # this one is allowed to fail
```

`ansible/playbooks/verify.yml` runs `ansible/roles/verify_agents/tasks/main.yml`,
which asserts the package is installed, the service is `running`, and the config
file exists with a mode in `['0600', '0400', '0640']`. Those are real
assertions. Chaining the two commands is what makes the patch window honest.

**Prevention.** Grep for the pattern and review every hit:

```bash
grep -rn "failed_when: false" ansible/
```

Each occurrence is a decision that some failure does not matter. Most are
legitimate — decommissioning a host that is already gone, for instance. None of
them should be unreviewed.

## Patch, or replace?

On an autoscaling fleet you have a genuine choice, and the answer is usually
"replace":

| | Patch in place (`patch.yml`) | Replace via instance refresh |
| --- | --- | --- |
| Speed per host | Minutes | Minutes, but parallel and rolling |
| Drift risk | You learn what drifted | None — new instance from the launch template |
| Kernel updates | Needs a reboot | Free |
| Rollback | Hard: you cannot un-patch | Trivial: roll the launch template back |
| Requires | SSH reachability | Nothing but the ASG |
| Right for | Long-lived hosts, the bastion, stateful things | The app fleet |

The bastion is the exception that proves the rule. It is a single, long-lived
instance created by `aws_instance.bastion` in
`terraform/modules/compute/main.tf`, not part of the ASG. You cannot roll it.
Patch it — in a window, with someone watching, because losing it means losing
your SSH path.

## The change window

A window on an autoscaling fleet has three parts people forget:

1. **Freeze autoscaling.** Scheduled scaling actions and target-tracking policies
   will launch and terminate instances during your window. A host launched
   mid-window gets `$Latest` of the launch template and none of your in-flight
   changes.
2. **Announce the inventory, not just the time.** "Patching 14:00–16:00" is not
   actionable. "Patching the hosts in
   `ansible/inventory/generated/dev.yml`, 25% at a time" is.
3. **Define the abort condition before you start.** Not after the first failure.

A minimum viable window:

```bash
# 0. snapshot the current truth
cd terraform/environments/dev && terraform output ansible_hostnames > /tmp/fleet-before.txt

# 1. what will change, on one host first
cd ../../ansible
ansible-playbook playbooks/patch.yml --limit <canary-host> --diff

# 2. verify the canary is observable before continuing
ansible-playbook playbooks/verify.yml --limit <canary-host>

# 3. the rest, in batches
ansible-playbook playbooks/patch.yml --limit servers --forks 5

# 4. prove it, all of it
ansible-playbook playbooks/verify.yml --limit servers

# 5. what exists now
cd ../terraform/environments/dev && terraform output ansible_hostnames > /tmp/fleet-after.txt
diff /tmp/fleet-before.txt /tmp/fleet-after.txt
```

Step 5 is the one everyone skips and everyone regrets. If the hostnames changed,
the ASG replaced something during your window, and you need to know before you
close the change rather than after.

## Rollback: the two tools differ

| | Terraform | Ansible |
| --- | --- | --- |
| Rollback mechanism | Revert the commit, `plan`, `apply` the saved plan | Revert the commit, re-run the playbook |
| State to unwind | Yes — resources may have been created | No — configuration is convergent |
| Time to safe | Minutes, if the plan is clean | One run |
| Dangerous case | A resource that cannot be reverted (destroyed data) | A task that is not idempotent |

Ansible rollback is cheap *because* the playbooks are convergent: re-running the
previous version restores the previous state. That is only true while every task
is idempotent, which is what `make idempotency` in the `Makefile` asserts — run
the lab twice and require `changed=0` on the second run.

Terraform rollback is expensive when the plan is not a pure revert. Read the
plan. If reverting a commit says `destroy` on something with data in it, the
rollback is not a rollback; it is a new project.

## Lab (no AWS account required)

1. See exactly which hosts each playbook would touch, without touching them:

   ```bash
   cd ansible
   ansible-playbook playbooks/patch.yml --list-hosts --limit servers
   ansible-playbook playbooks/drift-check.yml --list-hosts --limit lab
   ```

2. Run the drift detector against the local lab:

   ```bash
   ansible-playbook playbooks/drift-check.yml --limit lab
   ```

3. Audit every suppressed failure in the repo:

   ```bash
   grep -rn "failed_when: false" ansible/ | wc -l
   ```

4. Prove the idempotency gate still passes after your edits:

   ```bash
   cd .. && make idempotency
   ```

## Exercises

1. Change `serial: 2` to a percentage and justify the number against the ASG's
   `min_healthy_percentage = 50`.
2. Split the agent check out of `patch.yml` entirely and chain
   `verify.yml` after it in the deploy path.
3. Add a scheduled scaling action that pauses scale-out during the patch window,
   managed by Terraform so the window is reviewable in a PR.
4. Write the abort condition for your patch window as a single command that can
   be run mid-window to decide whether to continue.

## Gotchas

- `serial` applies per play, and a play that fails with `any_errors_fatal`
  stops the remaining batches. Decide deliberately which you want.
- `cache_valid_time: 3600` means the apt cache may be an hour stale. For a
  same-day CVE, run `update_cache: true` with no valid-time window.
- The `reboot` module's `reboot_timeout: 600` will fail the host if the kernel
  update triggers a slow `initramfs` rebuild. That is a real failure, not a
  timeout to be tuned away.
- A host that is `--limit`ed out of the patch run does not get patched. Track
  coverage as a percentage of the fleet, not as "the run was green".
- `ansible/playbooks/decommission.yml` refuses to run without `--limit`. Keep
  that assertion; it is the cheapest safety mechanism in the repo.

## Check yourself

- [ ] You can explain why `serial: 2` is unsafe on a two-host fleet
- [ ] You know which task can hide a failure and how you compensate for it
- [ ] You can say when to patch and when to replace
- [ ] You know the three things a change window must freeze or record

**Next:** [Day 36 — Cost, Budgets and Governance](day36-cost-budgets-and-governance.md)
