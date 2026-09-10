# Day 7 — Roles: Anatomy and Design

**Level 1** · ~90 min · Prereqs: Day 6

## What you will be able to do

- Read and write every directory of a role
- Explain `defaults` vs `vars` and choose correctly
- Declare role dependencies and metadata
- Design a role that runs on a server *and* in a container

## Why roles

A 600-line playbook is unmaintainable. Roles give you:

- **Namespacing:** tasks appear as `newrelic_infra : Write newrelic-infra.yml`
- **Defaults:** overridable variables in one obvious place
- **Reusability:** the same role in many plays and repos
- **Shareability:** publishable to Ansible Galaxy

## Anatomy, with this repo's files

```
ansible/roles/newrelic_infra/
├── defaults/main.yml      lowest-precedence variables
├── meta/main.yml          galaxy info + dependencies
├── tasks/main.yml         entry point
│   ├── repo.yml           included: repository setup
│   └── verify.yml         included: post-install proof
├── handlers/main.yml      restart on config change
└── templates/newrelic-infra.yml.j2
```

Optional and unused here: `vars/`, `files/`, `library/`, `module_utils/`, `tests/`.

### `defaults/main.yml` — the contract

```yaml
newrelic_infra_license_key: "{{ newrelic_license_key | default('') }}"
newrelic_infra_config_mode: "0600"        # file contains the license key
newrelic_infra_install_packages: true
newrelic_infra_service_enabled: true
```

Rules:

- Everything overridable lives here. **Nothing secret.**
- Every variable is prefixed with the role name (`newrelic_infra_*`) so two roles
  never collide. `ansible-lint`'s `var-naming` rule enforces this; this repo
  relaxes it only for genuinely shared `newrelic_*` vars (see `.ansible-lint`).
- Defaults must be safe. A default of `true` for `install_packages` means a
  careless run installs software.

### `meta/main.yml` — metadata and dependencies

```yaml
galaxy_info:
  role_name: newrelic_infra
  namespace: newrelic_fleet
  min_ansible_version: "2.15"
  platforms:
    - name: Ubuntu
      versions: [jammy, noble]
    - name: EL
      versions: ["8", "9"]
dependencies: []
```

`roles/newrelic_integrations/meta/main.yml` declares a real dependency:

```yaml
dependencies:
  - role: newrelic_infra
```

so integrations always run after the agent. Dependencies run **before** the
depending role, once per play.

### `tasks/main.yml` — orchestration

`roles/newrelic_infra/tasks/main.yml` does five things and delegates two:

```yaml
- name: Assert New Relic license key is available     # fail fast
- name: Include repository setup                       # -> tasks/repo.yml
- name: Install New Relic infrastructure agent package
- name: Write newrelic-infra.yml                       # -> notify handler
- name: Enable and start the infrastructure agent
- name: Verify the agent                               # -> tasks/verify.yml
```

Splitting `repo.yml` out is not tidiness — it lets you skip it
(`--skip-tags nr_repo`) on air-gapped hosts that install from an internal mirror.

## include_tasks vs import_tasks

| | `import_tasks` (static) | `include_tasks` (dynamic) |
| --- | --- | --- |
| Parsed | at playbook load | at runtime |
| `--list-tasks` shows | every inner task | only the include |
| Tags inherit | yes, to inner tasks | to the include itself |
| Loops | limited | fully supported |
| Variables in the path | resolved late | resolved at runtime |

Rule: use `include_tasks` when the path or content depends on runtime facts; use
`import_tasks` when you want static analysis and tags to reach inner tasks.

## The design pattern that makes roles testable

Every risky task in this repo is behind a boolean:

```yaml
- name: Enable and start the infrastructure agent
  ansible.builtin.service:
    name: "{{ newrelic_infra_service_name }}"
    state: "{{ newrelic_infra_service_state }}"
    enabled: "{{ newrelic_infra_service_enabled }}"
  when: newrelic_infra_install_packages | bool
```

`inventory/group_vars/lab.yml` flips them off:

```yaml
newrelic_infra_install_packages: false
newrelic_infra_service_enabled: false
newrelic_infra_config_dir: "{{ ansible_user_dir }}/lab-newrelic"
```

Result: **the same role** installs an agent on a production EC2 instance and
renders a config file in your home directory in the lab. Without feature flags,
you can only test roles against real servers, so you test them rarely, so they
break.

## Lab 7.1 — read a role before you run it

```bash
cd ansible
ansible-playbook playbooks/newrelic.yml --limit lab --list-tasks
```

Every task is prefixed with its role. Read the list top to bottom — that is the
role's contract.

```bash
ansible-playbook playbooks/newrelic.yml --limit lab --list-tags
ansible-doc ansible.builtin.template     # module documentation, offline
```

## Lab 7.2 — override a default

```bash
ansible-playbook playbooks/newrelic.yml --limit lab --check --diff \
  -e newrelic_infra_log_level=debug -e newrelic_infra_verbosity=3
```

Then confirm the override reached the rendered file by running the bridge lab
(Day 15) with the same extra vars.

## Lab 7.3 — the deliberate failure

Put a variable in `vars/` instead of `defaults/` and try to override it:

```bash
mkdir -p roles/common/vars
echo "common_timezone: Asia/Tokyo" > roles/common/vars/main.yml
ansible-inventory --host lab-local | grep -i timezone   # inventory still says UTC
ansible lab -m debug -a "msg={{ common_timezone }}"     # but the role sees Tokyo
rm -rf roles/common/vars
```

That mismatch — inventory says one thing, the role uses another — is one of the
hardest Ansible bugs to diagnose. **If a variable should be overridable, it
belongs in `defaults/`.**

## Exercises

1. Write a new role `roles/audit` with one task that writes
   `/etc/ansible-managed/audit.txt`, complete with `defaults/`, `meta/` and a
   README. Add it to `playbooks/configure.yml`.
2. Make `roles/common` depend on nothing but `roles/hardening` depend on
   `common`. Prove the ordering with `--list-tasks`.
3. Convert `roles/newrelic_infra/tasks/repo.yml` from `include_tasks` to
   `import_tasks`. What breaks with `--skip-tags nr_repo`? (Answer: nothing
   breaks, but tags now propagate into the file's tasks — usually what you want.
   Try it.)

## Gotchas

- A role's `defaults` are the **weakest** variables in Ansible. Do not put
  anything there you would be upset to see overridden.
- Role names with dashes need `roles/<name-with-dash>` on disk but are referenced
  with the same dashes; underscores are simpler.
- `ansible-lint` requires `meta/main.yml` for publishable roles (`meta-no-info`).
  Include it even for internal roles.

## Check yourself

- [ ] You can draw the role directory layout from memory
- [ ] You know why `install_packages: false` makes the lab possible
- [ ] `--list-tasks` shows role-prefixed task names

**Next:** [Day 8 — Templates & Jinja2](day08-templates-jinja2.md)
