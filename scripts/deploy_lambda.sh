#!/usr/bin/env bash
set -euo pipefail

# Check for --dry-run flag
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
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
: "${VPC_NAME:?must be set}"
: "${SHARED_SG_NAME:?must be set}"
: "${ALB_NAME:?must be set}"

# Per-app parameter
APP_NAME="${APP_NAME:-fastapi-app}"

if [[ -z "${APP_NAME}" ]]; then
  print_error "APP_NAME not set"
  exit 1
fi

TMP_PROFILE="spoke-from-hub"

if [[ $DRY_RUN -eq 1 ]]; then
  print_dry_run_header
fi

print_section "Deploy Lambda to Call ECS App via ALB"
print_info "App Name:           ${APP_NAME}"
print_info "ALB Name:           ${ALB_NAME}"
print_info "VPC Name:           ${VPC_NAME}"
echo

# Validate prerequisites
validate_prerequisites || exit 1

if [[ $DRY_RUN -eq 1 ]]; then
  print_info "[DRY-RUN] Would deploy Lambda function:"
  print_info "  - Function name: ecs-caller"
  print_info "  - Runtime: python3.11"
  print_info "  - IAM role: ecs-caller-lambda-role"
  print_info "  - VPC configuration with shared security group"
  print_info "  - Calls ALB endpoint for app: ${APP_NAME}"
  echo
  print_warning "DRY-RUN COMPLETE: No changes were made. Run without --dry-run to execute."
  echo
  exit 0
fi

# === Step 1: Assume SpokeECSRole ===

print_section "Step 1: Assume SpokeECSRole"

if ! aws sts get-caller-identity --profile "${TMP_PROFILE}" >/dev/null 2>&1; then
  print_info "Assuming SpokeECSRole using hub profile ${HUB_PROFILE} ..."
  SPOKE_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/${SPOKE_ROLE_NAME}"
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "${SPOKE_ROLE_ARN}" \
      --role-session-name "hub-to-spoke-lambda" \
      --profile "${HUB_PROFILE}" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
  )

  aws configure set aws_access_key_id     "${AWS_ACCESS_KEY_ID}"     --profile "${TMP_PROFILE}"
  aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}" --profile "${TMP_PROFILE}"
  aws configure set aws_session_token     "${AWS_SESSION_TOKEN}"     --profile "${TMP_PROFILE}"

  print_success "Created temporary profile ${TMP_PROFILE}"
else
  print_success "Temporary profile ${TMP_PROFILE} already exists"
fi
echo

# === Step 2: Discover VPC and resources ===

print_section "Step 2: Discover VPC and Resources"

# Fetch region
REGION=$(aws configure get region --profile "${TMP_PROFILE}")
if [[ -z "${REGION}" ]]; then
  print_error "Could not determine region from profile ${TMP_PROFILE}"
  exit 1
fi
print_info "Region: ${REGION}"

# Get VPC ID
VPC_ID=$(get_vpc_id)
if [[ -z "${VPC_ID}" ]] || [[ "${VPC_ID}" == "None" ]]; then
  print_error "VPC not found: ${VPC_NAME}"
  exit 1
fi
print_success "VPC: ${VPC_ID}"

# Get subnet IDs
SUBNET_IDS=$(get_private_subnet_ids "${VPC_ID}")
if [[ -z "${SUBNET_IDS}" ]]; then
  print_error "No private subnets found in VPC ${VPC_ID}"
  exit 1
fi
SUBNET_ID_1=$(echo "${SUBNET_IDS}" | awk '{print $1}')
SUBNET_ID_2=$(echo "${SUBNET_IDS}" | awk '{print $2}')
print_success "Subnets: ${SUBNET_ID_1}, ${SUBNET_ID_2}"

# Get SG ID
SG_ID=$(get_shared_sg_id)
if [[ -z "${SG_ID}" ]] || [[ "${SG_ID}" == "None" ]]; then
  print_error "Security group not found: ${SHARED_SG_NAME}"
  exit 1
fi
print_success "Security Group: ${SG_ID}"

