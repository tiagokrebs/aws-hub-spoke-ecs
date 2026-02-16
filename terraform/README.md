# Hub-Spoke ECS Deployment - Terraform (Monolithic)

Terraform deployment that creates all infrastructure in a single state file.

## Prerequisites

- Terraform (`brew install terraform`)
- AWS CLI with `hub-me` profile configured
- Docker running locally
- `SpokeExecutionRole` in spoke account with broad permissions (IAM, EC2, ECS, ECR, ELB, Lambda, CloudWatch, S3)

## Quick Start

```bash
# 1. Create S3 bucket for Terraform state (one-time, hub account)
aws s3 mb s3://hub-spoke-ecs-terraform-state --region us-west-2 --profile hub-me

# 2. Init and apply
cd terraform/
terraform init
terraform plan
terraform apply

# 3. Test from spoke account
./invoke_from_spoke.sh

# 4. Test from hub account (assumes SpokeExecutionRole)
./invoke_from_hub.sh

# 5. Destroy everything
terraform destroy
```

## Configuration

Edit `terraform.tfvars`:

```hcl
hub_account_id   = "294493538673"
spoke_account_id = "445876755019"
hub_profile      = "hub-me"
region           = "us-west-2"
app_name         = "fastapi-app"
app_version      = "v1"
```

## How It Works

- **Default provider** assumes `SpokeExecutionRole` in the spoke account — creates VPC, ECS, ALB, ECR, Lambda, and spoke IAM roles
- **Hub provider** uses `hub-me` profile directly — creates only `HubECSRole`
- **S3 backend** stores state in the hub account
- **Docker build/push** runs locally via `null_resource`, triggered when `app_version` changes
- **Lambda source** lives in `terraform/lambda/ecs_caller.py`, zipped automatically by Terraform

## File Structure

```
terraform/
├── main.tf              # Providers, backend, locals
├── variables.tf         # Input variables
├── terraform.tfvars     # Variable values
├── iam.tf               # IAM roles (hub + spoke)
├── network.tf           # VPC, subnets, security group, VPC endpoints
├── ecr.tf               # ECR repo + Docker build/push
├── alb.tf               # Internal ALB, listener, target group, routing rule
├── ecs.tf               # ECS cluster, task definition, service
├── lambda.tf            # Lambda role + function
├── outputs.tf           # ALB DNS, Lambda name, invoke command
├── invoke_from_spoke.sh # Test Lambda using spoke profile
├── invoke_from_hub.sh   # Test Lambda assuming role from hub
└── lambda/
    └── ecs_caller.py    # Lambda source code
```

## Dependency Graph

