terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "hub-spoke-ecs-terraform-state"
    key     = "hub-spoke-ecs/fastapi-app/terraform.tfstate"
    region  = "us-west-2"
    profile = "hub-me"
  }
}

provider "aws" {
  region  = var.region
  profile = var.hub_profile

  assume_role {
    role_arn     = "arn:aws:iam::${var.spoke_account_id}:role/SpokeECSRole"
    session_name = "terraform-spoke-ecs"
  }
}

# =============================================================================
# SSM Parameter Lookups
# =============================================================================

data "aws_ssm_parameter" "vpc_id" {
  name = "/hub-spoke/vpc/id"
}

data "aws_ssm_parameter" "subnet_ids" {
  name = "/hub-spoke/vpc/subnet_ids"
}

data "aws_ssm_parameter" "security_group_id" {
  name = "/hub-spoke/vpc/security_group_id"
}

data "aws_ssm_parameter" "listener_arn" {
  name = "/hub-spoke/alb/listener_arn"
}

data "aws_ssm_parameter" "ecs_cluster_name" {
  name = "/hub-spoke/ecs/cluster_name"
}

data "aws_ssm_parameter" "ecr_repository_url" {
  name = "/hub-spoke/ecr/repository_url"
}

data "aws_ssm_parameter" "task_execution_role_arn" {
  name = "/hub-spoke/iam/task_execution_role_arn"
}

data "aws_ssm_parameter" "task_role_arn" {
  name = "/hub-spoke/iam/task_role_arn"
}

# =============================================================================
# ECS App
# =============================================================================

module "ecs_app" {
  source = "../../constructs/ecs-app"

  app_name               = var.app_name
  app_version            = var.app_version
  app_path               = "${path.module}/../app"
  cluster_name           = data.aws_ssm_parameter.ecs_cluster_name.value
  ecr_repo_url           = data.aws_ssm_parameter.ecr_repository_url.value
  task_execution_role_arn = data.aws_ssm_parameter.task_execution_role_arn.value
  task_role_arn           = data.aws_ssm_parameter.task_role_arn.value
  subnet_ids             = split(",", data.aws_ssm_parameter.subnet_ids.value)
  security_group_id      = data.aws_ssm_parameter.security_group_id.value
  listener_arn           = data.aws_ssm_parameter.listener_arn.value
  vpc_id                 = data.aws_ssm_parameter.vpc_id.value
  region                 = var.region
}
