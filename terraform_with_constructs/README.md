# Hub-Spoke ECS Deployment - Terraform with Constructs (Modular)

Production-ready modular Terraform setup. Separates shared infrastructure from per-app deployments using reusable modules and SSM parameters. Implements least-privilege by bootstrapping specific IAM roles and using only those for subsequent deployments.

## Architecture

```
terraform_with_constructs/
├── constructs/                  # Reusable Terraform modules (vpc, ecr, ecs-cluster, alb, ecs-app, lambda, etc)
├── shared-infra/                # Shared infrastructure (one state file)
│   └── Creates: VPC, ALB, ECS cluster, ECR, IAM roles, exports via SSM
├── fastapi-app/deploy/          # FastAPI app deployment (separate state file)
│   └── Creates: ECS task definition, service, target group, listener rule
└── ecs-caller/deploy/           # Lambda app deployment (separate state file)
    └── Creates: Lambda function and IAM role
```

## Deployment Flow (Least Privilege)

1. **shared-infra**: `hub-me` assumes `SpokeExecutionRole` (admin) → bootstraps:
   - `SpokeECSRole` (specific ECS, ECR, Lambda, CloudWatch, ALB permissions)
   - `ecsTaskExecutionRole` (for ECS task execution)
   - `ecsTaskRole` (for ECS task permissions)
   - Infrastructure: VPC, ALB, ECS cluster, ECR repository
   - Exports all values to SSM Parameter Store

2. **fastapi-app/deploy**: `hub-me` assumes `SpokeECSRole` (specific permissions) → deploys:
   - ECS task definition
   - ECS service + target group
   - ALB listener rule
   - Reads shared infrastructure from SSM parameters

3. **ecs-caller/deploy**: `hub-me` assumes `SpokeECSRole` (specific permissions) → deploys:
   - Lambda function
   - Lambda IAM role
   - Reads shared infrastructure from SSM parameters

**Key benefit**: `SpokeExecutionRole` (admin) is used only once to create the specific roles. All subsequent operations use `SpokeECSRole` with minimal permissions. This provides clear audit trails and prevents accidental privilege escalation.

## Quick Start

```bash
# 1. Create S3 bucket for Terraform state (one-time, hub account)
aws s3 mb s3://hub-spoke-ecs-terraform-state --region us-west-2 --profile hub-me

# 2. Deploy shared infrastructure
cd terraform_with_constructs/shared-infra
terraform init
terraform apply

# 3. Deploy FastAPI app
cd ../fastapi-app/deploy
terraform init
terraform apply

# 4. Deploy Lambda caller
cd ../../ecs-caller/deploy
terraform init
terraform apply

# 5. Test the Lambda
./invoke_from_spoke.sh spoke-me
# Or from hub account:
./invoke_from_hub.sh hub-me

# 6. Destroy everything (reverse order)
cd ../../ecs-caller/deploy
terraform destroy

cd ../../../fastapi-app/deploy
terraform destroy

cd ../../shared-infra
terraform destroy
```

## Key Differences from Monolithic Terraform

- **Multiple state files**: Each deployment module has its own state (cleaner, better for teams)
- **Modular constructs**: 8 reusable modules for VPC, ECS, ALB, ECR, Lambda, etc
- **SSM parameters**: Shared infrastructure exports values via SSM Parameter Store for app deployments to consume
- **Deploy independently**: Each app can be deployed/destroyed without affecting others or shared infra
- **Better for CI/CD**: Each app directory can be in its own Terraform pipeline

## Configuration

Edit `terraform/terraform.tfvars`:

```hcl
hub_account_id   = "294493538673"
spoke_account_id = "445876755019"
hub_profile      = "hub-me"
region           = "us-west-2"
app_name         = "fastapi-app"
app_version      = "v1"
```
