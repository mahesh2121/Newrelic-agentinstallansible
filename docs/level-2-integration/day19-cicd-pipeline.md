# Day 19 — CI/CD for Terraform and Ansible

**Level 2** · ~90 min · Prereqs: Day 18

## What you will be able to do

- Design a pipeline that plans on PR and applies on merge
- Authenticate to AWS without long-lived keys (OIDC)
- Pass secrets to Ansible without writing them to disk
- Fail the build on the checks that matter

## The pipeline shape

```
pull_request
├── lint           yamllint, ansible-lint, terraform fmt
├── validate       hcl parse, checkov, ansible-playbook --syntax-check
├── test           labs/local/lab.yml, labs/local/mock_bridge.sh
└── plan           terraform plan  -> uploaded as artifact + PR comment

push to main
└── deploy         terraform apply -> tf_to_inventory.py -> ansible-playbook site.yml
```

Two rules make this safe:

1. **The plan that was reviewed is the plan that is applied.** Save it with
   `-out=tfplan`, upload it as an artifact, and `apply tfplan` — do not re-plan.
2. **Nothing applies from a fork.** `pull_request_target` with secrets is how
   people leak credentials.

## The workflow in this repo

`.github/workflows/ci.yml` implements it. The core stages:

```yaml
- name: YAML lint
  run: yamllint .

- name: Ansible lint
  working-directory: ansible
  run: ansible-lint

- name: Syntax check every playbook
  working-directory: ansible
  run: |
    for p in playbooks/*.yml ../labs/local/lab.yml; do
      ansible-playbook --syntax-check "$p"
    done

- name: HCL parse
  run: python3 tools/hcl_parse_check.py

- name: Security scan
  run: checkov --config-file .checkov.yaml

- name: Integration lab (the real bridge, no cloud needed)
  run: bash labs/local/mock_bridge.sh
```

Every one of those commands was run against this repository — see
[`docs/VERIFICATION.md`](../VERIFICATION.md).

## OIDC instead of access keys

```yaml
permissions:
  id-token: write      # required for OIDC
  contents: read
  pull-requests: write

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789012:role/github-actions-terraform
      aws-region: ap-south-1
```

AWS trusts the GitHub OIDC provider and issues short-lived credentials scoped to
that role. No `AWS_SECRET_ACCESS_KEY` in repository secrets, nothing to rotate,
and CloudTrail shows exactly which repo/branch assumed the role.

The role's trust policy conditions on the repo and ref:

```json
"Condition": {
  "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
  "StringLike":   { "token.actions.githubusercontent.com:sub":
                    "repo:yourorg/Newrelic-agentinstallansible:ref:refs/heads/main" }
}
```

Without the `sub` condition, **any** workflow in **any** repo can assume the role.

## Secrets for Ansible

The vault password must reach CI without being written to a file that persists.

```yaml
- name: Decrypt vault
  env:
    VAULT_PASSWORD: ${{ secrets.ANSIBLE_VAULT_PASSWORD }}
  run: echo "$VAULT_PASSWORD" > /tmp/.vault-pass && chmod 600 /tmp/.vault-pass

- name: Run Ansible
  working-directory: ansible
  run: >
    ansible-playbook playbooks/site.yml
    --vault-password-file /tmp/.vault-pass
    --limit "${ENVIRONMENT}" --diff

- name: Shred the password file
  if: always()
  run: shred -u /tmp/.vault-pass || rm -f /tmp/.vault-pass
```

Better still, keep the license key out of Ansible vault entirely and inject it at
runtime from a secrets manager:

```yaml
- name: Fetch license key from AWS Secrets Manager
  ansible.builtin.command:
    cmd: aws secretsmanager get-secret-value --secret-id newrelic/license --query SecretString
  register: nr_secret
  changed_when: false
  no_log: true
```

Either way: `no_log: true` on any task that touches a credential.

## Caching

```yaml
- uses: actions/setup-python@v5
  with:
    python-version: "3.11"
    cache: pip

- name: Cache ansible collections
  uses: actions/cache@v4
  with:
    path: ansible/collections
    key: collections-${{ hashFiles('ansible/requirements.yml') }}
```

Terraform's plugin cache too:

```yaml
- uses: hashicorp/setup-terraform@v3
  with:
    terraform_version: 1.9.8
env:
  TF_PLUGIN_CACHE_DIR: ${{ github.workspace }}/.terraform.d/plugin-cache
```

## The checks that actually catch bugs

Ranked by how often they save you, from this course's own experience:

| Check | Caught what |
| --- | --- |
| Running the lab for real | the Jinja whitespace bug that produced invalid YAML |
| Running the lab for real | the handler that restarted a nonexistent service |
| `ansible-inventory --host` | the reserved-name `environment` variable |
| `checkov` | `monitoring { enabled = true }` on `aws_instance` (schema-invalid) |
| `ansible-lint` | `state: latest` in the patching playbook |
| `--syntax-check` | nothing on its own — it is cheap, so keep it |

Notice the pattern: **static checks found style and schema problems; only
execution found logic problems.** That is why the workflow runs
`labs/local/mock_bridge.sh` on every PR.

## Lab 19.1 — run the CI locally

```bash
cd Newrelic-agentinstallansible
yamllint .
(cd ansible && ansible-lint)
(cd ansible && for p in playbooks/*.yml ../labs/local/lab.yml; do ansible-playbook --syntax-check "$p"; done)
python3 tools/hcl_parse_check.py
checkov --config-file .checkov.yaml | grep -E "Passed|Failed"
bash labs/local/mock_bridge.sh | tail -6
```

If all six pass locally, the workflow will pass. That equivalence is the point:
**CI runs the same commands you run.**

## Lab 19.2 — the deliberate failure

Make a lint error and confirm the pipeline catches it:

```bash
cd ansible
printf -- '---\n- name: bad\n  hosts: localhost\n  tasks:\n    - name: shell it\n      ansible.builtin.shell: ls\n' > playbooks/bad.yml
ansible-lint
```

```
package-latest / no-changed-when / ...
Failed: N failure(s)
```

Delete it: `rm playbooks/bad.yml`.

## Exercises

1. Add a job that runs `terraform plan` and posts the diff as a PR comment.
2. Add concurrency control so two deploys to the same environment cannot overlap
   (`concurrency: { group: deploy-${{ inputs.env }}, cancel-in-progress: false }`).
3. Add a scheduled drift job that runs `playbooks/drift-check.yml` nightly and
   opens an issue when hosts report changes (Day 25).

## Gotchas

- `terraform fmt -check` fails on whitespace. Run `terraform fmt` before you push.
- `ansible-lint` versions disagree. Pin it in CI to match your local version.
- `actions/checkout` must run before `hashFiles` can read your lock files.
- Never `echo` a secret, even "for debugging". GitHub masks known secrets, but
  derived values (a decrypted vault file's contents) are not masked.
- A green `--syntax-check` means nothing about correctness. It parses, that is all.

## Check yourself

- [ ] All six local CI commands pass
- [ ] You can explain why the reviewed plan must be the applied plan
- [ ] You know why OIDC beats stored access keys

**Next:** [Day 20 — Testing & Level 2 Capstone](day20-testing-and-capstone.md)
