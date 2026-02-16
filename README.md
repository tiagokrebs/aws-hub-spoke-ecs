# Hub-Spoke ECS Deployment

Deploy containerized applications across AWS accounts using a hub account to manage infrastructure in a spoke account.

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

## Deployment Methods

Choose one of these three approaches:

### 1. [Bash Scripts](./scripts/README.md)
Simple shell scripts using AWS CLI. Good for learning and quick deployments.
- Fast setup
- Direct control
- Best for single environments

### 2. [Terraform (Monolithic)](./terraform/README.md)
All infrastructure in a single Terraform state file.
- IaC approach
- Reproducible
- Easier versioning

### 3. [Terraform with Constructs (Modular)](./terraform_with_constructs/README.md) **[Recommended for Production]**
Modular Terraform with reusable constructs and separate state files.
- Production-ready
- Least-privilege IAM
- Team-friendly (independent app deployments)
- Better for CI/CD pipelines

## Prerequisites (All Methods)

- AWS CLI (two profiles configured: `hub-me` and `spoke-me`)
- Docker
- For Terraform methods: `terraform` installed

## Next Steps

- Deploy multiple apps with different names
- Add HTTPS by creating an ACM certificate
- Scale services by updating ECS service desired count
- Add alarms using CloudWatch metrics
- Integrate with CI/CD to auto-build and deploy on commit
