#!/usr/bin/env bash
set -euo pipefail

# Check for --dry-run flag
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift || true
fi

# Load helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/helpers.sh"

# Load .env
if ! check_env_file; then
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${HUB_ACCOUNT_ID:?must be set}"
: "${SPOKE_ACCOUNT_ID:?must be set}"
: "${HUB_PROFILE:?must be set}"
: "${SPOKE_ROLE_NAME:?must be set}"

HUB_ROLE_NAME="${HUB_ROLE_NAME:-HubECSRole}"

if [[ $DRY_RUN -eq 1 ]]; then
  print_dry_run_header
fi

print_section "Setup Roles Configuration"
print_info "Hub account:   ${HUB_ACCOUNT_ID} (profile ${HUB_PROFILE})"
print_info "Spoke account: ${SPOKE_ACCOUNT_ID}"
echo

# Validate prerequisites
validate_prerequisites || exit 1

# Check AWS profiles and credentials
print_section "Validating AWS Configuration"
check_aws_profile "${HUB_PROFILE}" || exit 1
check_aws_credentials "${HUB_PROFILE}" || exit 1
echo

# === 1. Assume SpokeExecutionRole (bootstrap role) into temporary profile ===

SPOKE_EXECUTION_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/SpokeExecutionRole"
TMP_PROFILE="spoke-from-hub"

print_section "Step 1: Assume SpokeExecutionRole (Bootstrap)"
print_info "Bootstrap Role ARN: ${SPOKE_EXECUTION_ROLE_ARN}"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Assuming SpokeExecutionRole using hub profile ${HUB_PROFILE} ..."
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "${SPOKE_EXECUTION_ROLE_ARN}" \
      --role-session-name "hub-to-spoke-ecs-setup" \
      --profile "${HUB_PROFILE}" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
  )

  aws configure set aws_access_key_id     "${AWS_ACCESS_KEY_ID}"     --profile "${TMP_PROFILE}"
  aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}" --profile "${TMP_PROFILE}"
  aws configure set aws_session_token     "${AWS_SESSION_TOKEN}"     --profile "${TMP_PROFILE}"

  print_success "Created temporary profile ${TMP_PROFILE}"

  # Fetch region from profile
  REGION=$(aws configure get region --profile "${TMP_PROFILE}")
  if [[ -z "${REGION}" ]]; then
    print_error "Could not determine region from profile ${TMP_PROFILE}"
    exit 1
  fi
  print_info "Region: ${REGION}"
else
  print_info "[DRY-RUN] Would assume SpokeExecutionRole and create temporary profile '${TMP_PROFILE}'"
  REGION="us-west-2"  # Placeholder for dry-run
fi
echo

# === 2. Create HubECSRole in hub account ===

print_section "Step 2: Create HubECSRole in Hub Account"
print_info "Role name: ${HUB_ROLE_NAME}"

cat > hub-ecs-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${HUB_ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  aws iam get-role \
    --role-name "${HUB_ROLE_NAME}" \
    --profile "${HUB_PROFILE}" >/dev/null 2>&1
  hub_role_exists=$?
  set -e

  if [[ $hub_role_exists -ne 0 ]]; then
    print_info "Creating role ${HUB_ROLE_NAME} ..."
    aws iam create-role \
      --role-name "${HUB_ROLE_NAME}" \
      --assume-role-policy-document file://hub-ecs-trust.json \
      --profile "${HUB_PROFILE}" >/dev/null
    print_success "Role created"
  else
    print_info "Role ${HUB_ROLE_NAME} exists; updating trust policy ..."
    aws iam update-assume-role-policy \
      --role-name "${HUB_ROLE_NAME}" \
      --policy-document file://hub-ecs-trust.json \
      --profile "${HUB_PROFILE}" >/dev/null
    print_success "Trust policy updated"
  fi
else
  print_info "[DRY-RUN] Would create/update role '${HUB_ROLE_NAME}' with trust policy"
fi

cat > hub-assume-spoke.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeSpokECSRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/${SPOKE_ROLE_NAME}"
    }
  ]
}
EOF

if [[ $DRY_RUN -eq 0 ]]; then
  aws iam put-role-policy \
    --role-name "${HUB_ROLE_NAME}" \
    --policy-name "AssumeSpokECSRole" \
    --policy-document file://hub-assume-spoke.json \
    --profile "${HUB_PROFILE}" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then
    print_success "Inline policy attached to role"
  else
    print_error "Failed to attach inline policy to ${HUB_ROLE_NAME}"
    exit 1
  fi
