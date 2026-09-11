variable "project" {
  description = "Project name, used as a prefix for every resource."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the compute resources live in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the Auto Scaling group (private subnets)."
  type        = list(string)
}

variable "alb_subnet_ids" {
  description = "Subnets for the load balancer (public subnets, 2+ AZs)."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to each instance."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group for the load balancer."
  type        = string
}

variable "ami_id" {
  description = "AMI to launch. Leave empty to use the latest Ubuntu LTS."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key" {
  description = "Public key material for the EC2 key pair."
  type        = string
}

variable "min_size" {
  description = "Minimum number of instances in the ASG."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of instances in the ASG."
  type        = number
  default     = 3
}

variable "desired_capacity" {
  description = "Desired number of instances in the ASG."
  type        = number
  default     = 2
}

variable "app_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8080
}

# --- the Terraform -> Ansible hand-off ---------------------------------------
# Day 16: user_data only bootstraps enough for Ansible to connect.
# Everything else is Ansible's job, because Ansible is idempotent and
# user_data runs exactly once per instance lifetime.
variable "bootstrap_user" {
  description = "Default OS user of the AMI (ubuntu, ec2-user, admin)."
  type        = string
  default     = "ubuntu"
}

variable "ansible_ssh_authorized_keys" {
  description = "Public keys written to the bootstrap user by user_data."
  type        = list(string)
  default     = []
}

variable "ansible_pull_url" {
  description = "Optional git URL for ansible-pull. Empty = push mode only."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN. Empty = HTTP-only (dev mode, flagged by checkov)."
  type        = string
  default     = ""
}

variable "create_bastion" {
  description = "Create the bastion host used for SSH/Ansible access."
  type        = bool
  default     = true
}

variable "bastion_subnet_id" {
  description = "Public subnet for the bastion host."
  type        = string
  default     = ""
}

variable "bastion_security_group_id" {
  description = "Security group for the bastion host."
  type        = string
  default     = ""
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host."
  type        = string
  default     = "t3.micro"
}

variable "bastion_hostname" {
  description = "Inventory host name used for the bastion."
  type        = string
  default     = "bastion"
}

variable "enable_alb_deletion_protection" {
  description = "Protect the load balancer from accidental deletion (CKV_AWS_150)."
  type        = bool
  default     = true
}

variable "enable_alb_access_logs" {
  description = "Store ALB access logs in a purpose-built S3 bucket (CKV_AWS_91)."
  type        = bool
  default     = true
}

variable "alb_access_log_retention_days" {
  description = "Lifecycle expiration for ALB access logs."
  type        = number
  default     = 90
}

variable "aws_account_id" {
  description = "AWS account ID, used to make the log bucket name unique."
  type        = string
  default     = "000000000000"
}

variable "alb_log_delivery_principal" {
  description = "ELB account principal for your region (see AWS ELB access-log docs)."
  type        = string
  default     = "arn:aws:iam::718504428378:root"
}
