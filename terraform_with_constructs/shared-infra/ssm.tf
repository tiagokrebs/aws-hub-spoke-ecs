resource "aws_ssm_parameter" "vpc_id" {
  name  = "/hub-spoke/vpc/id"
  type  = "String"
  value = module.vpc.vpc_id
}

resource "aws_ssm_parameter" "subnet_ids" {
  name  = "/hub-spoke/vpc/subnet_ids"
  type  = "String"
  value = join(",", module.vpc.subnet_ids)
}

resource "aws_ssm_parameter" "security_group_id" {
  name  = "/hub-spoke/vpc/security_group_id"
  type  = "String"
  value = module.security_group.security_group_id
}

resource "aws_ssm_parameter" "alb_arn" {
  name  = "/hub-spoke/alb/arn"
  type  = "String"
  value = module.alb.alb_arn
}

resource "aws_ssm_parameter" "alb_dns_name" {
  name  = "/hub-spoke/alb/dns_name"
  type  = "String"
  value = module.alb.alb_dns_name
}

resource "aws_ssm_parameter" "alb_listener_arn" {
  name  = "/hub-spoke/alb/listener_arn"
  type  = "String"
  value = module.alb.listener_arn
}

resource "aws_ssm_parameter" "ecs_cluster_name" {
  name  = "/hub-spoke/ecs/cluster_name"
  type  = "String"
  value = module.ecs_cluster.cluster_name
}

resource "aws_ssm_parameter" "ecr_repository_url" {
  name  = "/hub-spoke/ecr/repository_url"
  type  = "String"
  value = module.ecr.repository_url
}

resource "aws_ssm_parameter" "task_execution_role_arn" {
  name  = "/hub-spoke/iam/task_execution_role_arn"
  type  = "String"
  value = aws_iam_role.ecs_task_execution.arn
}

resource "aws_ssm_parameter" "task_role_arn" {
  name  = "/hub-spoke/iam/task_role_arn"
  type  = "String"
  value = aws_iam_role.ecs_task.arn
}
