variable "app_name" {
  description = "Name of the application"
  type        = string
}

variable "app_version" {
  description = "Version tag for the application"
  type        = string
}

variable "app_path" {
  description = "Path to the application source (docker build context)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the ECS cluster"
  type        = string
}

variable "ecr_repo_url" {
  description = "URL of the ECR repository"
  type        = string
}

variable "task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the ECS task role"
  type        = string
}

variable "subnet_ids" {
  description = "IDs of the subnets for the ECS service"
  type        = list(string)
}

variable "security_group_id" {
  description = "ID of the security group for the ECS service"
  type        = string
}

variable "listener_arn" {
  description = "ARN of the ALB listener"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority for the ALB listener rule"
  type        = number
  default     = 10
}
