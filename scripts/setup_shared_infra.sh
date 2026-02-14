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
: "${VPC_NAME:?must be set}"
: "${VPC_CIDR:?must be set}"
: "${SUBNET_CIDR_1:?must be set}"
: "${SUBNET_CIDR_2:?must be set}"
: "${SHARED_SG_NAME:?must be set}"
: "${SHARED_ECR_REPO:?must be set}"
: "${ECS_CLUSTER_NAME:?must be set}"
: "${ALB_NAME:?must be set}"

if [[ $DRY_RUN -eq 1 ]]; then
  print_dry_run_header
fi

print_section "Setup Shared Infrastructure"
print_info "Hub account:        ${HUB_ACCOUNT_ID} (profile ${HUB_PROFILE})"
print_info "Spoke account:      ${SPOKE_ACCOUNT_ID}"
print_info "VPC Name:           ${VPC_NAME}"
print_info "ECS Cluster:        ${ECS_CLUSTER_NAME}"
print_info "ALB Name:           ${ALB_NAME}"
echo

# Validate prerequisites
validate_prerequisites || exit 1

# Check AWS profile and credentials
print_section "Validating AWS Configuration"
check_aws_profile "${HUB_PROFILE}" || exit 1
check_aws_credentials "${HUB_PROFILE}" || exit 1
echo

# === Step 1: Assume SpokeECSRole ===

SPOKE_EXECUTION_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/SpokeExecutionRole"
TMP_PROFILE="spoke-from-hub"

print_section "Step 1: Assume SpokeExecutionRole"

if [[ $DRY_RUN -eq 0 ]]; then
  if ! aws sts get-caller-identity --profile "${TMP_PROFILE}" >/dev/null 2>&1; then
    print_info "Assuming SpokeExecutionRole using hub profile ${HUB_PROFILE} ..."
    read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
      aws sts assume-role \
        --role-arn "${SPOKE_EXECUTION_ROLE_ARN}" \
        --role-session-name "hub-to-spoke-shared-infra" \
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

  # Fetch region from profile
  REGION=$(aws configure get region --profile "${TMP_PROFILE}")
  if [[ -z "${REGION}" ]]; then
    print_error "Could not determine region from profile ${TMP_PROFILE}"
    exit 1
  fi
  print_info "Region: ${REGION}"
else
  print_info "[DRY-RUN] Would assume SpokeExecutionRole"
  REGION="us-west-2"  # Placeholder for dry-run
fi
echo

# === Step 2: VPC ===

print_section "Step 2: Create VPC"

VPC_ID=""
if [[ $DRY_RUN -eq 0 ]]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query 'Vpcs[0].VpcId' --output text \
    --profile "${TMP_PROFILE}")

  if [[ "${VPC_ID}" == "None" ]] || [[ -z "${VPC_ID}" ]]; then
    print_info "Creating VPC ${VPC_NAME}..."
    VPC_ID=$(aws ec2 create-vpc \
      --cidr-block "${VPC_CIDR}" \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${VPC_NAME}}]" \
      --query 'Vpc.VpcId' --output text \
      --profile "${TMP_PROFILE}")
    print_success "VPC created: ${VPC_ID}"
  else
    print_success "VPC already exists: ${VPC_ID}"
  fi

  # Enable DNS hostnames and DNS resolution
  aws ec2 modify-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --enable-dns-hostnames \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  aws ec2 modify-vpc-attribute \
    --vpc-id "${VPC_ID}" \
    --enable-dns-support \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  print_info "DNS enabled on VPC"
else
  print_info "[DRY-RUN] Would create VPC ${VPC_NAME}"
  VPC_ID="vpc-12345678"  # Placeholder for dry-run
fi
echo

# === Step 3: Subnets ===

print_section "Step 3: Create Private Subnets"

SUBNET_ID_1=""
SUBNET_ID_2=""

