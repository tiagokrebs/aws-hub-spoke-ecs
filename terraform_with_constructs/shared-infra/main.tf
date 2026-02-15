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
    key     = "hub-spoke-ecs/shared-infra/terraform.tfstate"
    region  = "us-west-2"
    profile = "hub-me"
  }
}

locals {
  vpc_name         = "hub-spoke-vpc"
  vpc_cidr         = "10.0.0.0/16"
  shared_sg_name   = "hub-spoke-shared-sg"
  ecr_repo_name    = "apps"
  ecs_cluster_name = "hub-spoke-cluster"
  alb_name         = "hub-spoke-alb"
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

# =============================================================================
# Constructs
# =============================================================================

module "vpc" {
  source = "../constructs/vpc"

  vpc_name             = local.vpc_name
  vpc_cidr             = local.vpc_cidr
  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
}

module "security_group" {
  source = "../constructs/security-group"

  name     = local.shared_sg_name
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = local.vpc_cidr
}

module "vpc_endpoints" {
  source = "../constructs/vpc-endpoints"

  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.subnet_ids
  security_group_id = module.security_group.security_group_id
  route_table_id    = module.vpc.route_table_id
  region            = var.region
}

module "ecr" {
  source = "../constructs/ecr"

  name         = local.ecr_repo_name
  force_delete = true
}

module "ecs_cluster" {
  source = "../constructs/ecs-cluster"

  name = local.ecs_cluster_name
}

module "alb" {
  source = "../constructs/alb"

  name              = local.alb_name
  security_group_id = module.security_group.security_group_id
  subnet_ids        = module.vpc.subnet_ids
}
