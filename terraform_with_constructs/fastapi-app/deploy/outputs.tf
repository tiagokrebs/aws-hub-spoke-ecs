output "service_name" {
  description = "ECS service name"
  value       = module.ecs_app.service_name
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = module.ecs_app.target_group_arn
}
