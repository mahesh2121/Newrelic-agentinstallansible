# Day 16 — Bootstrap, user_data and ProxyJump

**Level 2** · ~90 min · Prereqs: Day 15

## What you will be able to do

- Split work correctly between user_data and Ansible
- Bootstrap a host that has no Python and no deploy user
- Reach private instances through a bastion
- Decide between push, pull and baked-AMI strategies

## The chicken-and-egg problem

Terraform hands you a running instance. To configure it with Ansible you need:

1. SSH reachability — the instance is in a **private** subnet
2. A user with your key — only the AMI default user exists
3. Python on the host — most modules need it
4. The host in your inventory — Day 15, which needs the instance to exist

`playbooks/bootstrap.yml` solves 2–4. The bastion solves 1.

## Phase 1 — facts off, raw on

```yaml
- name: Wait for freshly provisioned hosts
  hosts: servers
  gather_facts: false        # <-- critical
  become: false
  tasks:
    - name: Wait for SSH to accept connections
      ansible.builtin.wait_for_connection:
        timeout: "{{ bootstrap_wait_timeout }}"
        delay: 10

    - name: Test raw connectivity before gathering facts
      ansible.builtin.raw: echo bootstrap-ok
      register: bootstrap_raw
      changed_when: false
```

Why `gather_facts: false`? Gathering facts **requires Python** on the target. On
a minimal AMI it may be absent, and fact gathering fails with an obscure error.
`raw` executes over SSH with no Python at all — that is what makes bootstrapping
possible.

Then install Python:

```yaml
    - name: Ensure Python 3 is present (required by most Ansible modules)
      ansible.builtin.raw: >-
        test -e /usr/bin/python3 ||
        (apt-get update -qq && apt-get install -y -qq python3) 2>/dev/null ||
        (dnf install -y -q python3) 2>/dev/null ||
        (yum install -y -q python3) 2>/dev/null || true
      changed_when: "'Setting up python3' in bootstrap_python.stdout"
```

Ugly, portable, and it works on Ubuntu, RHEL and Amazon Linux. Once Python
exists, everything else is normal Ansible.

## Phase 2 — the deploy user

```yaml
- name: Create the deploy user and baseline access
  hosts: servers
  gather_facts: true
  roles:
    - role: users
```

`roles/users` creates `deploy`, installs your **public** keys and writes a
`visudo -cf`-validated sudoers drop-in. After this play, every later run can
target `deploy` instead of the AMI default user.

The key-rendering task replaces the whole file:

```yaml
- name: Render authorized_keys for deploy user
  ansible.builtin.template:
    src: authorized_keys.j2
    dest: "{{ users_deploy_user_home }}/.ssh/authorized_keys"
    mode: "0600"
```

Whole-file rendering is deliberately "exclusive": remove a key from
`users_ssh_authorized_keys` and it disappears on the next run. (`ansible.posix.authorized_key`
does this too, but requires a collection — see Day 17 for why this repo avoids
them.)

### The lockout warning

`roles/hardening` sets `PasswordAuthentication no`. If you enable that **before**
your key is on the box, you are locked out. Order matters:

```
users (keys) ──▶ hardening (disable passwords)
```

Never the reverse. This is why `playbooks/site.yml` imports bootstrap before
configure, and why `ansible.builtin.template` uses `validate: visudo -cf %s` —
a malformed sudoers file can never be written, so it can never lock you out.

## Phase 3 — reaching private instances

### ProxyJump via inventory

```yaml
# inventory/group_vars/servers.yml
ansible_user: ubuntu
ansible_ssh_common_args: "-o StrictHostKeyChecking=accept-new -J ubuntu@bastion.example.com"
```

Or per host:

```yaml
newrelic-fleet-dev-app-1a2b3c:
  ansible_host: 10.0.11.41
  ansible_ssh_common_args: "-J ubuntu@203.0.113.10"
```

The bridge already emits the bastion's public IP
(`module.compute.bastion_inventory_host`), so you can build this string from
Terraform data instead of hard-coding it.

### ProxyJump via ssh_config (cleaner for humans)