if [[ $DRY_RUN -eq 0 ]]; then
  # Get first 2 available AZs
  AZ_LIST=$(aws ec2 describe-availability-zones \
    --query 'AvailabilityZones[0:2].ZoneName' --output text \
    --profile "${TMP_PROFILE}")
  AZ1=$(echo "$AZ_LIST" | awk '{print $1}')
  AZ2=$(echo "$AZ_LIST" | awk '{print $2}')
  print_info "Using AZs: ${AZ1}, ${AZ2}"

  # Check and create subnets
  SUBNET_ID_1=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${SUBNET_CIDR_1}" \
    --query 'Subnets[0].SubnetId' --output text \
    --profile "${TMP_PROFILE}" 2>/dev/null || echo "None")

  if [[ "${SUBNET_ID_1}" == "None" ]] || [[ -z "${SUBNET_ID_1}" ]]; then
    print_info "Creating subnet 1 (${SUBNET_CIDR_1}) in ${AZ1}..."
    SUBNET_ID_1=$(aws ec2 create-subnet \
      --vpc-id "${VPC_ID}" \
      --cidr-block "${SUBNET_CIDR_1}" \
      --availability-zone "${AZ1}" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-private-1},{Key=Type,Value=private}]" \
      --query 'Subnet.SubnetId' --output text \
      --profile "${TMP_PROFILE}")
    print_success "Subnet 1 created: ${SUBNET_ID_1}"
  else
    print_success "Subnet 1 already exists: ${SUBNET_ID_1}"
  fi

  SUBNET_ID_2=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${SUBNET_CIDR_2}" \
    --query 'Subnets[0].SubnetId' --output text \
    --profile "${TMP_PROFILE}" 2>/dev/null || echo "None")

  if [[ "${SUBNET_ID_2}" == "None" ]] || [[ -z "${SUBNET_ID_2}" ]]; then
    print_info "Creating subnet 2 (${SUBNET_CIDR_2}) in ${AZ2}..."
    SUBNET_ID_2=$(aws ec2 create-subnet \
      --vpc-id "${VPC_ID}" \
      --cidr-block "${SUBNET_CIDR_2}" \
      --availability-zone "${AZ2}" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${VPC_NAME}-private-2},{Key=Type,Value=private}]" \
      --query 'Subnet.SubnetId' --output text \
      --profile "${TMP_PROFILE}")
    print_success "Subnet 2 created: ${SUBNET_ID_2}"
  else
    print_success "Subnet 2 already exists: ${SUBNET_ID_2}"
  fi
else
  print_info "[DRY-RUN] Would create 2 private subnets"
  SUBNET_ID_1="subnet-12345678"
  SUBNET_ID_2="subnet-87654321"
fi
echo

# === Step 4: Shared Security Group ===

print_section "Step 4: Create Shared Security Group"

SG_ID=""
if [[ $DRY_RUN -eq 0 ]]; then
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SHARED_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text \
    --profile "${TMP_PROFILE}" 2>/dev/null || echo "None")

  if [[ "${SG_ID}" == "None" ]] || [[ -z "${SG_ID}" ]]; then
    print_info "Creating security group ${SHARED_SG_NAME}..."
    SG_ID=$(aws ec2 create-security-group \
      --group-name "${SHARED_SG_NAME}" \
      --description "Hub-Spoke shared security group" \
      --vpc-id "${VPC_ID}" \
      --query 'GroupId' --output text \
      --profile "${TMP_PROFILE}")
    print_success "Security group created: ${SG_ID}"
  else
    print_success "Security group already exists: ${SG_ID}"
  fi

  # Add ingress rules (always, for both new and existing SGs)
  print_info "Adding ingress rules..."
  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp \
    --port 80 \
    --cidr "${VPC_CIDR}" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp \
    --port 443 \
    --cidr "${VPC_CIDR}" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  print_success "Ingress rules added"
else
  print_info "[DRY-RUN] Would create shared security group"
  SG_ID="sg-12345678"
fi
echo

# === Step 5: Shared ECR Repository ===

print_section "Step 5: Create Shared ECR Repository"

if [[ $DRY_RUN -eq 0 ]]; then
  REPO_EXISTS=$(aws ecr describe-repositories \
    --repository-names "${SHARED_ECR_REPO}" \
    --profile "${TMP_PROFILE}" \
    --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "None")

  if [[ "${REPO_EXISTS}" == "None" ]] || [[ -z "${REPO_EXISTS}" ]]; then
    print_info "Creating ECR repository ${SHARED_ECR_REPO}..."
    aws ecr create-repository \
      --repository-name "${SHARED_ECR_REPO}" \
      --profile "${TMP_PROFILE}" >/dev/null
    print_success "ECR repository created"
  else
    print_success "ECR repository already exists: ${REPO_EXISTS}"
  fi
else
  print_info "[DRY-RUN] Would create ECR repository ${SHARED_ECR_REPO}"
fi
echo

# === Step 6: ECS Cluster ===

print_section "Step 6: Create ECS Cluster"

