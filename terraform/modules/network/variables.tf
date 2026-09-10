variable "project" {
  description = "Project name, used as a prefix for every resource."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "One CIDR per availability zone, for public subnets."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One CIDR per availability zone, for private subnets."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "enable_nat_gateway" {
  description = "Provision NAT gateway(s) so private subnets reach the internet."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheap, dev). false = one per AZ (prod)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "enable_flow_logs" {
  description = "Create VPC flow logs (CKV2_AWS_11)."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for flow logs. 365 satisfies CKV_AWS_338."
  type        = number
  default     = 365
}

variable "aws_region" {
  description = "Region, used for the CloudWatch Logs KMS grant condition."
  type        = string
  default     = "ap-south-1"
}
