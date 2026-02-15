# Hub-Spoke ECS Deployment

Deploy containerized applications across AWS accounts using a hub account to manage infrastructure in a spoke account.

## Quick Start

Running the full deployment takes ~10 minutes:

```bash
# 1. Set up infrastructure and roles (one-time)
./scripts/setup_infrastructure.sh

# 2. Build, push, and deploy an app
APP_NAME=fastapi-app APP_VERSION=v1 ./scripts/deploy_all.sh

# 3. Invoke the Lambda caller to test
./scripts/invoke_lambda.sh

# Expected output:
# {
#   "statusCode": 200,
#   "body": {
#     "message": "Hello from hub-spoke ECS!",
#     "hostname": "ip-10-0-2-118.us-west-2.compute.internal",
#     "environment": "production"
#   }
# }
```

## Architecture & Why

```
Hub Account (hub-me)
  └─> HubECSRole
       └─> Assumes SpokeECSRole in Spoke Account
            └─> Manages infrastructure in Spoke:
                 - Private VPC (no public internet access)
                 - ECS Fargate tasks running apps
                 - Internal ALB routing traffic between apps
                 - VPC endpoints for ECR, logs, S3 (no NAT needed)
                 - Lambda in same VPC calling apps via ALB
```

**Why this design:**

- **Private VPC + VPC Endpoints:** No internet gateway or NAT gateway needed. VPC endpoints connect directly to AWS services. Cheaper and more secure.
- **Internal ALB:** Apps communicate via private ALB DNS names. No Route53 or service discovery complexity.
- **Single shared ECR repo:** Apps tagged as `apps:app-name-v1`. One repo, multiple apps, clean tagging.
- **Per-app task definitions:** Each app has its own task definition, service, and target group. Easy to deploy new versions independently.
- **Lambda in same VPC:** Caller function runs in the same VPC with same security group. Direct access to ALB.

## Prerequisites

- AWS CLI (two profiles configured: `hub-me` and `spoke-me`)
- Docker
- `jq` for JSON parsing

## Setup Steps

### 1. Configure Accounts

Edit `.env`:

```bash
HUB_ACCOUNT_ID=123456789012        # Your hub account ID
SPOKE_ACCOUNT_ID=210987654321      # Your spoke account ID
HUB_PROFILE=hub-me                 # Hub AWS CLI profile
SPOKE_ROLE_NAME=SpokeECSRole       # Will be created in spoke

# Shared infrastructure names
VPC_NAME=hub-spoke-vpc
SHARED_ECR_REPO=apps               # Single repo for all apps
ECS_CLUSTER_NAME=hub-spoke-cluster
ALB_NAME=hub-spoke-alb

# Per-app (override at runtime)
APP_NAME=fastapi-app
APP_VERSION=v1
CONTAINER_PORT=80
```

### 2. One-Time Infrastructure Setup

```bash
./scripts/setup_infrastructure.sh
```

This creates:
- VPC with 2 private subnets (no public subnets)
- 4 VPC endpoints (ECR API, ECR DKR, CloudWatch Logs, S3)
- Shared security group with rules for internal traffic
- ECS cluster
- Internal ALB with HTTP:80 listener
- IAM roles in both accounts

### 3. Deploy Your App

For each app, run:

```bash
APP_NAME=my-app APP_VERSION=v1 ./scripts/deploy_all.sh
```

This:
1. Builds Docker image from `app/Dockerfile` (port 80)
2. Pushes to `apps:my-app-v1` in shared ECR
3. Creates task definition with `APP_PREFIX=/my-app` env var
4. Creates ECS service + target group + ALB path rule (`/my-app/*`)
5. Deploys Lambda caller that hits the ALB

### 4. Test

```bash
./scripts/invoke_lambda.sh
```

Or deploy multiple apps and they'll all coexist:

```bash
# App 1
APP_NAME=api APP_VERSION=v1 ./scripts/deploy_all.sh
# App 2
APP_NAME=worker APP_VERSION=v1 ./scripts/deploy_all.sh

# Lambda can be pointed at either via APP_NAME env var
APP_NAME=api ./scripts/deploy_lambda.sh
./scripts/invoke_lambda.sh  # Hits /api/* route
```

## How Apps Route Traffic

The ALB routes by path prefix:

```
Request: GET http://internal-alb-dns/my-app/
  ↓
ALB rule: /my-app/* → target group tg-my-app
  ↓
Task receives request, FastAPI sees /my-app/ (via APP_PREFIX env var)
  ↓
App routes: @app.get(f"{APP_PREFIX}/") matches /my-app/
```

The `APP_PREFIX` environment variable tells each app what path it's running under, so routes work correctly.

## File Structure