```
Host bastion
    HostName 203.0.113.10
    User ubuntu
    IdentityFile ~/.ssh/newrelic-fleet

Host 10.0.*
    User ubuntu
    ProxyJump bastion
    IdentityFile ~/.ssh/newrelic-fleet
```

Then Ansible needs no special flags at all.

### ControlMaster: the 10x speedup

`ansible/ansible.cfg`:

```ini
[ssh_connection]
pipelining    = True
ssh_args      = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=30
control_path  = /tmp/ansible-%%h-%%r
```

`ControlMaster` reuses one SSH connection for all tasks on a host; `pipelining`
avoids writing module files to disk. On a 200-host run this is the difference
between minutes and tens of minutes. `%%` is escaping for Ansible's own `%`
substitution.

## Three delivery strategies

| Strategy | How it works | Freshness | Best for |
| --- | --- | --- | --- |
| **Push** (this repo) | control node runs playbooks over SSH | on demand / on event | most fleets |
| **Pull** | `ansible-pull` cron on each host | up to cron interval | huge fleets, no inbound SSH |
| **Baked AMI** | Packer runs Ansible at image build | at image build | immutable infrastructure |

Production answer is usually **baked + push**: Packer bakes the baseline and the
agent package; Ansible push handles configuration that varies per host and
remediates drift.

`terraform/modules/compute/variables.tf` already has the hook:

```hcl
variable "ansible_pull_url" {
  description = "Optional git URL for ansible-pull. Empty = push mode only."
  type        = string
  default     = ""
}
```

## The marker-file pattern

user_data writes `/var/tmp/ansible-bootstrap-complete`. Then:

```yaml
- name: Wait for bootstrap to finish
  ansible.builtin.wait_for:
    path: /var/tmp/ansible-bootstrap-complete
    timeout: 600
```

Watching a file beats guessing a sleep duration, and it gives you a definitive
answer when the boot is stuck: if the marker never appears, read
`/var/log/user-data.log`.

## Lab 16.1 — read the bootstrap playbook

```bash
cd Newrelic-agentinstallansible
cat ansible/playbooks/bootstrap.yml
cat ansible/roles/users/tasks/main.yml
cat terraform/modules/compute/templates/user_data.sh.tpl
```

Trace one host's first 60 seconds: user_data → SSH up → `wait_for_connection` →
`raw` → Python → `users` role.

## Lab 16.2 — practise the "no Python" path locally

```bash
cd ansible
ansible lab -m raw -a 'echo works-without-python'
ansible lab -m setup -a 'filter=ansible_python_version'
```

`raw` and `setup` behave differently; on a host without Python only `raw` works.

## Lab 16.3 — the deliberate failure

Simulate an unreachable host and watch `wait_for_connection` time out:

```bash
ansible lab -m wait_for_connection \
  -e ansible_connection=ssh -e ansible_host=10.255.255.1 \
  -e ansible_user=nobody
```

Read the error. In production this is what "the ASG launched an instance but
bootstrap never ran" looks like, and the next step is always
`/var/log/user-data.log` on that instance (or the EC2 system log in the console).

## Exercises

1. Add a task that waits for the marker file instead of a fixed delay.
2. Emit `ansible_ssh_common_args` from Terraform, using the bastion's public IP.
   What breaks if the bastion is replaced?
3. Convert `playbooks/bootstrap.yml` into a pull-mode cron job. What do you have
   to solve about secrets?

## Gotchas

- `gather_facts: true` on a host without Python produces
  `MODULE FAILURE ... /usr/bin/python: No such file or directory`. Set
  `ansible_python_interpreter` or bootstrap Python first.
- `wait_for_connection` waits for **Ansible** to work, not for the OS to boot.
  Use `wait_for` on the marker file for the latter.
- ControlMaster sockets in `/tmp` can survive a crashed run and confuse the next
  one. `rm /tmp/ansible-*` is a legitimate fix.
- SSH key rotation must update user_data **and** running hosts; user_data only
  affects new instances.

## Check yourself

- [ ] You can explain why `gather_facts: false` + `raw` is required
- [ ] You know the correct ordering of `users` before `hardening`
- [ ] You can reach a private host through a bastion two different ways

**Next:** [Day 17 — Collections & Galaxy](day17-collections-and-galaxy.md)