else
  print_info "[DRY-RUN] Would attach inline policy 'AssumeSpokECSRole' to '${HUB_ROLE_NAME}'"
fi
echo

# === 3. Get Hub Role ARN and wait for visibility ===

print_section "Step 3: Get Hub Role ARN"

HUB_ROLE_ARN=""
if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Waiting for ${HUB_ROLE_NAME} to be visible in IAM ..."
  for i in {1..10}; do
    HUB_ROLE_ARN=$(aws iam get-role \
      --role-name "${HUB_ROLE_NAME}" \
      --profile "${HUB_PROFILE}" \
      --query 'Role.Arn' \
      --output text 2>/dev/null || true)
    # Trim whitespace
    HUB_ROLE_ARN=$(echo -n "${HUB_ROLE_ARN}" | xargs)
    if [[ -n "${HUB_ROLE_ARN}" && "${HUB_ROLE_ARN}" != "None" ]]; then
      print_success "Role visible (attempt $i/10)"
      break
    fi
    print_warning "Role not visible yet, waiting 3s (attempt $i/10)..."
    sleep 3
  done

  if [[ -z "${HUB_ROLE_ARN}" || "${HUB_ROLE_ARN}" == "None" ]]; then
    print_error "Hub role ARN still not visible after retries"
    exit 1
  fi
else
  HUB_ROLE_ARN="arn:aws:iam::${HUB_ACCOUNT_ID}:role/${HUB_ROLE_NAME}"
  print_info "[DRY-RUN] Would wait for role visibility (simulated ARN: ${HUB_ROLE_ARN})"
fi

print_info "Hub role ARN: ${HUB_ROLE_ARN}"
echo

# === 4. Create SpokeECSRole in spoke account ===

print_section "Step 4: Create SpokeECSRole in Spoke Account"
print_info "Role name: ${SPOKE_ROLE_NAME}"

if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  aws iam get-role \
    --role-name "${SPOKE_ROLE_NAME}" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  spoke_role_exists=$?
  set -e

  if [[ $spoke_role_exists -ne 0 ]]; then
    print_info "Creating placeholder role ${SPOKE_ROLE_NAME} ..."
    aws iam create-role \
      --role-name "${SPOKE_ROLE_NAME}" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Deny",
            "Principal": { "AWS": "*" },
            "Action": "sts:AssumeRole"
          }
        ]
      }' \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      print_success "Role created"
    else
      print_error "Failed to create ${SPOKE_ROLE_NAME}"
      exit 1
    fi
  else
    print_success "Role ${SPOKE_ROLE_NAME} already exists"
  fi
else
  print_info "[DRY-RUN] Would create/verify role '${SPOKE_ROLE_NAME}' in spoke account"
fi

