# Environment root module. Thin on purpose: all the logic lives in modules/,
# so prod/ is this file with different variable values. Day 21 covers why
# "copy the folder, change the tfvars" beats clever workspaces.

module "network" {
  source = "../../modules/network"

  project              = var.project
  environment          = var.environment
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  enable_nat_gateway   = true
  single_nat_gateway   = var.environment != "prod"

  tags = {
    CostCenter = var.cost_center
    Owner      = var.owner
  }
}

module "security" {
  source = "../../modules/security"

  project               = var.project
  environment           = var.environment
  vpc_id                = module.network.vpc_id
  bastion_allowed_cidrs = var.bastion_allowed_cidrs

  tags = {
    CostCenter = var.cost_center
    Owner      = var.owner
  }
}

module "compute" {
  source = "../../modules/compute"

  project         = var.project
  environment     = var.environment
  vpc_id          = module.network.vpc_id
  subnet_ids      = values(module.network.private_subnet_ids)
  alb_subnet_ids  = values(module.network.public_subnet_ids)
  security_group_ids = [module.security.app_security_group_id]
  alb_security_group_id = module.security.alb_security_group_id

  instance_type    = var.instance_type
  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  ssh_public_key                = var.ssh_public_key
  ansible_ssh_authorized_keys   = var.ansible_ssh_authorized_keys

  create_bastion            = true
  bastion_subnet_id         = values(module.network.public_subnet_ids)[0]
  bastion_security_group_id = module.security.bastion_security_group_id
  alb_certificate_arn       = var.alb_certificate_arn

  tags = {
    CostCenter = var.cost_center
    Owner      = var.owner
  }
}

# Monitoring is optional so you can `terraform apply` the AWS side before you
# have a New Relic API key configured.
module "monitoring" {
  source = "../../modules/monitoring"
  count  = var.enable_monitoring_module ? 1 : 0

  project                  = var.project
  environment              = var.environment
  account_id               = var.newrelic_account_id
  notification_channel_ids = var.notification_channel_ids
}
