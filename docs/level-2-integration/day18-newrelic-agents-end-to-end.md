# Day 18 — New Relic Agents End to End, and Proving It Works

**Level 2** · ~2 hours · Prereqs: Day 17

## What you will be able to do

- Install and configure the infrastructure agent with Ansible
- Configure APM language agents and on-host integrations
- Distinguish four levels of "the agent works"
- Fail a deploy when monitoring is not actually reporting

## The four agents

| Agent | What it monitors | Where it configures |
| --- | --- | --- |
| Infrastructure | host metrics: CPU, memory, disk, processes | `/etc/newrelic-infra.yml` |
| APM | your application's transactions | `newrelic.ini` / `newrelic.js` / env vars |
| On-host integrations (`nri-*`) | nginx, postgres, custom commands | `/etc/newrelic-infra/integrations.d/` |
| Browser / mobile | front-end | not this repo |

Roles: `roles/newrelic_infra`, `roles/newrelic_apm`, `roles/newrelic_integrations`,
`roles/verify_agents`.

## Infrastructure agent: the flow

```
tasks/main.yml
├── assert license key present          fail fast with a readable message
├── include_tasks: repo.yml             GPG key + apt/yum repository
├── package: newrelic-infra
├── file: config / var / log dirs
├── template: newrelic-infra.yml        mode 0600 -> notify handler
├── service: enable + start
└── include_tasks: verify.yml           -validate, log scan, summary
```

### The config

```yaml
license_key: <from vault>
display_name: newrelic-fleet-dev-app-4d5e6f
verbose: 0
log:
  file: /var/log/newrelic-infra/newrelic-infra.log
  level: info
custom_attributes:
  env: "dev"
  region: "ap-south-1"
  managed_by: "ansible"
labels:
  env: "dev"
  tier: "app"
passthrough_environment:
  - NRIA_CUSTOM_ATTRIBUTES
  - AWS_REGION
```

That is real rendered output from `labs/local/mock_bridge.sh`.

Three decisions to note:

- **`display_name` comes from Terraform** — the instance-derived hostname. This is
  what you will search for in the New Relic UI, so making it match your inventory
  saves real debugging time.
- **`custom_attributes` and `labels` are both rendered.** `custom_attributes` is
  the current spelling; `labels` is legacy but still works, and dashboards that
  filter on `labels` keep working during a migration. Delete `labels` when the
  migration is done.
- **Mode `0600`.** The file holds the license key.

> **Unverified in the sandbox:** `download.newrelic.com` and
> `docs.newrelic.com` were unreachable when this repo was generated, so the
> repository URLs, GPG key path and config key names must be confirmed against
> current New Relic documentation on a host with internet access:
> ```bash
> curl -sSI https://download.newrelic.com/infrastructure_agent/linux/apt/dists/ | head -1
> newrelic-infra -h | grep -i validate
> ```

## APM agents

`roles/newrelic_apm` renders three artefacts:

- `newrelic.ini` — Python agent (`NEW_RELIC_CONFIG_FILE` points at it)
- `newrelic.js` — Node agent
- `newrelic.env` — `NEW_RELIC_*` variables for a systemd `EnvironmentFile`

```ini
[newrelic]
license_key = <from vault>
app_name = newrelic-fleet-dev
monitor_mode = true
distributed_tracing.enabled = true
```

Many teams prefer env vars over files — `newrelic_apm_write_env_file: true`
supports both. The env file sets the ingest host by account region:

```
NEW_RELIC_HOST={{ 'collector.eu01.nr-data.net' if newrelic_account_region == 'EU' else 'collector.nr-data.net' }}
```

## On-host integrations

`roles/newrelic_integrations` drops definition files into
`/etc/newrelic-infra/integrations.d/`. The infrastructure agent discovers and runs
them — no extra service, no extra port.

```yaml
integrations:
  - name: fleet-uptime
    interval: 30s
    labels:
      env: "dev"
    commands:
      - run:
          command: /usr/bin/uptime
          event_type: FleetUptimeSample
```

The role declares a dependency on `newrelic_infra` in `meta/main.yml`, so
ordering is guaranteed.

## Four levels of "it works"

This is the part most teams skip, and it is the reason "the playbook succeeded but
New Relic is empty" happens.

