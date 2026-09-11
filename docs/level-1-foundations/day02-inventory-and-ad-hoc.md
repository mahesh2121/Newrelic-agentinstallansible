# Day 2 — Inventory, Groups and Ad-hoc Commands

**Level 1** · ~75 min · Prereqs: Day 1

## What you will be able to do

- Write inventory in INI and YAML, and choose between them
- Model real fleets with groups, children and group variables
- Explain what `ansible-inventory --graph` is telling you
- Migrate this repo's legacy `inverntory.ini` safely

## The bug in this repo's history

This repository started life with two files. One was a 23-byte inventory:

```ini
[servers]
13.233.199.9
```

Note the filename: `inverntory.ini`. Not a joke — that is the actual filename,
and it is the single most common Ansible failure mode: **Ansible silently ignores
an inventory file it was not told about.** It does not warn that `inverntory.ini`
is unused; it just uses the default and finds no hosts.

The replacement is `ansible/inventory/hosts.yml`. The original file is still in
the repo so you can see where the course started.

## Concepts

### Inventory is a data model, not a host list

```yaml
all:
  children:
    servers:            # what a host IS
      hosts:
        web-01: {ansible_host: 10.0.11.41}
    lab:                # where it runs
      hosts:
        lab-local: {ansible_connection: local}
    newrelic_infra:     # what should be installed on it
      children:
        servers:
        lab:
```

`newrelic_infra` is the group the monitoring playbook targets. Adding a host to
`servers` automatically opts it into monitoring. That is the whole point of
groups: **playbooks target intent, not hostnames.**

### Groups: three useful axes

| Axis | Examples | Used by |
| --- | --- | --- |
| Role in the stack | `web`, `db`, `bastion` | role selection |
| Environment | `dev`, `staging`, `prod` | `--limit` |
| Desired state | `newrelic_infra`, `hardening` | playbook `hosts:` |

### Connection variables

| Variable | Meaning |
| --- | --- |
| `ansible_host` | real DNS/IP to connect to |
| `ansible_user` | SSH user |
| `ansible_connection` | `ssh` (default), `local`, `paramiko`, `winrm` |
| `ansible_ssh_common_args` | extra ssh flags, e.g. ProxyJump (Day 16) |
| `ansible_python_interpreter` | which Python to use on the target |

## Lab 2.1 — inspect the inventory

```bash
cd ansible
ansible-inventory --graph
```

Real output from this repository:

```
@all:
  |--@ungrouped:
  |--@servers:
  |  |--legacy-13-233-199-9
  |--@lab:
  |  |--lab-local
  |--@newrelic_infra:
  |  |--@servers:
  |  |  |--legacy-13-233-199-9
  |  |--@lab:
  |  |  |--lab-local
  |--@newrelic_apm:
  ...
```

Read it as a tree: `@newrelic_infra` contains `@servers` and `@lab`, so it has
two hosts. `@ungrouped` is empty, which is what you want — an ungrouped host
usually means a typo.

```bash
ansible-inventory --list --yaml        # full data model with variables
ansible-inventory --host lab-local     # one host's variables
```

## Lab 2.2 — the safety net that saves fleets

`ansible/ansible.cfg` contains:

```ini
[inventory]
unparsed_is_failed = True
```

Without it, `ansible-playbook -i inventry.yml site.yml` (typo) makes Ansible fall
back to the default inventory and quietly run against the wrong hosts — or none.
With it, Ansible **fails loudly**. Set this on every project.

Try it:

```bash
ansible-playbook -i does-not-exist.yml playbooks/verify.yml
```

## Lab 2.3 — ad-hoc commands you will actually use

```bash
# reachability
ansible lab -m ping

# what OS is it?
ansible lab -m setup -a 'filter=ansible_os_family'

# read a file
ansible lab -m slurp -a 'src=/etc/hostname'

# reboot (never do this ad-hoc in prod - Day 23 shows the safe way)
ansible servers -m reboot --become

# the most useful debugging flag in Ansible
ansible lab -m ping -vvv
```

`-vvv` shows the SSH command, the module JSON shipped to the host, and the raw
response. When something is inexplicable, `-vvv` is not optional.

## Lab 2.4 — the deliberate failure

```bash
ansible servers -m ping
```

This targets the legacy host `13.233.199.9`, which is not reachable from your
machine. You get `UNREACHABLE`. Now run:

```bash
ansible servers -m ping -e ansible_connection=local
```

It succeeds — but notice what just happened: you told Ansible to treat a remote
host as local. That is exactly how people accidentally configure the wrong
machine. **`-e` overrides everything**, including safety. Day 4 explains the
precedence that makes this possible.

## Exercises

1. Convert `ansible/inventory/hosts.yml` to INI format in a scratch file. What do
   you lose? (Nested children and per-host variable types.)
2. Create `ansible/inventory/group_vars/lab.yml` with a variable
   `lab_marker: hello` and prove it reaches the host with
   `ansible-inventory --host lab-local`.
3. Write an inventory where `newrelic_apm` includes only hosts that also have a
   `apm_enabled: true` host var. Hint: you cannot — inventory groups are static.
   Explain what you would use instead (Day 15, dynamic inventory).

## Gotchas

- INI inventory cannot express nested groups or typed values. YAML can. Start
  with YAML.
- Group names with dashes work but are awkward in `group_vars/` filenames. Use
  underscores.
- `ansible_host` is not the same as the inventory hostname. The hostname is the
  identity used in hostvars and in New Relic (`display_name`); `ansible_host` is
  just where to connect.

## Check yourself

- [ ] `ansible-inventory --graph` runs and you can explain every line
- [ ] You can state why `unparsed_is_failed = True` matters
- [ ] You know which file to edit to add a host to monitoring

**Next:** [Day 3 — Playbooks & YAML](day03-playbooks-and-yaml.md)
