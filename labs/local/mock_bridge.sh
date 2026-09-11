#!/usr/bin/env bash
# Day 15 lab: prove the Terraform -> Ansible bridge WITHOUT an AWS account.
#
# It uses a sample terraform.tfstate (labs/local/sample.tfstate.json) as a
# stand-in for a real apply, generates the inventory exactly the way
# terraform/scripts/tf_to_inventory.py would, then runs the real newrelic.yml
# playbook against it. Every host is redirected to localhost so the run is safe.
#
#   bash labs/local/mock_bridge.sh
#
# What this proves:
#   * the Terraform output shape is valid Ansible inventory
#   * ansible/inventory/terraform.py produces a working dynamic inventory
#   * roles/newrelic_infra renders a real agent config from generated host vars
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE="${REPO_ROOT}/labs/local/sample.tfstate.json"
WORKDIR="$(mktemp -d)"
INVENTORY="${WORKDIR}/generated-inventory.yml"

echo "==> 1. terraform state -> ansible inventory"
python3 "${REPO_ROOT}/terraform/scripts/tf_to_inventory.py" \
  --state-file "${STATE}" --output "${INVENTORY}"

echo
echo "==> 2. hosts Ansible discovered from the state file"
(cd "${REPO_ROOT}/ansible" && ansible-inventory -i "${INVENTORY}" --list --yaml | sed -n '1,25p')

echo
echo "==> 3. same hosts through the dynamic inventory script"
(cd "${REPO_ROOT}/ansible" && TF_STATE_FILE="${STATE}" ansible-inventory -i inventory/terraform.py --graph)

echo
echo "==> 4. run the real playbook against the generated inventory"
# Extra vars go through a FILE, not inline key=value: `-e "k={'a':1}"` arrives as
# a STRING and templates calling .items() on it blow up. `-e @file` keeps types.
cat > "${WORKDIR}/overrides.yml" <<EOF
---
ansible_connection: local
ansible_host: localhost
newrelic_infra_install_packages: false
newrelic_integrations_restart_agent: false
newrelic_infra_license_key: LAB-PLACEHOLDER-LICENSE-KEY
newrelic_infra_custom_attributes:
  env: dev
  region: ap-south-1
  managed_by: ansible
newrelic_infra_labels:
  env: dev
  tier: app
newrelic_infra_passthrough_environment:
  - NRIA_CUSTOM_ATTRIBUTES
  - AWS_REGION
newrelic_infra_config_dir: ${WORKDIR}/etc
newrelic_infra_integrations_dir: ${WORKDIR}/etc/integrations.d
newrelic_infra_var_dir: ${WORKDIR}/var/db
newrelic_infra_log_dir: ${WORKDIR}/var/log
newrelic_infra_log_file: ${WORKDIR}/var/log/newrelic-infra.log
newrelic_integrations_dir: ${WORKDIR}/etc/integrations.d
EOF

(cd "${REPO_ROOT}/ansible" && ansible-playbook playbooks/newrelic.yml \
  --inventory "${INVENTORY}" \
  --extra-vars "@${WORKDIR}/overrides.yml")

echo
echo "==> 5. proof: the agent config Ansible rendered from Terraform data"
CONFIG="${WORKDIR}/etc/newrelic-infra.yml"
ls -l "${CONFIG}"
# The file is mode 0600 and owned by root on purpose: it contains the license
# key. Ansible ran with become=yes, so reading it back needs sudo.
if ! cat "${CONFIG}" 2>/dev/null; then
  echo "(root-owned 0600 - reading it back with sudo, which is the point)"
  sudo -n cat "${CONFIG}" || echo "run: sudo cat ${CONFIG}"
fi

echo
echo "==> 6. proof: the on-host integration definition"
sudo -n cat "${WORKDIR}/etc/integrations.d/nri-flex-example.yml" 2>/dev/null ||
  cat "${WORKDIR}/etc/integrations.d/nri-flex-example.yml" 2>/dev/null ||
  echo "run: sudo cat ${WORKDIR}/etc/integrations.d/nri-flex-example.yml"

echo
echo "==> 7. assert the rendered files are VALID YAML"
# This is the check that catches Jinja whitespace mistakes: a template that
# renders but produces garbage YAML would silently break the agent.
sudo -n cat "${CONFIG}" > "${WORKDIR}/config.copy" 2>/dev/null || cp "${CONFIG}" "${WORKDIR}/config.copy"
sudo -n cat "${WORKDIR}/etc/integrations.d/nri-flex-example.yml" > "${WORKDIR}/integration.copy" 2>/dev/null ||
  cp "${WORKDIR}/etc/integrations.d/nri-flex-example.yml" "${WORKDIR}/integration.copy"

python3 - "${WORKDIR}" <<'PY'
import pathlib
import sys

import yaml

workdir = pathlib.Path(sys.argv[1])
failed = False
for name in ("config.copy", "integration.copy"):
    path = workdir / name
    try:
        parsed = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        print(f"FAIL  {name}: invalid YAML -> {exc}")
        failed = True
        continue
    if not isinstance(parsed, dict) or not parsed:
        print(f"FAIL  {name}: parsed but empty ({parsed!r})")
        failed = True
        continue
    print(f"PASS  {name}: valid YAML with {len(parsed)} top-level key(s) -> {sorted(parsed)}")

cfg = yaml.safe_load((workdir / "config.copy").read_text())
if cfg.get("display_name", "").endswith(("1a2b3c", "4d5e6f", "7g8h9i")):
    print(f"PASS  display_name came from Terraform state: {cfg['display_name']}")
else:
    print(f"FAIL  display_name not from state: {cfg.get('display_name')}")
    failed = True

sys.exit(1 if failed else 0)
PY

echo
echo "==> workdir kept for inspection: ${WORKDIR}"
