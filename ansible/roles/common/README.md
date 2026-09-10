# Role: common

Baseline OS configuration applied to every managed host before anything else.

| Item | Path | Purpose |
| --- | --- | --- |
| defaults | `defaults/main.yml` | Lowest-precedence variables, safe to override |
| tasks | `tasks/main.yml` | Packages, timezone, NTP, MOTD, marker file |
| handlers | `handlers/main.yml` | Notified only on real change |
| templates | `templates/motd.j2` | Jinja2 banner rendered per host |

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `common_manage_timezone` | `true` | Set `false` in containers (no `timedatectl`) |
| `common_manage_motd` | `true` | Renders `common_motd_path` |
| `common_manage_ntp` | `true` | Enables `common_ntp_service` |
| `common_base_packages` | curl, wget, jq... | Set to `[]` to skip package management |
| `common_marker_dir` | `/etc/ansible-managed` | Drift evidence, see Day 25 |

## Feature flags

Every task that needs root or a systemd unit is gated by a boolean. That is what
lets the *same* role run against a production EC2 instance and against the local
lab group (`inventory/group_vars/lab.yml` flips the flags off).

## Try it

```bash
cd ansible
ansible-playbook playbooks/configure.yml --limit lab -t common --diff
```
