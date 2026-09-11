# Day 6 — Handlers, Idempotency and Tags

**Level 1** · ~75 min · Prereqs: Day 5

## What you will be able to do

- Use handlers so services restart only when configuration changes
- Explain the two guards every handler in this repo has, and why
- Run a slice of work with tags
- Prove idempotency and read a recap critically

## Handlers

A handler is a task that runs **only if notified**, and **at most once per play**,
no matter how many tasks notify it.

```yaml
- name: Write newrelic-infra.yml
  ansible.builtin.template:
    src: newrelic-infra.yml.j2
    dest: "{{ newrelic_infra_config_path }}"
    mode: "{{ newrelic_infra_config_mode }}"
  notify: Restart newrelic-infra
```

```yaml
# roles/newrelic_infra/handlers/main.yml
- name: Restart newrelic-infra
  ansible.builtin.service:
    name: "{{ newrelic_infra_service_name }}"
    state: restarted
  when:
    - newrelic_infra_restart_on_config_change | bool
    - newrelic_infra_install_packages | bool
```

Three properties that make handlers worth it:

1. Config written five times in one play → **one** restart, at the end.
2. Config unchanged → **no** restart. No service blips during a no-op run.
3. Handlers run in the order they are **defined**, not notified.

### The two guards are battle scars

That `when:` clause is not decoration. While building this course the handler was
run in a lab where the agent package was not installed:

```
RUNNING HANDLER [newrelic_infra : Restart newrelic-infra]
fatal: [host]: FAILED! => {"msg": "Could not find the requested service newrelic-infra: host"}
```

The play had *already* done all its work; the handler then failed the run. Any
handler that touches a service must first confirm the service exists. Both
`roles/newrelic_infra` and `roles/newrelic_integrations` now carry this guard.

### Forcing and flushing

```bash
ansible-playbook playbooks/newrelic.yml --force-handlers   # run notified handlers even if a later task fails
```

```yaml
- name: Flush handlers before the play reports success
  ansible.builtin.meta: flush_handlers
```

`playbooks/configure.yml` flushes handlers so that a "success" recap really means
the service was restarted, not that the restart is pending.

## Idempotency

**Definition:** running the same playbook twice produces the same end state, and
the second run reports `changed=0`.

Why it matters beyond tidiness:

- A task that always reports `changed` fires its handler **every run** — your
  agents restart on every deploy.
- `changed` noise hides real drift (Day 25).
- Ansible Tower/AWX and CI treat unexpected changes as a signal.

### The three things that break idempotency

```yaml
# 1. command/shell without changed_when
- name: Check something
  ansible.builtin.command:
    cmd: some-tool --status
  changed_when: false                     # it only reads state

# 2. copy with dynamic content
- name: Write a stamp
  ansible.builtin.copy:
    content: "generated: {{ now() }}"     # changes every run!
    dest: /etc/stamp
    mode: "0644"

# 3. template with a timestamp
```

Note `roles/common/tasks/main.yml` writes a marker file containing
`ansible_date_time['iso8601']`. That is **deliberately** non-idempotent — it is an
audit record of when Ansible last ran, and Day 25 uses it. Know which of your
tasks are meant to change.

## Tags

Tags select work. `roles/newrelic_infra/tasks/main.yml` is tagged by phase:

| Tag | Scope |
| --- | --- |
| `nr_repo` | GPG key + repository |
| `nr_package` | install/upgrade |
| `nr_config` | config file + directories |
| `nr_service` | systemd |
| `nr_verify` | verification |

```bash
ansible-playbook playbooks/newrelic.yml --list-tags
ansible-playbook playbooks/newrelic.yml --tags nr_config --diff --check
ansible-playbook playbooks/newrelic.yml --skip-tags nr_repo
```

Tagging rules that keep them useful:

- Tag **roles** in the play (`- role: common, tags: common`) so you can run one
  role from a multi-role play.
- Tag **phases** inside a role when a phase is independently useful.
- Do not tag every task. If everything is tagged, nothing is.

Gotcha: tags apply to `include_tasks` but **static** `import_tasks` inherits tags
differently. Prefer `include_tasks` when you want to tag the included file.

## Lab 6.1 — watch a handler fire once

```bash
cd ansible
ansible-playbook ../labs/local/lab.yml
```

Look for:

```
TASK [Render fleet-wide monitoring config] ***
changed: [lab-local]
...
RUNNING HANDLER [Show handler fired] ********
ok: [lab-local] => {"msg": "monitoring config changed -> handler ran exactly once"}
```

Now run it again. The template reports `ok` (no change), and the handler **does
not run at all**. That is the whole point.

## Lab 6.2 — run a slice

```bash
ansible-playbook playbooks/configure.yml --limit lab --tags common --diff
```

Then check what you skipped:

```bash
ansible-playbook playbooks/configure.yml --limit lab --list-tasks
```

## Lab 6.3 — the deliberate failure

Break idempotency on purpose:

```bash
ansible lab -m copy -a "content={{ ansible_date_time['iso8601'] }} dest=/tmp/stamp mode=0644"
```

Run it twice: `changed=1` both times. Now make it idempotent with static content
and confirm `changed=0` on the second run. You have just felt the difference
between a playbook you can run daily and one you cannot.

## Exercises

1. Add a handler to `labs/local/lab.yml` that is notified by two tasks. Prove it
   runs once.
2. Add `changed_when: false` to every `command` task in
   `roles/firewall/tasks/main.yml` that currently reports changes on a healthy
   host, and justify each one in a comment.
3. Create a tag `audit` that runs only the read-only verification tasks, and run
   it with `--check`.

## Gotchas

- Handlers are **not** run on hosts where the play failed earlier, unless
  `--force-handlers`.
- A handler name must match the `notify` string exactly — a typo silently does
  nothing. Run with `-vv` to see "NOTIFIED HANDLER" lines.
- `state: reloaded` is not supported by all services; `restarted` is safer.

## Check yourself

- [ ] Second run of the lab shows no handler execution
- [ ] You can name the two guards on the newrelic_infra handler and why they exist
- [ ] You can run only the `nr_config` phase

**Next:** [Day 7 — Roles Anatomy](day07-roles-anatomy.md)