```
scripts/
  ├── setup_infrastructure.sh    # One-time: VPC, endpoints, ALB, cluster
  ├── setup_roles.sh             # IAM roles and trust relationships
  ├── build_push_app.sh          # Build image and push to shared ECR
  ├── deploy_app_ecs.sh          # Create task def, service, target group, ALB rule
  ├── deploy_lambda.sh           # Deploy Lambda caller in VPC
  ├── deploy_all.sh              # Run build + deploy_app + deploy_lambda
  ├── invoke_lambda.sh           # Test via Lambda
  ├── cleanup.sh                 # Delete all resources
  └── helpers.sh                 # Shared functions (VPC/ALB/SG discovery)

app/
  ├── main.py                    # FastAPI app with APP_PREFIX support
  └── Dockerfile                 # Build image, port 80
```

## Cleanup

```bash
./scripts/cleanup.sh
```

Deletes:
- All ECS services and task definitions
- ALB, listener rules, target groups
- VPC endpoints, security groups, subnets, VPC
- ECR repo, CloudWatch logs
- Lambda function

(Keeps IAM roles to prevent accidental deletion)

## Decisions Explained

**Why container port 80?** Standard HTTP port. Simpler ALB routing, no port mapping confusion.

**Why private subnets?** VPC endpoints provide direct access to AWS services. No NAT = faster, cheaper, more secure.

**Why shared ECR repo?** One repo, multiple images by tag (`apps:app-name-v1`). Cleaner than creating repos per app.

**Why ALB path-prefix routing?** All traffic through one ALB. Each app gets a path like `/my-app/*`. Easy to add/remove apps without reconfiguring DNS or load balancers.

**Why Lambda in VPC?** Same VPC as apps. No cross-VPC complications. Direct access to internal ALB via DNS.

**Why APP_PREFIX env var?** Apps need to know their route prefix. FastAPI registers routes with the prefix so paths work correctly under `/my-app/` instead of `/`.

## Troubleshooting

**Task won't start:** Check CloudWatch logs at `/ecs/APP_NAME`. Usually a VPC endpoint connectivity issue or security group rule missing.

**Lambda timeout:** Wait 30 seconds after deployment. Lambda ENI initialization takes time. The invoke script waits automatically.

**Health checks failing:** Confirm the app is listening on port 80 and the health check path matches `APP_PREFIX/health`.

**Cannot reach ALB:** Verify security group allows port 80/443 from VPC CIDR (10.0.0.0/16). Run setup_shared_infra.sh again to re-add rules.

## Terraform Deployment (Monolithic)

Alternative deployment using Terraform. Creates the same infrastructure as the bash scripts in a single state file.

### Prerequisites

- Terraform (`brew install terraform`)
- AWS CLI with `hub-me` profile configured
- Docker running locally
- `SpokeExecutionRole` in spoke account with broad permissions (IAM, EC2, ECS, ECR, ELB, Lambda, CloudWatch, S3)

### Quick Start

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

## Terraform with Constructs (Modular)

Production-ready modular Terraform setup. Separates shared infrastructure from per-app deployments using reusable modules and SSM parameters. Implements least-privilege by bootstrapping specific IAM roles and using only those for subsequent deployments.

### Architecture

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

### Deployment Flow (Least Privilege)

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

### Quick Start

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

### Key Differences from Monolithic Terraform

- **Multiple state files**: Each deployment module has its own state (cleaner, better for teams)
- **Modular constructs**: 8 reusable modules for VPC, ECS, ALB, ECR, Lambda, etc
- **SSM parameters**: Shared infrastructure exports values via SSM Parameter Store for app deployments to consume
- **Deploy independently**: Each app can be deployed/destroyed without affecting others or shared infra
- **Better for CI/CD**: Each app directory can be in its own Terraform pipeline

### Configuration

Edit `terraform/terraform.tfvars`:

```hcl
hub_account_id   = "294493538673"
spoke_account_id = "445876755019"
hub_profile      = "hub-me"
region           = "us-west-2"
app_name         = "fastapi-app"
app_version      = "v1"
```

### How It Works

- **Default provider** assumes `SpokeExecutionRole` in the spoke account — creates VPC, ECS, ALB, ECR, Lambda, and spoke IAM roles
- **Hub provider** uses `hub-me` profile directly — creates only `HubECSRole`
- **S3 backend** stores state in the hub account
- **Docker build/push** runs locally via `null_resource`, triggered when `app_version` changes
- **Lambda source** lives in `terraform/lambda/ecs_caller.py`, zipped automatically by Terraform

### File Structure

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

### Dependency Graph

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

## Next Steps

- Deploy multiple apps with different names
- Add HTTPS by creating an ACM certificate
- Scale services by updating ECS service desired count
- Add alarms using CloudWatch metrics
- Integrate with CI/CD to auto-build and deploy on commit