if [[ $DRY_RUN -eq 0 ]]; then
  CLUSTER_STATUS=$(aws ecs describe-clusters \
    --clusters "${ECS_CLUSTER_NAME}" \
    --profile "${TMP_PROFILE}" \
    --query 'clusters[0].status' --output text 2>/dev/null || echo "None")

  if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
    print_info "Creating ECS cluster ${ECS_CLUSTER_NAME}..."
    aws ecs create-cluster \
      --cluster-name "${ECS_CLUSTER_NAME}" \
      --capacity-providers FARGATE FARGATE_SPOT \
      --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1,base=1 \
      --profile "${TMP_PROFILE}" >/dev/null
    print_success "ECS cluster created"
  else
    print_success "ECS cluster already exists"
  fi
else
  print_info "[DRY-RUN] Would create ECS cluster ${ECS_CLUSTER_NAME}"
fi
echo

# === Step 7: VPC Endpoints ===

print_section "Step 7: Create VPC Endpoints"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Creating VPC endpoints (errors ignored if already exist)..."

  # Get main route table
  ROUTE_TABLE=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text \
    --profile "${TMP_PROFILE}")

  # ECR API endpoint
  aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.${REGION}.ecr.api" \
    --subnet-ids "${SUBNET_ID_1}" "${SUBNET_ID_2}" \
    --security-group-ids "${SG_ID}" \
    --private-dns-enabled \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || print_warning "ECR API endpoint already exists or error"

  # ECR DKR endpoint
  aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.${REGION}.ecr.dkr" \
    --subnet-ids "${SUBNET_ID_1}" "${SUBNET_ID_2}" \
    --security-group-ids "${SG_ID}" \
    --private-dns-enabled \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || print_warning "ECR DKR endpoint already exists or error"

  # Logs endpoint
  aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.${REGION}.logs" \
    --subnet-ids "${SUBNET_ID_1}" "${SUBNET_ID_2}" \
    --security-group-ids "${SG_ID}" \
    --private-dns-enabled \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || print_warning "Logs endpoint already exists or error"

  # S3 endpoint (Gateway)
  aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Gateway \
    --service-name "com.amazonaws.${REGION}.s3" \
    --route-table-ids "${ROUTE_TABLE}" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || print_warning "S3 endpoint already exists or error"

  print_success "VPC endpoints configured"
  print_info "Waiting for endpoints to initialize..."
  sleep 30
else
  print_info "[DRY-RUN] Would create VPC endpoints"
fi
echo

# === Step 8: Internal ALB ===

print_section "Step 8: Create Internal Application Load Balancer"

if [[ $DRY_RUN -eq 0 ]]; then
  ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --profile "${TMP_PROFILE}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

  if [[ "${ALB_ARN}" == "None" ]] || [[ -z "${ALB_ARN}" ]]; then
    print_info "Creating internal ALB ${ALB_NAME}..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
      --name "${ALB_NAME}" \
      --subnets "${SUBNET_ID_1}" "${SUBNET_ID_2}" \
      --security-groups "${SG_ID}" \
      --scheme internal \
      --type application \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text \
      --profile "${TMP_PROFILE}")
    print_success "ALB created: ${ALB_ARN}"
  else
    print_success "ALB already exists: ${ALB_ARN}"
  fi

  # Create HTTP:80 listener with default 503 response
  LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}" \
    --profile "${TMP_PROFILE}" \
    --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || echo "None")

  if [[ "${LISTENER_ARN}" == "None" ]] || [[ -z "${LISTENER_ARN}" ]]; then
    print_info "Creating HTTP:80 listener..."
    aws elbv2 create-listener \
      --load-balancer-arn "${ALB_ARN}" \
      --protocol HTTP \
      --port 80 \
      --default-actions Type=fixed-response,FixedResponseConfig="{StatusCode=503,ContentType=text/plain}" \
      --profile "${TMP_PROFILE}" >/dev/null
    print_success "Listener created"
  else
    print_success "HTTP:80 listener already exists"
  fi
else
  print_info "[DRY-RUN] Would create internal ALB ${ALB_NAME}"
fi
echo

# === Summary ===

print_section "Shared Infrastructure Setup Complete"
print_success "VPC:                ${VPC_ID} (${VPC_CIDR})"
print_success "Subnets:            ${SUBNET_ID_1}, ${SUBNET_ID_2}"
print_success "Security Group:     ${SG_ID} (${SHARED_SG_NAME})"
print_success "ECR Repository:     ${SHARED_ECR_REPO}"
print_success "ECS Cluster:        ${ECS_CLUSTER_NAME}"
print_success "ALB:                ${ALB_NAME}"
print_success "VPC Endpoints:      ECR API, ECR DKR, CloudWatch Logs, S3"
echo

if [[ $DRY_RUN -eq 1 ]]; then
  print_warning "DRY-RUN COMPLETE: No changes were made. Run without --dry-run to execute."
fi
echo
