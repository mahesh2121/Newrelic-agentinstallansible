# Verification Report

Exactly what was run against this repository, what it returned, and — equally
important — **what could not be verified** and why.

Generated in an offline sandbox on 2026-09-10. Re-run any of it yourself with
`make verify`.

## Tool versions

| Tool | Version |
| --- | --- |
| ansible-core | 2.19.13 |
| ansible-lint | 26.8.0 |
| yamllint | 1.38.0 |
| checkov | 3.3.17 |
| python-hcl2 | (HCL2 parser) |
| Python | 3.11.2 |

Pin these in CI. `ansible-lint` rules change between majors, and a version
mismatch produces failures that are not real.

## What passed

| Check | Command | Result |
| --- | --- | --- |
| YAML lint | `yamllint .` | clean — 0 warnings, 0 errors |
| Ansible lint | `cd ansible && ansible-lint` | `Passed: 0 failure(s), 0 warning(s) in 65 files processed of 71 encountered. Profile 'production' was required, and it passed.` |
| Playbook syntax | `ansible-playbook --syntax-check` on each | 10 / 10 playbooks pass |
| HCL parse | `python3 tools/hcl_parse_check.py` | `HCL PARSE OK: 21 file(s), 221 declared block(s)` |
| Security/policy | `checkov --config-file .checkov.yaml` | `Passed checks: 110, Failed checks: 0` |
| Docs integrity | `python3 tools/docs_path_check.py` | all referenced repo paths exist |
| Local lab | `ansible-playbook ../labs/local/lab.yml` | fresh run `ok=6 changed=4 rescued=1 failed=0` |
| Idempotency | same command, second run | `ok=5 changed=0 rescued=1 failed=0` |
| Bridge | `bash labs/local/mock_bridge.sh` | 3 / 3 assertions `PASS` |
| Dynamic inventory | `ansible-inventory -i inventory/terraform.py --graph` | 3 hosts in `servers` and `newrelic_infra` |

The `ok=6` → `ok=5` difference between the two lab runs is the handler: on the
first run the monitoring config changed, so the handler ran (and counts as `ok`);
on the second nothing changed, so it did not run at all.

## What was executed for real

These are not static checks — the code actually ran:

1. **`labs/local/lab.yml`** — rendered templates, created directories, exercised
   `loop`, `when`, `block/rescue/always`, and fired a handler. Verified twice for
   idempotency.
2. **`labs/local/mock_bridge.sh`** — the full Terraform→Ansible path:
   `sample.tfstate.json` → `tf_to_inventory.py` → generated inventory →
   `playbooks/newrelic.yml` → rendered `newrelic-infra.yml` and integration
   definition → YAML parse assertions.
3. **`terraform/scripts/tf_to_inventory.py`** — against the sample state, both
   `--stdout` and `--output`.
4. **`ansible/inventory/terraform.py`** — `--list` and `--host`, consumed by
   `ansible-inventory`.
5. **A Jinja whitespace probe** — rendered both dash-tag and plain-tag loop forms
   and diffed the output, which is how the invalid-YAML bug was proven.

## Bugs found by running, and fixed

Each of these was invisible to every static check:

| # | Bug | Found by |
| --- | --- | --- |
| 1 | `stdout_callback = yaml` aborted every run with **exit 0 and no output** (missing `community.general`) | running any playbook |
| 2 | Jinja dash-tags collapsed a YAML mapping onto one line: `labels:      env: "dev"    commands:` — invalid agent config | rendering + YAML parse |
| 3 | A comment containing literal block tags broke the template: `Syntax error in template: tag name expected` | rendering |
| 4 | `Restart newrelic-infra` handler failed the play when the agent was not installed | running the role with `install_packages: false` |
| 5 | `newrelic_integrations` handler had the same defect | same |
| 6 | Terraform emitted `environment` as a host var — a reserved Ansible keyword | `ansible-inventory --host` |
| 7 | `-e "d={'a':1}"` arrives as a string, breaking `.items()` in templates | running with inline extra vars |
| 8 | `tf_to_inventory.py` crashed on `children: {servers: null}` | running it |
| 9 | `monitoring { enabled = true }` on `aws_instance` — invalid for the AWS provider (it is a boolean there; the block form belongs to `aws_launch_template`) | checkov CKV_AWS_126 |
| 10 | `state: latest` in the patching playbook | `ansible-lint` |
| 11 | `make verify` reported **"all four levels passed" while the bridge had crashed** — the `bridge` target piped to `tail`, so the pipeline exited with `tail`'s status. Fixed with `.SHELLFLAGS := -eu -o pipefail -c`, then proven by a negative test: hiding the lab fixture now makes `make bridge` exit 2. | re-running `make verify` after a sandbox reset |
| 12 | `.gitignore`'s `*.tfstate.*` pattern excluded `labs/local/sample.tfstate.json` — a required, non-secret lab fixture — so a clean checkout could not run the Day 15 bridge lab. Fixed with an explicit `!labs/local/sample.tfstate.json` negation. | `git check-ignore -v` |

