# Role: hardening

Security baseline, all of it behind flags so you can adopt it one control at a time.

| Flag | Default | Effect |
| --- | --- | --- |
| `hardening_manage_sshd` | `true` | `sshd_config.d` drop-in, validated with `sshd -t` |
| `hardening_manage_unattended_upgrades` | `false` | installs automatic security updates |
| `hardening_manage_fail2ban` | `false` | installs fail2ban + `jail.local` |

> **Order matters.** Never enable `PasswordAuthentication no` before your SSH key
> is on the box - see the `users` role and Day 16. Ansible runs `validate:`
> before writing, so a syntax error can never lock you out with a broken config.

```bash
ansible-playbook playbooks/hardening.yml --limit lab -e hardening_manage_sshd=false --diff
```