```
VPC (aws_vpc.main) "hub-spoke-vpc" 10.0.0.0/16
│
├── EC2 Subnet (aws_subnet.private_1) "hub-spoke-vpc-private-1" 10.0.1.0/24
│   └─ needs: vpc_id
├── EC2 Subnet (aws_subnet.private_2) "hub-spoke-vpc-private-2" 10.0.2.0/24
│   └─ needs: vpc_id
│
├── EC2 Security Group (aws_security_group.shared) "hub-spoke-shared-sg"
│   └─ needs: vpc_id
│   │
│   ├── ELB Application Load Balancer (aws_lb.main) "hub-spoke-alb" internal
│   │   └─ needs: security_groups, subnets
│   │   │
│   │   ├── ELB Listener (aws_lb_listener.http) HTTP:80, default 503
│   │   │   └─ needs: load_balancer_arn
│   │   │   │
│   │   │   └── ELB Listener Rule (aws_lb_listener_rule.app) /fastapi-app/* priority:10 ──┐
│   │   │       └─ needs: listener_arn, target_group_arn                                   │
│   │   │                                                                                  │
│   │   └── Lambda Function (aws_lambda_function.ecs_caller) "ecs-caller" python3.11       │
│   │       └─ needs: aws_lb.main.dns_name for ALB_DNS env var                             │
│   │                                                                                      │
│   ├── EC2 VPC Endpoint (aws_vpc_endpoint.ecr_api) Interface: ecr.api                     │
│   │   └─ needs: vpc_id, subnet_ids, security_group_ids                                   │
│   ├── EC2 VPC Endpoint (aws_vpc_endpoint.ecr_dkr) Interface: ecr.dkr                     │
│   │   └─ needs: vpc_id, subnet_ids, security_group_ids                                   │
│   └── EC2 VPC Endpoint (aws_vpc_endpoint.logs) Interface: logs                           │
│       └─ needs: vpc_id, subnet_ids, security_group_ids                                   │
│                                                                                          │
├── EC2 VPC Endpoint (aws_vpc_endpoint.s3) Gateway: s3                                     │
│   └─ needs: vpc_id, route_table_ids (main route table)                                   │
│                                                                                          │
└── ELB Target Group (aws_lb_target_group.app) "tg-fastapi-app" HTTP:80 ip ────────────────┘
    └─ needs: vpc_id

IAM Role (aws_iam_role.hub_ecs) "HubECSRole" [hub account]
│
├── IAM Role Policy (aws_iam_role_policy.hub_assume_spoke) "AssumeSpokECSRole"
│   └─ needs: role id to attach policy to
│
└── IAM Role (aws_iam_role.spoke_ecs) "SpokeECSRole" [spoke account]
    └─ needs: hub_ecs.arn for trust policy principal
    │
    └── IAM Role Policy (aws_iam_role_policy.spoke_ecs_management) "SpokECSManagementPolicy"
        └─ needs: spoke_ecs.id, ecs_task_execution.arn, ecs_task.arn for PassRole resources

IAM Role (aws_iam_role.ecs_task_execution) "ecsTaskExecutionRole"
│
├── IAM Policy Attachment (aws_iam_role_policy_attachment.ecs_task_execution)
│   └─ needs: role name to attach AmazonECSTaskExecutionRolePolicy
│
└──┐
   │
   ├── ECS Task Definition (aws_ecs_task_definition.app) "fastapi-app" Fargate 256cpu/512mem
   │   └─ needs: execution_role_arn, task_role_arn, ecr repository_url for image,
   │   │         log_group name, docker image must exist (null_resource)
   │   │
   │   └── ECS Service (aws_ecs_service.app) "fastapi-app" desired:1 Fargate
   │       └─ needs: cluster id, task_definition arn, subnet_ids,
   │                 security_group id, target_group_arn, listener_rule (explicit depends_on)
   │
IAM Role (aws_iam_role.ecs_task) "ecsTaskRole" ──┘

ECR Repository (aws_ecr_repository.apps) "apps"
│
└── null_resource (null_resource.docker_build_push) docker build+push apps:fastapi-app-v1
    └─ needs: repository_url for docker tag/push, ecr auth token for docker login
    │
    └── ECS Task Definition (aws_ecs_task_definition.app)
        └─ needs: image to exist in ECR before task can run

ECS Cluster (aws_ecs_cluster.main) "hub-spoke-cluster"
│
├── ECS Capacity Providers (aws_ecs_cluster_capacity_providers.main) FARGATE + FARGATE_SPOT
│   └─ needs: cluster_name
│
└── ECS Service (aws_ecs_service.app)
    └─ needs: cluster id

IAM Role (aws_iam_role.lambda) "ecs-caller-lambda-role"
│
└── IAM Policy Attachment (aws_iam_role_policy_attachment.lambda_vpc)
    └─ needs: role name to attach AWSLambdaVPCAccessExecutionRole
    │
    └── Lambda Function (aws_lambda_function.ecs_caller) "ecs-caller"
        └─ needs: role arn (via policy attachment depends_on), subnet_ids,
                  security_group id, ALB dns_name for env var, archive zip for code

CloudWatch Log Group (aws_cloudwatch_log_group.app) "/ecs/fastapi-app"
│
└── ECS Task Definition (aws_ecs_task_definition.app)
    └─ needs: log group name for awslogs config
```
