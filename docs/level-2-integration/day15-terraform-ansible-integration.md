# Day 15 — The Bridge: Terraform Output → Ansible Inventory

**Level 2** · ~2 hours · Prereqs: Day 14 · **This is the most important day in the course.**

## What you will be able to do

- Export Terraform data in a shape Ansible can consume directly
- Choose between three integration patterns and justify the choice
- Generate inventory as part of a deploy
- Read state directly with a dynamic inventory script

## The problem

Terraform created 3 instances with private IPs. Ansible needs an inventory. The
naive answers are both wrong:

- **Hand-edit `hosts.yml`** → it is stale within a day, and it is a lie the
  moment the ASG scales.
- **`user_data` writes the inventory** → user_data runs once, per instance, and
  cannot know about the other instances.

The correct answer: **Terraform already knows. Ask it.**

## Pattern 1 — Terraform output shaped as inventory (this repo's default)

`terraform/environments/dev/outputs.tf` discovers live instances and builds the
inventory structure:

```hcl
data "aws_instances" "app" {
  instance_tags = {
    "aws:autoscaling:groupName" = module.compute.autoscaling_group_name
  }
  instance_state_names = ["running", "pending"]
}

data "aws_instance" "app" {
  for_each    = toset(data.aws_instances.app.ids)
  instance_id = each.value
}

locals {
  app_hosts = {
    for id, instance in data.aws_instance.app :
    format("%s-%s-app-%s", var.project, var.environment, substr(id, -6, 6)) => {
      ansible_host      = instance.private_ip
      ansible_user      = "ubuntu"
      instance_id       = id
      availability_zone = instance.availability_zone
      aws_region        = var.aws_region
      env_name          = var.environment     # NOT "environment" - see below
      project           = var.project
    }
  }

  ansible_hosts = merge(module.compute.bastion_inventory_host, local.app_hosts)
}

output "ansible_inventory_json" {
  value = {
    all = {
      children = {
        servers = {
          hosts = local.ansible_hosts
          vars  = { ansible_ssh_common_args = "-o StrictHostKeyChecking=accept-new" }
        }
        newrelic_infra = { children = { servers = null } }
      }
    }
  }
}
```

Two design decisions worth noticing:

**One `data.aws_instance` per ID, not zipping two lists.**
`data.aws_instances` exposes `ids` and `private_ips` as parallel lists. Zipping
them works, but relies on the provider keeping both in the same order. A
`for_each` data source keyed by ID is deterministic and costs nothing.

**`env_name`, not `environment`.** This is a real bug this course hit:

```
[WARNING]: Found variable using reserved name 'environment'.
```

`environment` is a reserved Ansible keyword (it sets env vars on tasks). Emitting
it as a host variable makes Ansible warn on every run and can shadow the keyword
in confusing ways. The output now emits `env_name`. **Reserved names to avoid in
inventory:** `environment`, `role`, `connection`, `vars`, `when`, `tags`,
`async`, `delay`.

### Generating the file

```bash
terraform/scripts/tf_to_inventory.py \
  --workdir terraform/environments/dev \
  --output ansible/inventory/generated/dev.yml
```

The script prefers `terraform`, falls back to `tofu`, and writes a file with a
banner that says "GENERATED — DO NOT EDIT":

```yaml
# GENERATED FILE - DO NOT EDIT BY HAND.
# Source : terraform output ansible_inventory_json
# Regenerate:
#   terraform/scripts/tf_to_inventory.py -o ansible/inventory/generated/servers.yml
---
all:
  children:
    servers:
      hosts:
        newrelic-fleet-dev-app-1a2b3c:
          ansible_host: 10.0.11.41
          ansible_user: ubuntu
          instance_id: i-0abc11a2b3c
          availability_zone: ap-south-1a
          ...
```

`--stdout` prints instead of writing; `--state-file` reads a `.tfstate` directly
(which is how you test this without a cloud account).

## Pattern 2 — dynamic inventory straight from state

`ansible/inventory/terraform.py` is an executable script implementing
`--list` and `--host`. Ansible's `ansible.builtin.script` plugin loads the
**executable itself** — note that its `verify_file()` requires `os.X_OK`, so
there is no YAML wrapper file:

```bash
cd ansible
export TF_STATE_FILE=../labs/local/sample.tfstate.json
ansible-inventory -i inventory/terraform.py --graph
```

Real output:

```
@all:
  |--@ungrouped:
  |--@servers:
  |  |--newrelic-fleet-dev-app-1a2b3c
  |  |--newrelic-fleet-dev-app-4d5e6f
  |  |--newrelic-fleet-dev-app-7g8h9i
  |--@newrelic_infra:
  |  |--@servers:
  |  |  |--newrelic-fleet-dev-app-1a2b3c
  |  |  |--newrelic-fleet-dev-app-4d5e6f
  |  |  |--newrelic-fleet-dev-app-7g8h9i
```

