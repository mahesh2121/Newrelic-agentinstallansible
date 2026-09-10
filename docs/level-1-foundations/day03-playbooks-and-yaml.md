# Day 3 — Playbooks, Plays and YAML

**Level 1** · ~75 min · Prereqs: Day 2

## What you will be able to do

- Structure a playbook into plays, tasks, modules
- Use `--check`, `--diff`, `--limit`, `--tags` and `-v`
- Read a PLAY RECAP and know what it does *not* tell you
- Run the course lab and prove it is idempotent

## Concepts

### Anatomy

```yaml
---
- name: Configure baseline on all managed hosts   # play
  hosts: servers:lab                              # target group(s)
  gather_facts: true
  become: true                                    # privilege escalation
  tasks:
    - name: Install baseline packages             # task
      ansible.builtin.package:                    # module (FQCN)
        name: curl
        state: present
```

Three levels: **playbook → play → task**. A play is "these hosts, this state".
A task is one module invocation.

`hosts: servers:lab` means the union of both groups (colon = union in a hosts
pattern). Other patterns: `servers:!staging`, `newrelic_*`, `web[0]`.

### FQCN is not pedantry

`ansible.builtin.package` vs `package`. The short form works, but the fully
qualified collection name tells you where the module comes from — which matters
when `community.general.package` and `ansible.builtin.package` behave differently.
`ansible-lint` enforces it, and this repo passes `--profile production`.

### `become`

```ini
[privilege_escalation]
become = True
become_method = sudo
```

is set in `ansible/ansible.cfg`, so every task runs as root unless you say
otherwise. To opt a task out: `become: false`. Forgetting this is why people
wonder why their lab playbook writes to `/root`.

## Lab 3.1 — run the course lab

```bash
cd ansible
ansible-playbook ../labs/local/lab.yml
```

Real output (truncated):

```
TASK [Create lab directory tree] *********************
changed: [lab-local] => (item=/root/tf-ansible-lab)
changed: [lab-local] => (item=/root/tf-ansible-lab/etc)
...
TASK [Attempt an operation that can fail] ************
fatal: [lab-local]: FAILED! => {"rc": 1, ...}
TASK [Handle the failure] ****************************
ok: [lab-local] => {"msg": "Rescued - the file is missing, ..."}
RUNNING HANDLER [Show handler fired] *****************
ok: [lab-local] => {"msg": "monitoring config changed -> handler ran exactly once"}

PLAY RECAP *******************************************
lab-local : ok=6  changed=4  unreachable=0  failed=0  skipped=0  rescued=1  ignored=0
```

Notice `failed=0` even though a task genuinely failed — the `rescue` block caught
it. That is Day 5's topic, and it is already running.

## Lab 3.2 — prove idempotency

Run it again immediately:

```bash
ansible-playbook ../labs/local/lab.yml
```

Expected: `changed=0` for the file/directory tasks. The `block/rescue` demo still
reports `rescued=1` because the command it runs is *designed* to fail.

**This is the single most important habit in Ansible:** run twice, and the second
run must be `changed=0`. If it is not, you have a task that will churn forever,
trigger handlers every time, and hide real drift.

## Lab 3.3 — the four flags you will use every day

```bash
# what WOULD change, without changing anything
ansible-playbook ../labs/local/lab.yml --check

# show me the actual line-by-line difference
ansible-playbook ../labs/local/lab.yml --diff

# only some hosts
ansible-playbook playbooks/configure.yml --limit lab

# only some tasks
ansible-playbook playbooks/newrelic.yml --tags nr_config --list-tasks
```

`--check` is a **best-effort simulation**, not a guarantee. Modules that only
read state report accurately; modules that shell out cannot know what would
happen. Never treat `--check` as proof — Day 20 covers real testing.

`--check` + `--diff` together is the closest thing Ansible has to
`terraform plan`. Use them before every production run.

## Lab 3.4 — the deliberate failure

Create a file with a tab in it and watch the error:

```bash
printf -- '---\n- hosts: localhost\n  tasks:\n\t- name: bad\n\t  debug:\n\t    msg: hi\n' > /tmp/bad.yml
ansible-playbook -i localhost, -c local /tmp/bad.yml
```

```
ERROR! Syntax Error while loading YAML.
  found character '\t' that cannot start any token
```

YAML forbids tabs for indentation. Your editor must insert spaces. Set it once
and stop thinking about it.

Second deliberate failure — the invisible one:

```bash
ansible-playbook -i localhost, /home/you/probe.yml     # no -c local
```

```
fatal: [localhost]: UNREACHABLE! => {"msg": "Failed to connect to the host via
ssh: Host key verification failed."}
```

`-i localhost,` is a host list, not an inventory file, and the default connection
is `ssh`. Add `-c local`. This exact failure was hit while writing this course.

## Exercises

1. Add a task to `labs/local/lab.yml` that writes the current date into a file.
   Run twice. Why is it `changed=1` both times, and how do you fix that?
   (Answer: `changed_when: false`, or make the content static.)
2. Make `labs/local/lab.yml` fail hard instead of rescuing, by removing the
   `rescue` section. Confirm `failed=1`.
3. Run `ansible-playbook playbooks/site.yml --list-tasks` and count the plays.
   Explain why `site.yml` uses `import_playbook` instead of one big play.

## Gotchas

- Strings that look like numbers/booleans need quotes: `mode: "0644"` not
  `mode: 0644` (which YAML reads as octal-ish and Ansible rejects), and
  `version: "1.0"` not `version: 1.0`.
- `ansible.builtin.debug` with `msg:` is fine, but `var:` is better for
  structured data: `- debug: var=hostvars[inventory_hostname]`.
- A play with no matching hosts prints
  `[WARNING]: Could not match supplied host pattern` and exits 0. In CI, add
  `--limit` checks or use `ansible.builtin.assert` on `groups`.

## Check yourself

- [ ] Lab playbook runs twice with `changed=0` on the second run
- [ ] You can explain `--check` vs `--diff` vs a real test
- [ ] You know why `-i localhost,` needs `-c local`

**Next:** [Day 4 — Variables & Vault](day04-variables-and-vault.md)
