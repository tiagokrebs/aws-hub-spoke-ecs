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
    key     = "hub-spoke-ecs/terraform.tfstate"
    region  = "us-west-2"
    profile = "hub-me"
  }
}

locals {
  vpc_name         = "hub-spoke-vpc"
  vpc_cidr         = "10.0.0.0/16"
  subnet_cidr_1    = "10.0.1.0/24"
  subnet_cidr_2    = "10.0.2.0/24"
  shared_sg_name   = "hub-spoke-shared-sg"
  ecr_repo_name    = "apps"
  ecs_cluster_name = "hub-spoke-cluster"
  alb_name         = "hub-spoke-alb"
  container_port   = 80

  hub_role_name   = "HubECSRole"
  spoke_role_name = "SpokeECSRole"
}

# Default provider: spoke account (assumes SpokeExecutionRole)
provider "aws" {
  region  = var.region
  profile = var.hub_profile

  assume_role {
    role_arn     = "arn:aws:iam::${var.spoke_account_id}:role/SpokeExecutionRole"
    session_name = "terraform-spoke"
  }
}

# Hub provider: direct hub account access
provider "aws" {
  alias   = "hub"
  region  = var.region
  profile = var.hub_profile
}

data "aws_availability_zones" "available" {
  state = "available"
}
