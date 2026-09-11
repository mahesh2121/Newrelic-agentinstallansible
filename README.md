# New Relic agent automation — Terraform + Ansible

Provision infrastructure with **Terraform**, configure it with **Ansible**, and
prove the New Relic agents are actually reporting.

This repository is two things at once:

1. **Working code** — Terraform modules for AWS, Ansible roles for the New Relic
   infrastructure agent, APM agents and on-host integrations, plus the glue that
   turns Terraform output into an Ansible inventory.
2. **A 30-day course** — [`TUTORIAL.md`](TUTORIAL.md) teaches Terraform + Ansible
   from zero to master level, using this code as the textbook.

## Start here

| You want to... | Read |
| --- | --- |
| Learn the whole thing, day by day | [`TUTORIAL.md`](TUTORIAL.md) |
| Set up your machine first | [`docs/00-prerequisites.md`](docs/00-prerequisites.md) |
| See the Terraform→Ansible bridge | [`docs/level-2-integration/day15-terraform-ansible-integration.md`](docs/level-2-integration/day15-terraform-ansible-integration.md) |
| See what was actually verified | [`docs/VERIFICATION.md`](docs/VERIFICATION.md) |
| Test yourself | [`docs/CHECKPOINTS.md`](docs/CHECKPOINTS.md) |
| Learn to *operate* it in AWS (Days 31–37) | [`docs/aws-cloudops-level3/README.md`](docs/aws-cloudops-level3/README.md) |

## Quick start (no cloud account needed)

```bash
python3 -m pip install --user ansible-core    # ansible-core 2.19.x

# 1. prove the toolchain
cd ansible
ansible lab -m ping

# 2. run the local lab twice - the second run must show changed=0
ansible-playbook ../labs/local/lab.yml
ansible-playbook ../labs/local/lab.yml

# 3. run the full Terraform -> Ansible bridge against a sample state file
cd ..
bash labs/local/mock_bridge.sh
```

That last command is the whole course in miniature: it reads a
`terraform.tfstate`, generates an Ansible inventory from it, runs the real
`newrelic.yml` playbook, and asserts the rendered agent config is valid YAML.

## Repository layout

```
terraform/
├── modules/
│   ├── network/       VPC, subnets, NAT, route tables, flow logs, default SG
│   ├── security/      bastion / app / ALB security groups
│   ├── compute/       key pair, IAM, launch template, ASG, ALB, bastion
│   └── monitoring/    New Relic alert policy, NRQL conditions, dashboard
├── environments/
│   ├── dev/           root module + variables + the Ansible inventory output
│   ├── staging/       thin wrapper, values only
│   └── prod/          values only
└── scripts/
    ├── tf_to_inventory.py    terraform output -> ansible inventory YAML
    └── deploy.sh             plan -> apply -> inventory -> configure -> verify

ansible/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml             static groups (servers, lab, newrelic_infra)
│   ├── terraform.py          dynamic inventory reading terraform.tfstate
│   ├── generated/            Terraform-generated (git-ignored)
│   └── group_vars/           all / servers / lab / vault
├── playbooks/
│   ├── site.yml              bootstrap -> configure -> newrelic -> verify
│   ├── bootstrap.yml         first contact: wait, raw, python, deploy user
│   ├── configure.yml  newrelic.yml  verify.yml  hardening.yml
│   ├── patch.yml  drift-check.yml  decommission.yml
└── roles/
    ├── common/  users/  firewall/  hardening/
    ├── newrelic_infra/       the point of this repository
    ├── newrelic_apm/  newrelic_integrations/  verify_agents/

labs/
├── local/         lab.yml, mock_bridge.sh, sample.tfstate.json
└── containers/    docker-compose multi-host lab

docs/              Day 0-30 curriculum, checkpoints, verification report
└── aws-cloudops-level3/   Day 31-37: operating the platform in AWS
tools/             hcl_parse_check.py, docs_path_check.py
.checkov.yaml      security skips, each with a written justification
```

## Verification

Everything is checked by five commands:

```bash
make verify      # or run them individually:
yamllint .
cd ansible && ansible-lint
cd ansible && for p in playbooks/*.yml ../labs/local/lab.yml; do ansible-playbook --syntax-check "$p"; done
python3 tools/hcl_parse_check.py
checkov --config-file .checkov.yaml
python3 tools/docs_path_check.py
bash labs/local/mock_bridge.sh
```

Results, and exactly what could **not** be verified offline, are in
[`docs/VERIFICATION.md`](docs/VERIFICATION.md).

## History note

The repository began as a single 23-byte inventory file named `inverntory.ini`
(sic) containing one hard-coded IP. Day 2 uses that as the opening lesson: Ansible
silently ignores an inventory file it was not told about. The replacement is
`ansible/inventory/hosts.yml`.

## License

MIT — see the `galaxy_info` block in each role's `meta/main.yml`.
