#!/usr/bin/env bash
# Managed by Terraform - modules/compute/templates/user_data.sh.tpl
#
# SCOPE OF THIS SCRIPT IS DELIBERATELY TINY.
# user_data runs ONCE at instance creation and is never re-run, so it cannot be
# used to keep a host in a desired state. It only has to do enough for Ansible
# to connect; the ansible playbooks do everything else.
set -euxo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "bootstrap started $(date -u +%Y-%m-%dT%H:%M:%SZ)"

%{ for key in ansible_ssh_authorized_keys ~}
echo '${key}' >> /home/${bootstrap_user}/.ssh/authorized_keys
%{ endfor ~}

# Marker file: `wait_for` in playbooks/bootstrap.yml can watch for this instead
# of guessing how long a boot takes.
echo "bootstrap-complete" > /var/tmp/ansible-bootstrap-complete

echo "bootstrap finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
