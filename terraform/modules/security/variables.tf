variable "project" {
  description = "Project name, used as a prefix for every resource."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups are created in."
  type        = string
}

variable "bastion_allowed_cidrs" {
  description = "CIDRs allowed to SSH into the bastion. Never use 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "app_ingress_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8080
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
