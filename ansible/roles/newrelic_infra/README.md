# Role: newrelic_infra

The reason this repository exists: install, configure and **prove** the New Relic
infrastructure agent is running.

## Task flow

```
tasks/main.yml
├── assert license key present        (fail fast, clear message)
├── include_tasks: repo.yml           GPG key + apt/yum repository
├── package: newrelic-infra           pinned or `present`
├── file: config/var/log dirs
├── template: newrelic-infra.yml      mode 0600 -> notify handler
├── service: enable + start
└── include_tasks: verify.yml         -validate, log scan, summary
```

## Why the config file is `0600`

`newrelic-infra.yml` contains the license key. Anyone who can read it can send
data to your account and inflate your bill. `newrelic_infra_config_mode` defaults
to `0600` and the template is rendered by root only.

## Tags

| Tag | Scope |
| --- | --- |
| `nr_repo` | Repository + GPG key only |
| `nr_package` | Package install/upgrade |
| `nr_config` | Config file + directories |
| `nr_service` | systemd enable/start |
| `nr_verify` | Post-install verification |

```bash
ansible-playbook playbooks/newrelic.yml --limit servers -t nr_config --diff --check
```

## Lab mode

`newrelic_infra_install_packages: false` (set in `group_vars/lab.yml`) renders
the config into a user-writable directory and skips package/service tasks. That
is how Day 8 exercises the template without root or internet access.

## Unverified in the sandbox

`download.newrelic.com` and `docs.newrelic.com` were unreachable from the
environment where this repo was generated, so the repository URLs, GPG key path
and config key names must be confirmed on a host with internet access:

```bash
curl -sSI https://download.newrelic.com/infrastructure_agent/linux/apt/dists/ | head -1
newrelic-infra -h | grep -i validate
```
