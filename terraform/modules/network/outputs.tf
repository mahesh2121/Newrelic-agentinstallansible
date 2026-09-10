output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, keyed by availability zone."
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, keyed by availability zone."
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "nat_gateway_public_ips" {
  description = "Egress IPs your monitoring traffic leaves from."
  value       = { for az, eip in aws_eip.nat : az => eip.public_ip }
}

output "flow_log_group_name" {
  description = "CloudWatch log group holding VPC flow logs."
  value       = try(aws_cloudwatch_log_group.flow_log[0].name, "")
}