Nothing to go stale: Ansible reads the state on every run.

## Pattern 3 — the cloud inventory plugin

Once you have the `amazon.aws` collection, Ansible can ask AWS directly:

```yaml
# inventory/aws_ec2.yml
plugin: amazon.aws.ec2_instances
regions: [ap-south-1]
filters:
  tag:ansible_managed: "true"
  instance-state-name: [running]
keyed_groups:
  - key: tags.ansible_group
hostnames:
  - tag:Name
compose:
  ansible_host: private_ip_address
```

| Pattern | Freshness | Needs cloud creds | Needs state | Best for |
| --- | --- | --- | --- | --- |
| 1. tf output → file | at generate time | no | yes | CI, auditable deploys |
| 2. script from state | at run time | no | yes | Terraform-managed fleets |
| 3. cloud plugin | at run time | yes | no | non-Terraform / hybrid fleets |

**This repo uses 1 by default** because the generated file is an artifact: you can
diff it between deploys, attach it to a PR, and see exactly which hosts a run
touched.

## Lab 15.1 — the whole bridge, no cloud account

```bash
bash labs/local/mock_bridge.sh
```

It does five things with `labs/local/sample.tfstate.json` standing in for a real
apply:

1. state → inventory via `tf_to_inventory.py`
2. prints the hosts Ansible discovered
3. prints the same hosts via the dynamic script
4. runs the **real** `playbooks/newrelic.yml` against the generated inventory
   (redirected to localhost, packages disabled)
5. prints the rendered agent config and **asserts it parses as YAML**

Real output from step 7:

```
PASS  config.copy: valid YAML with 7 top-level key(s) -> ['custom_attributes',
      'display_name', 'labels', 'license_key', 'log', 'passthrough_environment',
      'verbose']
PASS  integration.copy: valid YAML with 1 top-level key(s) -> ['integrations']
PASS  display_name came from Terraform state: newrelic-fleet-dev-app-4d5e6f
```

That last line is the proof that closes the loop: a value that began as an EC2
instance ID in Terraform state ended up as `display_name` in the New Relic agent
config. **That is the integration.**

## Lab 15.2 — one script, end to end

`terraform/scripts/deploy.sh` is what CI runs:

```bash
terraform init -input=false
terraform plan  -input=false -out=tfplan
terraform apply -input=false -auto-approve tfplan
tf_to_inventory.py -o ansible/inventory/generated/${ENV}.yml
ansible-playbook playbooks/site.yml --limit "${ENV}" --diff
```

```bash
DRY_RUN=1 bash terraform/scripts/deploy.sh dev   # stops before apply
```

## Lab 15.3 — the deliberate failure

Break the state file and watch each layer report it differently:

```bash
cp labs/local/sample.tfstate.json /tmp/ok.json
python3 -c "
import json,pathlib
p=pathlib.Path('labs/local/sample.tfstate.json')
s=json.loads(p.read_text()); s['outputs'].pop('ansible_inventory_json')
p.write_text(json.dumps(s,indent=2))
"
python3 terraform/scripts/tf_to_inventory.py --state-file labs/local/sample.tfstate.json --stdout
```

```
output 'ansible_inventory_json' not found in labs/local/sample.tfstate.json.
Available: autoscaling_group_name, vpc_id
```

Note that it lists what *is* available. A tool that tells you what it found is
worth the five lines of code. Restore with `cp /tmp/ok.json labs/local/sample.tfstate.json`.

## Exercises

1. Add `ansible_become=true` and a `ansible_ssh_private_key_file` to the emitted
   host vars. Where should the key path come from, and why not from state?
2. Extend the output to group hosts by `availability_zone`, so you can run
   `--limit` per AZ.
3. Make `tf_to_inventory.py` fail the build if the host count is zero. Why does
   that matter in CI?

## Gotchas

- Generated files must be **git-ignored** or committed **every** time. Half-measures
  cause "why is this host missing?" at 2am. This repo ignores
  `ansible/inventory/generated/`.
- `group_vars/` next to a generated inventory file are **not** loaded when you
  pass `-i /some/other/path.yml`. Group vars live next to the inventory that
  declares the group.
- Do not put `ansible_password` in state. Use SSH keys or `aws_ssm` lookups.

## Check yourself

- [ ] `bash labs/local/mock_bridge.sh` prints three `PASS` lines
- [ ] You can name the three patterns and say which this repo uses and why
- [ ] You can explain why `environment` was renamed to `env_name`

**Next:** [Day 16 — Bootstrap, user_data and ProxyJump](day16-bootstrap-userdata-proxyjump.md)
