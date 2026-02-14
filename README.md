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

## Next Steps

- Deploy multiple apps with different names
- Add HTTPS by creating an ACM certificate
- Scale services by updating ECS service desired count
- Add alarms using CloudWatch metrics
- Integrate with CI/CD to auto-build and deploy on commit
