variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name prefix."
  type        = string
  default     = "newrelic-fleet"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Team that owns these resources (for cost allocation)."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost centre tag value."
  type        = string
  default     = "sre-001"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to use."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "bastion_allowed_cidrs" {
  description = "CIDRs allowed to SSH into the bastion. Never 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "ssh_public_key" {
  description = "Public key material for the EC2 key pair."
  type        = string
}

variable "ansible_ssh_authorized_keys" {
  description = "Public keys written to instances by user_data for Ansible."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "EC2 instance type for the app tier."
  type        = string
  default     = "t3.micro"
}

variable "min_size" {
  description = "ASG minimum size."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "ASG maximum size."
  type        = number
  default     = 3
}

variable "desired_capacity" {
  description = "ASG desired capacity."
  type        = number
  default     = 2
}

# --- New Relic ----------------------------------------------------------------
variable "newrelic_account_id" {
  description = "New Relic account ID (numeric). Set NEW_RELIC_ACCOUNT_ID instead of committing it."
  type        = number
  default     = 0
}

variable "newrelic_region" {
  description = "New Relic account region: US or EU."
  type        = string
  default     = "US"

  validation {
    condition     = contains(["US", "EU"], var.newrelic_region)
    error_message = "newrelic_region must be US or EU."
  }
}

variable "enable_monitoring_module" {
  description = "Create New Relic alert policy and dashboard."
  type        = bool
  default     = false
}

variable "notification_channel_ids" {
  description = "New Relic notification destination IDs."
  type        = list(number)
  default     = []
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for the ALB. Empty = HTTP-only dev mode."
  type        = string
  default     = ""
}
