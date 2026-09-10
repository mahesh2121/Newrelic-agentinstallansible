# Day 0 — Prerequisites (read once, before Day 1)

## What you need

| Thing | Why | Minimum |
| --- | --- | --- |
| Linux or macOS terminal | both tools are CLI-first | any recent distro |
| Python 3.9+ | Ansible is Python | `python3 --version` |
| Git | the course lives in a repo | `git --version` |
| A text editor | you will write a lot of YAML | any |
| AWS account (from Day 12) | the Level 2/3 labs | free tier is enough |
| New Relic account (Day 18) | agent verification | free tier is enough |

Days 1–11 need **no cloud account at all**. Every lab runs locally.

## Install

### Ansible

```bash
python3 -m pip install --user ansible-core      # CLI + engine only
# or the full bundle with collections:
python3 -m pip install --user ansible

# linting and yaml checking (used by this repo's CI)
python3 -m pip install --user ansible-lint yamllint

ansible --version          # expect: ansible [core 2.x]
ansible-lint --version
```

This repository was written and validated against **ansible-core 2.19.13**,
**ansible-lint 26.8.0** and **yamllint 1.38.0**. Other versions work; if
`ansible-lint` disagrees with the code, check its version first.

> **Why `ansible-core`, not `ansible`?** `ansible-core` is the engine plus
> `ansible.builtin`. Everything in `ansible/` here uses only `ansible.builtin`
> modules, so it runs on a bare install. Day 17 covers collections and why you
> eventually want `requirements.yml`.

### Terraform

HashiCorp publishes binaries from `releases.hashicorp.com`:

```bash
# Linux amd64 - check https://developer.hashicorp.com/terraform/downloads for current
TF_VERSION=1.9.8
curl -sSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
unzip terraform_${TF_VERSION}_linux_amd64.zip
sudo install terraform /usr/local/bin/
terraform version
```

macOS: `brew install terraform`. Windows: use WSL2.

**OpenTofu** (`tofu`) is the open-source fork with identical HCL and CLI. The
scripts in `terraform/scripts/` prefer `terraform` and fall back to `tofu`, so
either works.

### Optional, for the local multi-host lab

```bash
docker --version    # labs/containers/docker-compose.yml spins up SSH-able hosts
```

## Verify your setup

```bash
cd Newrelic-agentinstallansible
ansible --version | head -3
terraform version || tofu version
```

Then prove the toolchain end to end — this is the command that must work before
Day 1:

```bash
cd ansible
ansible lab -m ping
```

Expected:

```
lab-local | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

If that fails, fix it now. Every later day depends on it.

## Environment variables you will set later

Keep these in a file outside the repo (`~/.tf-ansible.env`) and `source` it.
**Never** commit them.

```bash
export AWS_ACCESS_KEY_ID=...        # or better: aws-vault / SSO (Day 19)
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=ap-south-1

export NEW_RELIC_API_KEY=NRAK-...   # User API key
export NEW_RELIC_ACCOUNT_ID=1234567
export NEW_RELIC_REGION=US          # US or EU

export ANSIBLE_CONFIG=$PWD/ansible/ansible.cfg
```

## How to study

1. Read the day.
2. Run the lab **exactly** as written, including the step that fails on purpose.
3. Do the exercises without looking at the solution.
4. Tick the checkpoint. If you cannot tick it, re-read — do not move on.
5. Every fifth day, attempt `docs/CHECKPOINTS.md`.

## The three mistakes every beginner makes

1. **Editing YAML with tabs.** YAML forbids tabs for indentation. Your editor
   should be set to 2 spaces for `*.yml`.
2. **Trusting `ok` as success.** A playbook can report `ok=12 changed=0 failed=0`
   while the agent is not sending data. Verification is a separate step (Day 18).
3. **Hand-editing generated files.** `ansible/inventory/generated/*.yml` is
   written by Terraform. Edit the Terraform output, not the file.