print_info "Updating trust policy for ${SPOKE_ROLE_NAME} to trust hub role..."
# Ensure ARN is clean and properly formatted
HUB_ROLE_ARN_CLEAN=$(echo -n "${HUB_ROLE_ARN}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
cat > spoke-ecs-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${HUB_ROLE_ARN_CLEAN}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
print_info "Trust policy principal: ${HUB_ROLE_ARN_CLEAN}"

if [[ $DRY_RUN -eq 0 ]]; then
  aws iam update-assume-role-policy \
    --role-name "${SPOKE_ROLE_NAME}" \
    --policy-document file://spoke-ecs-trust.json \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then
    print_success "Trust policy updated"
  else
    print_error "Failed to update trust policy for ${SPOKE_ROLE_NAME}"
    exit 1
  fi
else
  print_info "[DRY-RUN] Would update trust policy to allow ${HUB_ROLE_NAME} to assume this role"
fi

# Attach ECS management permissions
print_info "Attaching ECS management permissions..."
cat > spoke-ecs-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRManagement",
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${SPOKE_ACCOUNT_ID}:repository/*"
    },
    {
      "Sid": "ECRAuthorization",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSClusterManagement",
      "Effect": "Allow",
      "Action": [
        "ecs:CreateCluster",
        "ecs:DescribeClusters",
        "ecs:RegisterTaskDefinition",
        "ecs:CreateService",
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:ListServices",
        "ecs:ListTaskDefinitions",
        "ecs:DescribeTaskDefinition",
        "ecs:DeleteCluster",
        "ecs:DeleteService"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2VPCManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DescribeVpcs",
        "ec2:CreateSubnet",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeNetworkInterfaces",
        "ec2:CreateVpcEndpoint",
        "ec2:DescribeVpcEndpoints",
        "ec2:DeleteVpcEndpoints",
        "ec2:DescribeRouteTables",
        "ec2:CreateTags",
        "ec2:ModifyVpcAttribute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ALBManagement",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/ecsTaskExecutionRole",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    },
    {
      "Sid": "IAMPassRoleTask",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/ecsTaskRole"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:${REGION}:${SPOKE_ACCOUNT_ID}:log-group:/ecs/*"
    }
  ]
}
EOF

if [[ $DRY_RUN -eq 0 ]]; then
  aws iam put-role-policy \
    --role-name "${SPOKE_ROLE_NAME}" \
    --policy-name "SpokECSManagementPolicy" \
    --policy-document file://spoke-ecs-policy.json \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then
    print_success "Permissions attached"
  else
    print_error "Failed to attach ECS management policy to ${SPOKE_ROLE_NAME}"
    exit 1
  fi
else
  print_info "[DRY-RUN] Would attach ECS management policy to '${SPOKE_ROLE_NAME}'"
fi
echo

# === 5. Create ECS task execution role ===

print_section "Step 5: Create ECS Task Execution Role"

cat > ecs-task-execution-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  aws iam get-role \
    --role-name "ecsTaskExecutionRole" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  exec_role_exists=$?
  set -e

  if [[ $exec_role_exists -ne 0 ]]; then
    print_info "Creating ecsTaskExecutionRole ..."
    aws iam create-role \
      --role-name "ecsTaskExecutionRole" \
      --assume-role-policy-document file://ecs-task-execution-trust.json \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      print_success "Role created"
    else
      print_error "Failed to create ecsTaskExecutionRole"
      exit 1
    fi
  else
    print_success "ecsTaskExecutionRole already exists"
  fi

  print_info "Attaching AmazonECSTaskExecutionRolePolicy ..."
  set +e
  aws iam attach-role-policy \
    --role-name "ecsTaskExecutionRole" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  attach_status=$?
  set -e

  if [[ $attach_status -eq 0 ]]; then
    print_success "Policy attached"
  else
    # Policy might already be attached, which is fine
    print_success "Policy attached (or already attached)"
  fi
else
  print_info "[DRY-RUN] Would create 'ecsTaskExecutionRole' and attach managed policy"
fi
echo

# === 6. Create ECS task role ===

print_section "Step 6: Create ECS Task Role"

if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  aws iam get-role \
    --role-name "ecsTaskRole" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  task_role_exists=$?
  set -e

  if [[ $task_role_exists -ne 0 ]]; then
    print_info "Creating ecsTaskRole ..."
    aws iam create-role \
      --role-name "ecsTaskRole" \
      --assume-role-policy-document file://ecs-task-execution-trust.json \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      print_success "Role created"
    else
      print_error "Failed to create ecsTaskRole"
      exit 1
    fi
  else
    print_success "ecsTaskRole already exists"
  fi
else
  print_info "[DRY-RUN] Would create 'ecsTaskRole'"
fi
echo

# === 7. Create ECS Service-Linked Role ===

print_section "Step 7: Create ECS Service-Linked Role"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Creating ECS service-linked role..."
  set +e
  aws iam create-service-linked-role \
    --aws-service-name ecs.amazonaws.com \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1
  create_status=$?
  set -e

  if [[ $create_status -eq 0 ]]; then
    print_success "Service-linked role created"
  else
    # Role might already exist, which is fine
    print_success "Service-linked role ready (already exists or just created)"
  fi
else
  print_info "[DRY-RUN] Would create ECS service-linked role"
fi
echo

print_section "Summary"
print_success "Setup complete!"
echo
print_info "Hub ECS role                    : ${HUB_ROLE_ARN}"
print_info "Spoke ECS role                 : arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/${SPOKE_ROLE_NAME}"
print_info "ECS Task Execution Role        : arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/ecsTaskExecutionRole"
print_info "ECS Task Role                  : arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/ecsTaskRole"
print_info "ECS Service-Linked Role        : AWSServiceRoleForECS"
print_info "Temporary profile              : ${TMP_PROFILE}"
echo

if [[ $DRY_RUN -eq 1 ]]; then
  print_warning "DRY-RUN COMPLETE: No changes were made. Run without --dry-run to execute."
fi
echo

# Clean up temp files
rm -f hub-ecs-trust.json hub-assume-spoke.json spoke-ecs-trust.json spoke-ecs-policy.json ecs-task-execution-trust.json
