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
    key     = "hub-spoke-ecs/ecs-caller/terraform.tfstate"
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

data "aws_ssm_parameter" "subnet_ids" {
  name = "/hub-spoke/vpc/subnet_ids"
}

data "aws_ssm_parameter" "security_group_id" {
  name = "/hub-spoke/vpc/security_group_id"
}

data "aws_ssm_parameter" "alb_dns_name" {
  name = "/hub-spoke/alb/dns_name"
}

# =============================================================================
# Lambda
# =============================================================================

module "lambda" {
  source = "../../constructs/lambda"

  function_name     = "ecs-caller"
  role_name         = "ecs-caller-lambda-role"
  source_file       = "${path.module}/../lambda/ecs_caller.py"
  handler           = "ecs_caller.lambda_handler"
  runtime           = "python3.11"
  timeout           = 30
  subnet_ids        = split(",", data.aws_ssm_parameter.subnet_ids.value)
  security_group_id = data.aws_ssm_parameter.security_group_id.value

  environment_variables = {
    ALB_DNS  = data.aws_ssm_parameter.alb_dns_name.value
    APP_NAME = var.app_name
  }
}
