# Staging reuses the dev root module. See Day 21 for the "one module, many
# environments" layout and why we avoid copying main.tf.
#
# If your organisation prefers fully separate state, uncomment and keep the
# backend block in sync with dev but a different key.
module "stack" {
  source = "../dev"

  environment            = "staging"
  vpc_cidr               = "10.20.0.0/16"
  instance_type          = "t3.small"
  min_size               = 2
  max_size               = 4
  desired_capacity       = 2
  enable_monitoring_module = true

  aws_region                = var.aws_region
  project                   = var.project
  ssh_public_key            = var.ssh_public_key
  ansible_ssh_authorized_keys = var.ansible_ssh_authorized_keys
  bastion_allowed_cidrs     = var.bastion_allowed_cidrs
  newrelic_account_id       = var.newrelic_account_id
  newrelic_region           = var.newrelic_region
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "newrelic-fleet"
}

variable "ssh_public_key" {
  type    = string
  default = ""
}

variable "ansible_ssh_authorized_keys" {
  type    = list(string)
  default = []
}

variable "bastion_allowed_cidrs" {
  type    = list(string)
  default = []
}

variable "newrelic_account_id" {
  type    = number
  default = 0
}

variable "newrelic_region" {
  type    = string
  default = "US"
}

output "ansible_inventory_yaml" {
  value = module.stack.ansible_inventory_yaml
}

output "ansible_inventory_json" {
  value = module.stack.ansible_inventory_json
}