# Get ALB DNS
ALB_DNS=$(get_alb_dns)
if [[ -z "${ALB_DNS}" ]] || [[ "${ALB_DNS}" == "None" ]]; then
  print_error "ALB not found: ${ALB_NAME}"
  exit 1
fi
print_success "ALB DNS: ${ALB_DNS}"
echo

# === Step 3: Create Lambda code ===

print_section "Step 3: Create Lambda Function Code"

print_info "Creating Lambda function code..."
cat > /tmp/ecs_caller.py << 'PYEOF'
import json
import urllib.request
import os

def lambda_handler(event, context):
    alb_dns = os.environ['ALB_DNS']
    app_name = os.environ['APP_NAME']

    url = f"http://{alb_dns}/{app_name}/"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return {
                'statusCode': response.status,
                'body': json.loads(response.read().decode('utf-8'))
            }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': {'error': str(e)}
        }
PYEOF

cd /tmp
zip -q ecs_caller.zip ecs_caller.py
print_success "Lambda package created"
echo

# === Step 4: Create IAM role ===

print_section "Step 4: Create Lambda Execution Role"

print_info "Creating/verifying Lambda execution role..."
ROLE_ARN=$(aws iam create-role \
  --role-name ecs-caller-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --profile "${TMP_PROFILE}" \
  --query 'Role.Arn' \
  --output text 2>/dev/null || \
  aws iam get-role \
    --role-name ecs-caller-lambda-role \
    --profile "${TMP_PROFILE}" \
    --query 'Role.Arn' \
    --output text)

aws iam attach-role-policy \
  --role-name ecs-caller-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole \
  --profile "${TMP_PROFILE}" 2>/dev/null || true

print_success "Role created/verified: ${ROLE_ARN}"
print_info "Waiting for IAM propagation..."
sleep 10
echo

# === Step 5: Create/Update Lambda function ===

print_section "Step 5: Create/Update Lambda Function"

print_info "Creating Lambda function ecs-caller..."
aws lambda create-function \
  --function-name ecs-caller \
  --runtime python3.11 \
  --role "${ROLE_ARN}" \
  --handler ecs_caller.lambda_handler \
  --zip-file fileb:///tmp/ecs_caller.zip \
  --timeout 30 \
  --vpc-config "SubnetIds=${SUBNET_ID_1},${SUBNET_ID_2},SecurityGroupIds=${SG_ID}" \
  --environment "Variables={ALB_DNS=${ALB_DNS},APP_NAME=${APP_NAME}}" \
  --profile "${TMP_PROFILE}" >/dev/null 2>&1 || {
    print_info "Function exists, updating code and configuration..."
    aws lambda update-function-code \
      --function-name ecs-caller \
      --zip-file fileb:///tmp/ecs_caller.zip \
      --profile "${TMP_PROFILE}" >/dev/null

    aws lambda update-function-configuration \
      --function-name ecs-caller \
      --environment "Variables={ALB_DNS=${ALB_DNS},APP_NAME=${APP_NAME}}" \
      --vpc-config "SubnetIds=${SUBNET_ID_1},${SUBNET_ID_2},SecurityGroupIds=${SG_ID}" \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  }

print_success "Lambda deployed"
echo

# === Summary ===

print_section "Lambda Deployment Complete"
print_success "Lambda function:    ecs-caller"
print_success "Runtime:            python3.11"
print_success "VPC Config:         ${SUBNET_ID_1}, ${SUBNET_ID_2}"
print_success "Security Group:     ${SG_ID}"
print_success "ALB Endpoint:       http://${ALB_DNS}/${APP_NAME}/"
print_success "Environment:"
print_success "  - ALB_DNS:        ${ALB_DNS}"
print_success "  - APP_NAME:       ${APP_NAME}"
echo

print_info "To invoke:"
print_info "  ./scripts/invoke_lambda.sh"
echo

print_info "Note: First invocation may take 30-60 seconds due to VPC ENI initialization"
echo

rm -f /tmp/ecs_caller.py /tmp/ecs_caller.zip
