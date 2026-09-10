# ---------------------------------------------------------------------------
# THE TERRAFORM -> ANSIBLE BRIDGE
# ---------------------------------------------------------------------------
# Instead of hand-editing inventory, ask AWS what exists right now and hand the
# answer to Ansible. Two consumers, one source of truth:
#
#   1. terraform/scripts/tf_to_inventory.py  -> writes inventory/generated/*.yml
#   2. ansible/inventory/terraform.py        -> reads state directly (dynamic)
#
# Day 15 compares this with the cloud inventory plugin and with static files.

# One data source per instance keeps host -> IP mapping deterministic.
# Zipping data.aws_instances.ids with data.aws_instances.private_ips works too,
# but relies on the provider keeping two lists in the same order.
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
  # App instances discovered from live AWS state, plus the bastion that the
  # compute module created. This map IS the Ansible inventory.
  app_hosts = {
    for id, instance in data.aws_instance.app :
    format(
      "%s-%s-app-%s",
      var.project,
      var.environment,
      substr(id, -6, 6)
    ) => {
      ansible_host           = instance.private_ip
      ansible_user           = "ubuntu"
      instance_id            = id
      availability_zone      = instance.availability_zone
      instance_type          = instance.instance_type
      private_ip             = instance.private_ip
      public_ip              = instance.public_ip
      aws_region             = var.aws_region
      # NOTE: the variable is called env_name, NOT environment - `environment`
      # is a reserved Ansible keyword and Ansible warns when you shadow it.
      env_name               = var.environment
      project                = var.project
    }
  }

  ansible_hosts = merge(module.compute.bastion_inventory_host, local.app_hosts)

  ansible_inventory = {
    all = {
      children = {
        servers = {
          hosts = local.ansible_hosts
          vars = {
            ansible_ssh_common_args = "-o StrictHostKeyChecking=accept-new"
          }
        }
        newrelic_infra = {
          children = {
            servers = null
          }
        }
      }
    }
  }
}

output "ansible_inventory_yaml" {
  description = "Ready-to-write Ansible inventory. Pipe to a file or use tf_to_inventory.py."
  value       = yamlencode(local.ansible_inventory)
}

output "ansible_inventory_json" {
  description = "Same inventory as structured data, for the dynamic inventory plugin."
  value       = local.ansible_inventory
}

output "ansible_hostnames" {
  description = "Host names Ansible will use, in no particular order."
  value       = keys(local.ansible_hosts)
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "nat_gateway_public_ips" {
  description = "Egress IPs (allowlist these in New Relic if you lock down ingest)."
  value       = module.network.nat_gateway_public_ips
}

output "alb_dns_name" {
  description = "Load balancer DNS name."
  value       = module.compute.alb_dns_name
}

output "autoscaling_group_name" {
  description = "ASG name, used to filter the inventory."
  value       = module.compute.autoscaling_group_name
}

output "newrelic_dashboard_guid" {
  description = "Fleet dashboard GUID (empty when the monitoring module is off)."
  value       = try(module.monitoring[0].dashboard_guid, "")
}

output "bastion_public_ip" {
  description = "Bastion public IP - the SSH/Ansible entry point (Day 16)."
  value       = module.compute.bastion_public_ip
}

output "flow_log_group_name" {
  description = "CloudWatch log group with VPC flow logs."
  value       = module.network.flow_log_group_name
}
