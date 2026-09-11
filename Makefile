# Shortcuts for the commands this course runs constantly.
#   make help      list targets
#   make verify    the full four-level gate (CI runs the same commands)

SHELL := /bin/bash
# Without pipefail, `cmd | tail` exits with tail's status, so a crashed lab would
# still report success. That is exactly the "green pipeline, broken production"
# failure described in docs/level-3-master/day29-troubleshooting-masterclass.md.
.SHELLFLAGS := -eu -o pipefail -c
ANSIBLE_DIR := ansible

.DEFAULT_GOAL := help
.PHONY: help verify lint syntax hcl scan lab bridge idempotency clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ---- Level 1/2: static and schema -------------------------------------------------
lint: ## yamllint + ansible-lint
	yamllint .
	cd $(ANSIBLE_DIR) && ansible-lint

syntax: ## ansible-playbook --syntax-check on every playbook
	cd $(ANSIBLE_DIR) && for p in playbooks/*.yml ../labs/local/lab.yml; do \
	  echo "-- $$p"; ansible-playbook --syntax-check "$$p"; done

hcl: ## parse every .tf file
	python3 tools/hcl_parse_check.py

# ---- Level 3: policy -------------------------------------------------------------
scan: ## checkov with the justified skip list
	checkov --config-file .checkov.yaml

# ---- Level 4: behaviour ----------------------------------------------------------
lab: ## run the local lab once
	cd $(ANSIBLE_DIR) && ansible-playbook ../labs/local/lab.yml

idempotency: ## run the lab twice and require changed=0 on the second run
	cd $(ANSIBLE_DIR) && ansible-playbook ../labs/local/lab.yml > /tmp/run1.log
	cd $(ANSIBLE_DIR) && ansible-playbook ../labs/local/lab.yml | tee /tmp/run2.log
	@grep -q "changed=0" /tmp/run2.log \
	  && echo "IDEMPOTENT: ok" \
	  || { echo "NOT IDEMPOTENT"; exit 1; }

bridge: ## state -> inventory -> playbook -> rendered config, with YAML assertions
	bash labs/local/mock_bridge.sh | tail -8

verify: lint syntax hcl scan idempotency bridge ## the full gate
	@echo
	@echo "verify: all four levels passed"

clean: ## remove generated artifacts and caches
	rm -rf $(ANSIBLE_DIR)/inventory/generated \
	       $(ANSIBLE_DIR)/.facts .facts \
	       $$(find . -name '*.retry') \
	       $$(find . -type d -name __pycache__)
	@echo "cleaned"
