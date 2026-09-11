# Role: users

Creates the automation account that Ansible itself will use on the next run, so
you can stop logging in as `ubuntu`/`ec2-user`.

* `users_deploy_user` (default `deploy`) is created and added to `sudo`
* `users_ssh_authorized_keys` installs your **public** keys with `exclusive: true`
  so removed keys actually disappear
* a `visudo -cf`-validated sudoers drop-in grants (passwordless) sudo

> Day 16 shows the chicken-and-egg problem this solves: Terraform hands you a
> cloud default user, you bootstrap `deploy`, then every later playbook targets
> `deploy`.

```bash
ansible-playbook playbooks/bootstrap.yml --limit lab -e users_sudoers_path=$HOME/lab-sudoers
```