| Level | Check | What it proves |
| --- | --- | --- |
| 1 | package installed | the RPM/DEB is there |
| 2 | service `running` | systemd thinks it is up |
| 3 | config sane | file exists, mode 0600, parses |
| 4 | **data arriving** | New Relic knows about this host |

Only level 4 is proof. `roles/verify_agents/tasks/main.yml` implements 1–3 and has
level 4 behind a flag:

```yaml
- name: Query New Relic API for this host
  ansible.builtin.uri:
    url: "{{ newrelic_verify_api_base_url }}/applications.json"
    headers:
      X-Api-Key: "{{ newrelic_verify_api_key }}"
    status_code: 200
  delegate_to: localhost
  become: false
  when:
    - newrelic_verify_api_enabled | bool
    - newrelic_verify_api_key | length > 10
  no_log: true
```

Note `no_log: true` — the API key must not land in your CI log.

A stronger version of level 4 uses NerdGraph (Day 26):

```
{ actor { account(id: 1234567) { nrql(query:
  "SELECT latest(timestamp) FROM SystemSample WHERE entity.name = 'my-host'") {
    results } } } }
```

If `latest(timestamp)` is older than 5 minutes, monitoring is broken — fail the
deploy.

## Lab 18.1 — render everything locally

```bash
bash labs/local/mock_bridge.sh
```

Read sections 5, 6 and 7. You should see the agent config with
`custom_attributes`, `labels` and `passthrough_environment`, the integration
definition, and three `PASS` lines.

## Lab 18.2 — the phases, independently

```bash
cd ansible
ansible-playbook playbooks/newrelic.yml --limit lab -t nr_config --diff --check
ansible-playbook playbooks/newrelic.yml --limit lab -t nr_verify --check
ansible-playbook playbooks/verify.yml --limit lab
```

`verify.yml` prints a per-host summary:

```
"lab-local -> package=skipped, service=skipped, config=skipped"
```

(`skipped` in the local lab because `newrelic_infra_install_packages: false`; on a
real host you get `ok`.)

## Lab 18.3 — the deliberate failure: a bad license key

The role asserts before doing anything:

```bash
ansible-playbook playbooks/newrelic.yml --limit lab \
  -e newrelic_infra_install_packages=true
```

```
newrelic_infra_license_key is empty. Put it in an ansible-vault file, e.g.
ansible-vault create inventory/group_vars/vault.yml with
vault_newrelic_license_key: <key> and run with --ask-vault-pass.
```

A readable failure at task 1 beats a cryptic one at task 40.

The second failure mode is worse because it is silent: a *wrong* key. The agent
installs, starts, and reports nothing. That is what `verify.yml`'s log scan is
for:

```yaml
- name: Assert no fatal errors in agent log
  ansible.builtin.assert:
    that:
      - "'license key is not valid' not in (newrelic_infra_log['content'] | b64decode | lower)"
```

## Lab 18.4 — permissions check

```bash
bash labs/local/mock_bridge.sh 2>&1 | grep "newrelic-infra.yml"
```

```
-rw------- 1 root root 504 .../newrelic-infra.yml
```

If you ever see `0644` here, someone changed `newrelic_infra_config_mode`. Fix it
before the license key leaks.

## Exercises

1. Add a `nri-nginx` integration definition for hosts in a `web` group.
2. Make `verify.yml` fail the play when `newrelic_verify_api_enabled` is true and
   the host is missing from the API response.
3. Add an assert that `newrelic_apm_app_name` never contains a space.
4. Pin the agent version in prod (`newrelic_infra_agent_state: "1.60.0"`) and
   explain why pinning matters for reproducibility.

## Gotchas

- The agent restarts when config changes. If you run this playbook hourly, a
  non-idempotent template causes an hourly restart — Day 6.
- `passthrough_environment` only forwards variables the agent process can see. A
  variable set in your shell is not visible to a systemd service.
- EU accounts need EU ingest endpoints. US keys against EU endpoints report
  nothing, silently.
- Agent upgrades can change config key support. Pin the version, read the
  changelog, and validate in dev first.

## Check yourself

- [ ] `mock_bridge.sh` prints three `PASS` lines
- [ ] You can list the four levels of verification and say which one matters
- [ ] You know why the config file is `0600`

**Next:** [Day 19 — CI/CD](day19-cicd-pipeline.md)
