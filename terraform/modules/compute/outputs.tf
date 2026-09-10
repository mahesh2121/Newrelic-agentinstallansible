output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group."
  value       = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  description = "ID of the launch template."
  value       = aws_launch_template.this.id
}

output "instance_profile_name" {
  description = "IAM instance profile attached to instances."
  value       = aws_iam_instance_profile.this.name
}

output "alb_dns_name" {
  description = "DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route 53 zone ID of the load balancer (for alias records)."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "ARN of the ALB target group."
  value       = aws_lb_target_group.this.arn
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host (Ansible/SSH entry point)."
  value       = try(aws_instance.bastion[0].public_ip, "")
}

output "bastion_private_ip" {
  description = "Private IP of the bastion host."
  value       = try(aws_instance.bastion[0].private_ip, "")
}

output "bastion_inventory_host" {
  description = "Ansible host definition for the bastion, ready to merge into inventory."
  value = try({
    (var.bastion_hostname) = {
      ansible_host = aws_instance.bastion[0].public_ip
      ansible_user = var.bootstrap_user
      instance_id  = aws_instance.bastion[0].id
      role         = "bastion"
    }
  }, {})
}
