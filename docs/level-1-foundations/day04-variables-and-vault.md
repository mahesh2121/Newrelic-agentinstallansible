# Day 4 — Variables, Precedence and Vault

**Level 1** · ~75 min · Prereqs: Day 3

## What you will be able to do

- Predict which value wins when a variable is defined in five places
- Store a New Relic license key safely and use it in a template
- Explain why `-e "key={'a':1}"` silently produces a string
- Debug an undefined variable

## Precedence, lowest to highest (the part that matters)

```
role defaults              roles/<role>/defaults/main.yml   ← weakest, meant to be overridden
inventory group_vars/all   ansible/inventory/group_vars/all.yml
inventory group_vars/<grp> ansible/inventory/group_vars/servers.yml
inventory host_vars        ansible/inventory/host_vars/<host>.yml
play vars                  vars: in the play
role vars                  roles/<role>/vars/main.yml       ← stronger than inventory
block/task vars            vars: on the task
extra vars                 -e / --extra-vars                ← always wins
```

Two things surprise people:

1. **Role `vars/` beats inventory `group_vars/`.** If you cannot override a role
   variable from inventory, it is probably in `vars/` — move it to `defaults/`.
2. **`-e` cannot be overridden by anything**, including `when:` conditions you
   wrote for safety. That is a feature and a footgun.

## Lab 4.1 — prove precedence with your own eyes

```bash
cd ansible
# group_vars/all.yml defines:  common_timezone: UTC
ansible-inventory --host lab-local | grep -i timezone
```

Now override it three ways and watch each one win:

```bash
# 1. from the command line
ansible lab -m debug -a "msg={{ common_timezone }}" -e common_timezone=Asia/Kolkata

# 2. from a host var file
mkdir -p inventory/host_vars
echo "common_timezone: Europe/Berlin" > inventory/host_vars/lab-local.yml
ansible-inventory --host lab-local | grep -i timezone
rm inventory/host_vars/lab-local.yml
```

## Lab 4.2 — the `-e` type trap (reproduced while writing this course)

```bash
ansible lab -m debug -a "msg={{ d }}" -e "d={'a': 1}"
```

You get a **string**, not a dict. Any template calling `.items()` on it dies with:

```
object of type 'str' has no attribute 'items'
```

The fix is a vars **file**, which preserves types:

```bash
cat > /tmp/vars.yml <<'EOF'
---
d:
  a: 1
EOF
ansible lab -m debug -a "msg={{ d }}" -e @/tmp/vars.yml
```

This is exactly what `labs/local/mock_bridge.sh` does: it writes an
`overrides.yml` and passes `-e @overrides.yml`. Use `-e @file` whenever a value is
a list or a dict.

## Lab 4.3 — encrypt the license key

The infrastructure agent needs a license key in `/etc/newrelic-infra.yml`. That
file is `0600` on the host (`newrelic_infra_config_mode`), and the key must never
be committed.

```bash
cd ansible
ansible-vault create inventory/group_vars/vault.yml
# prompt: set a password
```

Contents:

```yaml
---
vault_newrelic_license_key: YOUR-REAL-LICENSE-KEY
vault_newrelic_api_key: NRAK-XXXXXXXX
vault_newrelic_account_id: "1234567"
```

`inventory/group_vars/all.yml` wires it up:

```yaml
newrelic_license_key: "{{ vault_newrelic_license_key | default('') }}"
```

The `default('')` matters: the variable resolves even when the vault is locked,
which lets `--check` and linting run without secrets. The role then fails fast
with a clear message if the key is empty (`roles/newrelic_infra/tasks/main.yml`).

Use it:

```bash
ansible-vault view inventory/group_vars/vault.yml
ansible-vault edit inventory/group_vars/vault.yml
ansible-playbook playbooks/newrelic.yml --limit lab --ask-vault-pass --check
```

In CI, use `--vault-password-file` with a secret, or
`ansible-vault encrypt_string`. **Never** put the password in the playbook,
`ansible.cfg`, or git.

## Lab 4.4 — the deliberate failure: undefined variable

```bash
ansible lab -m debug -a "msg={{ nope_not_defined }}"
```

```
fatal: [lab-local]: FAILED! => {"msg": "The task includes an option with an
undefined variable. The error was: 'nope_not_defined' is undefined"}
```

Now the nastier version — a variable that is defined but wrong:

```yaml
- name: Render config
  ansible.builtin.template:
    src: x.j2
    dest: "{{ some_dir }}/x.conf"
```

If `some_dir` is undefined, the error points at the *task*, not the variable.
`-vvv` shows the resolved value. And `ansible-inventory --host <name>` is the
fastest way to see what Ansible actually believes.

## Lab 4.5 — variable naming rules

`ansible/inventory/hosts.yml` originally could have used `environment: dev` as a
host variable. It must not: `environment` is a **reserved Ansible keyword**, and
Ansible warns:

```
[WARNING]: Found variable using reserved name 'environment'.
```

This is a real bug this course caught in
`terraform/environments/dev/outputs.tf` — the Terraform output now emits
`env_name`, not `environment`. Other reserved names to avoid: `role`,
`connection`, `vars`, `when`, `tags`, `environment`, `async`, `delay`.

## Exercises

1. Add `newrelic_infra_custom_attributes: {team: sre}` to
   `inventory/group_vars/lab.yml`, then render the config with
   `bash labs/local/mock_bridge.sh` and find your attribute in the output file.
2. Encrypt a dummy value, then run a playbook **without** `--ask-vault-pass`.
   Read the error and explain it.
3. Move a variable from `roles/common/defaults/main.yml` to
   `roles/common/vars/main.yml` and prove that inventory can no longer override it.

## Gotchas

- Variables defined in `group_vars/all.yml` apply to `localhost` too, which
  surprises people running plays against `localhost`.
- `hostvars['other-host']['var']` only works if that host has been contacted or
  its facts cached.
- Jinja `{{ }}` inside a YAML value that starts with `{` must be quoted:
  `msg: "{{ x }}"`, not `msg: {{ x }}`.

## Check yourself

- [ ] You can list precedence from memory, at least the top and bottom three
- [ ] `vault.yml` exists, is encrypted, and the playbook runs with `--ask-vault-pass`
- [ ] You know why `-e @file` beats `-e "k={...}"`

**Next:** [Day 5 — Loops, Conditionals, Blocks](day05-loops-conditionals-blocks.md)