Bug 11 is the failure mode Day 29 describes as #15 ("the pipeline is green and
production is broken"). It is worth sitting with: the check that was supposed to
prove the integration worked was itself silently passing. A gate that has never
been seen to fail is not a gate.

## What could NOT be verified here

The sandbox had no access to the following hosts (verified by attempting each):

| Host | Needed for | Consequence |
| --- | --- | --- |
| `releases.hashicorp.com` | the `terraform` binary | no Terraform CLI at all |
| `release-assets.githubusercontent.com` | the OpenTofu binary | no `tofu` fallback either |
| `registry.terraform.io`, `registry.opentofu.org` | provider downloads | **no `terraform init`, `validate`, `plan` or `apply`** |
| `galaxy.ansible.com` | collections | no `ansible.posix`, `community.general`, `amazon.aws`, `newrelic.newrelic_install` |
| `download.newrelic.com`, `docs.newrelic.com` | agent packages and docs | no real agent install, no doc cross-check |

### Therefore these claims are **unverified** and must be confirmed on a machine with internet access

- **All Terraform HCL is schema-valid.** Parsing proves syntax; only
  `terraform validate` proves the arguments exist in the AWS provider schema.
  Run: `cd terraform/environments/dev && terraform init && terraform validate`.
- **`terraform plan` succeeds** for `environments/dev` and `environments/staging`.
- **The New Relic repository URLs and GPG key path** in
  `roles/newrelic_infra/defaults/main.yml` are current. Check:
  ```bash
  curl -sSI https://download.newrelic.com/infrastructure_agent/linux/apt/dists/ | head -1
  ```
- **The agent config key names** (`custom_attributes`, `labels`,
  `passthrough_environment`, `display_name`, `log.file`, `log.level`) match your
  agent version. Check: `newrelic-infra -h` and the agent's own documentation.
- **`newrelic-infra -config ... -validate`** exists as a flag in your version. The
  role tolerates its absence (`failed_when` ignores "unknown flag"), but confirm.
- **The New Relic Terraform provider resource arguments** in
  `modules/monitoring/main.tf` (`newrelic_nrql_alert_condition`,
  `newrelic_one_dashboard`) match provider `~> 3.0`.
- **NRQL attribute names** (`tags.env`, `integrationName`, `cpuPercent`,
  `memoryUsedPercent`) match what your agent actually sends. Verify with a query
  in the UI before trusting a threshold.
- **Available Galaxy collection versions** listed in
  `ansible/requirements.yml`.
- **`labs/containers/docker-compose.yml`** — no Docker daemon was available, so
  the multi-host lab is unexercised. The local (`connection: local`) lab is fully
  exercised instead.

### Checks that were deliberately weakened

- `checkov` reports `Skipped checks: 0` in its summary, but `.checkov.yaml`
  excludes 12 checks. Every exclusion carries a written justification; several are
  marked as **needing confirmation against a real `terraform plan`**, because
  checkov's static analysis did not resolve the association between the S3 bucket
  and its standalone `aws_s3_bucket_*` resources. Verified against checkov 3.3.17;
  results may differ on other versions.
- `tools/hcl_parse_check.py` is a syntax check, not a validation. Its limits are
  demonstrated in Day 9, Lab 9.4 (bug #9 above).

## How to re-verify everything

```bash
make verify
```

or step by step:

```bash
yamllint .
cd ansible && ansible-lint && cd ..
cd ansible && for p in playbooks/*.yml ../labs/local/lab.yml; do ansible-playbook --syntax-check "$p"; done && cd ..
python3 tools/hcl_parse_check.py
checkov --config-file .checkov.yaml
python3 tools/docs_path_check.py
bash labs/local/mock_bridge.sh | tail -6
```

And, on a machine with internet and cloud credentials, the two things this report
cannot do:

```bash
cd terraform/environments/dev
terraform init && terraform validate && terraform plan

cd ../../../ansible
ansible-playbook playbooks/site.yml --limit dev --check --diff --ask-vault-pass
```
