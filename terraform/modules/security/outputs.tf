output "bastion_security_group_id" {
  description = "Security group ID for the bastion host."
  value       = aws_security_group.bastion.id
}

output "app_security_group_id" {
  description = "Security group ID for the application tier."
  value       = aws_security_group.app.id
}

output "alb_security_group_id" {
  description = "Security group ID for the load balancer."
  value       = aws_security_group.alb.id
}
