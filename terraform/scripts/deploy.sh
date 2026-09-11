#!/usr/bin/env bash
# End-to-end deploy: provision with Terraform, configure with Ansible.
#
#   terraform/scripts/deploy.sh dev            # plan + apply + configure
#   terraform/scripts/deploy.sh dev --check    # plan only, ansible --check
#   DRY_RUN=1 terraform/scripts/deploy.sh dev  # never touches the cloud
#
# This is the script the CI workflow (.github/workflows/ci.yml) calls on merge.
set -euo pipefail

ENVIRONMENT="${1:-dev}"
MODE="${2:-apply}"
DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_OUT="${ANSIBLE_DIR}/inventory/generated/${ENVIRONMENT}.yml"

if [[ ! -d "${TF_DIR}" ]]; then
  echo "no such environment: ${ENVIRONMENT} (looked in ${TF_DIR})" >&2
  exit 1
fi

TF_BIN="terraform"
command -v terraform >/dev/null 2>&1 || TF_BIN="tofu"

echo "==> [1/4] terraform init (${ENVIRONMENT})"
(cd "${TF_DIR}" && "${TF_BIN}" init -input=false)

echo "==> [2/4] terraform plan"
(cd "${TF_DIR}" && "${TF_BIN}" plan -input=false -out=tfplan)

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "==> DRY_RUN=1 set, stopping before apply"
  exit 0
fi

if [[ "${MODE}" == "apply" ]]; then
  echo "==> [3/4] terraform apply"
  (cd "${TF_DIR}" && "${TF_BIN}" apply -input=false -auto-approve tfplan)
else
  echo "==> skipping apply (mode=${MODE})"
fi

echo "==> [4/4] generate inventory and run ansible"
mkdir -p "$(dirname "${INVENTORY_OUT}")"
(cd "${TF_DIR}" && "${REPO_ROOT}/terraform/scripts/tf_to_inventory.py" -o "${INVENTORY_OUT}")

ANSIBLE_ARGS=(playbooks/site.yml --limit "${ENVIRONMENT}" --diff)
if [[ "${MODE}" == "--check" ]]; then
  ANSIBLE_ARGS+=(--check)
fi

(cd "${ANSIBLE_DIR}" && ansible "${ANSIBLE_ARGS[@]}" -i "${INVENTORY_OUT}")

echo "==> done. inventory: ${INVENTORY_OUT}"
