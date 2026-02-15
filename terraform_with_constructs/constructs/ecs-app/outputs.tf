output "service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.this.name
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = aws_lb_target_group.this.arn
}
