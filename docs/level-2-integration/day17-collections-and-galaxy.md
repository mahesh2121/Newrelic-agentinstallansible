# Day 17 — Collections, Galaxy and the Official New Relic Role

**Level 2** · ~75 min · Prereqs: Day 16

## What you will be able to do

- Explain the module/role/collection hierarchy
- Pin dependencies with `requirements.yml`
- Compare this repo's role with the official `newrelic.newrelic_install`
- Decide when to vendor and when to consume

## The hierarchy

```
collection                     e.g. community.general, amazon.aws, newrelic.newrelic_install
├── modules                    executable code shipped to the host
├── roles                      task bundles
├── plugins                    inventory, callback, lookup, filter, connection
└── playbooks
```

`ansible-core` ships `ansible.builtin` only. Everything else — `amazon.aws.ec2_instance`,
`community.general.ufw`, `ansible.posix.authorized_key`, the `yaml` stdout
callback, the `profile_tasks` callback — comes from a collection.

## This repo's deliberate constraint

**Everything in `ansible/` uses `ansible.builtin` only.** Two consequences you
have already seen:

1. `stdout_callback = yaml` is commented out in `ansible/ansible.cfg`. Enabling it
   without `community.general` produces:
   ```
   [ERROR]: Could not load 'yaml' callback plugin.
   ```
   and — worse — the playbook prints nothing and exits 0.
2. `roles/users` renders `authorized_keys` from a template instead of using
   `ansible.posix.authorized_key`.

Is that the right long-term choice? No. It is the right choice for a **teaching
repo that must run anywhere**: one `pip install ansible-core` and every lab works.
For a production fleet, collections give you better modules.

## requirements.yml

```yaml
# ansible/requirements.yml
collections:
  - name: ansible.posix
    version: ">=1.5.0"
  - name: community.general
    version: ">=8.0.0"
  - name: amazon.aws
    version: ">=7.0.0"
  - name: newrelic.newrelic_install
    version: ">=1.0.0"

roles:
  - name: geerlingguy.ntp
    version: "2.4.0"
```

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml -p ./collections
ansible-galaxy role install -r requirements.yml -p ./roles
ansible-galaxy collection list | head
```

`collections_path = ./collections` is set in `ansible.cfg`, so vendored
collections live inside the repo. **Commit the lock, not necessarily the
collections** — `requirements.yml` in git, `collections/` in `.gitignore`, and CI
installs on every run.

> **Sandbox note:** `galaxy.ansible.com` was unreachable from the environment
> where this repo was generated (TLS connection closed). The install commands
> above are standard, but the exact available versions must be confirmed on a
> machine with internet access.

## Why pin

`ansible-galaxy install community.general` without a version pulls whatever is
latest. A new minor version can change a module's defaults. In CI that means a
green build on Monday and a red one on Tuesday with no code change. Pin, and
bump deliberately.

## The official New Relic role

New Relic publishes `newrelic.newrelic_install`. Roughly:

```yaml
- hosts: servers
  roles:
    - role: newrelic.newrelic_install
      vars:
        newrelic_license_key: "{{ vault_newrelic_license_key }}"
        newrelic_agent_type: infrastructure
```

Compare with `roles/newrelic_infra` in this repo:

| | Official role | This repo's role |
| --- | --- | --- |
| Maintained by | New Relic | you |
| Agent types | infra, APM, integrations | infra, APM, integrations (separate roles) |
| Config source | its own variables | your `group_vars` + templates |
| Customisation | limited to its variables | total |
| Verification | minimal | `roles/verify_agents` + NR API check |
| Dependencies | collections | `ansible.builtin` only |

**Which should you use?** Start with the official role. Move to your own when you
need something it cannot express — custom config keys, an internal package
mirror, an air-gapped install path, or verification that fails the deploy.

A hybrid is common and is what this repo effectively demonstrates: use the
official role for the package, keep your own thin role for configuration and
verification.

## When to vendor

| Situation | Do this |
| --- | --- |
| Role is stable, widely used | Consume from Galaxy, pinned |
| You need 3 lines changed | Fork, vendor, document why |
| You need behaviour the author won't take | Vendor permanently |
| It is your company's core competency | Own role in your own repo |

Whatever you choose: **write down the decision**. `ansible/roles/*/README.md`
files in this repo do that.

## Lab 17.1 — audit what this repo actually uses

```bash
cd Newrelic-agentinstallansible
grep -rho "ansible\.[a-z_]*\.[a-z_]*" ansible/roles ansible/playbooks | sort | uniq -c | sort -rn
```

Every result should start with `ansible.builtin.`. If you see anything else, a
collection is required and the lab will fail on a bare install.

## Lab 17.2 — module documentation is offline

```bash
ansible-doc ansible.builtin.template
ansible-doc ansible.builtin.service
ansible-doc -l ansible.builtin | wc -l
```

`ansible-doc` reads from the installed package — no internet needed. Use it
instead of guessing module parameters.

## Lab 17.3 — the deliberate failure

Enable the pretty callback and watch a run produce **no output at all**:

```bash
cd ansible
sed -i 's/^# stdout_callback = yaml/stdout_callback = yaml/' ansible.cfg
ansible-playbook ../labs/local/lab.yml
```

```
[WARNING]: Error loading plugin 'community.general.yaml': No module named 'ansible_collections.community'
[ERROR]: Could not load 'yaml' callback plugin.
```

…and nothing else. Exit code 0. In CI this is a **silent green build that did
nothing**. Restore:

```bash
sed -i 's/^stdout_callback = yaml/# stdout_callback = yaml/' ansible.cfg
```

## Exercises

1. Install `ansible.posix` and rewrite the `authorized_keys` task with
   `authorized_key`. Which version is more readable? Which is more portable?
2. Add `newrelic.newrelic_install` to `requirements.yml` and write a play that
   uses it for the package while keeping this repo's role for config.
3. Pin `community.general` and then bump it. Read the changelog for one module you
   use and describe what changed.

## Gotchas

- `collections_path` in `ansible.cfg` is relative to the config file.
- Two collections can provide a module with the same short name. Always use FQCN.
- `ansible-galaxy` needs network access; CI should cache `./collections`.
- Roles installed into `./roles` can shadow roles of the same name in your repo.
  Keep third-party roles in a distinct directory.

## Check yourself

- [ ] Every module reference in `ansible/` is `ansible.builtin.*`
- [ ] You can explain why the callback is commented out
- [ ] You have a written answer for "official role or our own?"

**Next:** [Day 18 — New Relic Agents End to End](day18-newrelic-agents-end-to-end.md)
