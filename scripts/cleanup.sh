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
: "${SHARED_SG_NAME:?must be set}"
: "${SHARED_ECR_REPO:?must be set}"
: "${ECS_CLUSTER_NAME:?must be set}"
: "${ALB_NAME:?must be set}"

TMP_PROFILE="spoke-from-hub"

if [[ $DRY_RUN -eq 1 ]]; then
  print_dry_run_header
fi

print_section "Cleanup Configuration"
print_warning "This will delete all hub-spoke ECS resources"
print_info "Hub account:    ${HUB_ACCOUNT_ID}"
print_info "Spoke account:  ${SPOKE_ACCOUNT_ID}"
print_info "VPC:            ${VPC_NAME}"
print_info "Cluster:        ${ECS_CLUSTER_NAME}"
echo

if [[ $DRY_RUN -eq 0 ]]; then
  read -p "Are you sure? (type 'yes' to confirm): " confirmation
  if [[ "${confirmation}" != "yes" ]]; then
    print_warning "Cleanup cancelled"
    exit 0
  fi
else
  print_info "DRY-RUN: Skipping confirmation prompt"
fi
echo

# Validate prerequisites
validate_prerequisites || exit 1

# Check AWS profile and credentials
print_section "Validating AWS Configuration"
check_aws_profile "${HUB_PROFILE}" || exit 1
check_aws_credentials "${HUB_PROFILE}" || exit 1
echo

# === Step 1: Assume spoke role ===

print_section "Step 1: Assume SpokeECSRole"

if [[ $DRY_RUN -eq 0 ]]; then
  if ! aws sts get-caller-identity --profile "${TMP_PROFILE}" >/dev/null 2>&1; then
    print_info "Assuming spoke role ${SPOKE_ROLE_NAME}..."
    SPOKE_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/${SPOKE_ROLE_NAME}"
    read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
      aws sts assume-role \
        --role-arn "${SPOKE_ROLE_ARN}" \
        --role-session-name "hub-to-spoke-ecs-cleanup" \
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

  # Fetch region
  REGION=$(aws configure get region --profile "${TMP_PROFILE}")
else
  print_info "[DRY-RUN] Would assume SpokeECSRole"
  REGION="us-west-2"  # Placeholder for dry-run
fi
echo

# === Step 2: Delete ECS services ===

print_section "Step 2: Delete ECS Services"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Finding ECS services in cluster ${ECS_CLUSTER_NAME}..."
  SERVICE_ARNS=$(aws ecs list-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --profile "${TMP_PROFILE}" \
    --query 'serviceArns[*]' --output text 2>/dev/null || echo "")

  if [[ -n "${SERVICE_ARNS}" ]]; then
    for service_arn in ${SERVICE_ARNS}; do
      SERVICE_NAME=$(echo "${service_arn}" | awk -F'/' '{print $NF}')
      print_info "Deleting service ${SERVICE_NAME}..."
      aws ecs delete-service \
        --cluster "${ECS_CLUSTER_NAME}" \
        --service "${service_arn}" \
        --force \
        --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
    done
    print_success "ECS services deleted"
  else
    print_warning "No ECS services found"
  fi
else
  print_info "[DRY-RUN] Would delete all ECS services in cluster ${ECS_CLUSTER_NAME}"
fi
echo

# === Step 3: Delete Lambda function ===

print_section "Step 3: Delete Lambda Function"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Deleting Lambda function: ecs-caller"
  aws lambda delete-function \
    --function-name ecs-caller \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  print_success "Lambda function deleted"

  print_info "Deleting Lambda IAM role..."
  aws iam detach-role-policy \
    --role-name ecs-caller-lambda-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  aws iam delete-role \
    --role-name ecs-caller-lambda-role \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  print_success "Lambda IAM role deleted"
else
  print_info "[DRY-RUN] Would delete Lambda function 'ecs-caller' and its IAM role"
fi
echo

# === Step 4: Delete ALB listener rules and target groups ===

print_section "Step 4: Delete ALB Listener Rules and Target Groups"

if [[ $DRY_RUN -eq 0 ]]; then
  # Get ALB ARN
  ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --profile "${TMP_PROFILE}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

  if [[ "${ALB_ARN}" != "None" ]] && [[ -n "${ALB_ARN}" ]]; then
    # Delete listener rules
    print_info "Finding ALB listener rules..."
    LISTENER_ARNS=$(aws elbv2 describe-listeners \
      --load-balancer-arn "${ALB_ARN}" \
      --profile "${TMP_PROFILE}" \
      --query 'Listeners[*].ListenerArn' --output text 2>/dev/null || echo "")

    if [[ -n "${LISTENER_ARNS}" ]]; then
      for listener_arn in ${LISTENER_ARNS}; do
        RULE_ARNS=$(aws elbv2 describe-rules \
          --listener-arn "${listener_arn}" \
          --profile "${TMP_PROFILE}" \
          --query 'Rules[?!IsDefault].RuleArn' --output text 2>/dev/null || echo "")

        for rule_arn in ${RULE_ARNS}; do
          print_info "Deleting listener rule ${rule_arn}..."
          aws elbv2 delete-rule \
            --rule-arn "${rule_arn}" \
            --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
        done
      done
    fi

    # Delete target groups
    print_info "Finding target groups..."
    TG_ARNS=$(aws elbv2 describe-target-groups \
      --profile "${TMP_PROFILE}" \
      --query "TargetGroups[?starts_with(TargetGroupName, 'tg-')].TargetGroupArn" --output text 2>/dev/null || echo "")

    if [[ -n "${TG_ARNS}" ]]; then
      for tg_arn in ${TG_ARNS}; do
        print_info "Deleting target group ${tg_arn}..."
        aws elbv2 delete-target-group \
          --target-group-arn "${tg_arn}" \
          --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
      done
    fi

    # Delete listener
    print_info "Deleting ALB listener..."
    if [[ -n "${LISTENER_ARNS}" ]]; then
      for listener_arn in ${LISTENER_ARNS}; do
        aws elbv2 delete-listener \
          --listener-arn "${listener_arn}" \
          --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
      done
    fi

    # Delete ALB
    print_info "Deleting ALB..."
    aws elbv2 delete-load-balancer \
      --load-balancer-arn "${ALB_ARN}" \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

    print_success "ALB resources deleted"
  else
    print_warning "ALB not found"
  fi
else
  print_info "[DRY-RUN] Would delete ALB, listener rules, and target groups"
fi
echo

# === Step 5: Delete VPC endpoints ===

print_section "Step 5: Delete VPC Endpoints"

if [[ $DRY_RUN -eq 0 ]]; then
  # Get VPC ID
  VPC_ID=$(get_vpc_id)

  if [[ -n "${VPC_ID}" ]] && [[ "${VPC_ID}" != "None" ]]; then
    print_info "Finding VPC endpoints in VPC ${VPC_ID}..."
    ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --profile "${TMP_PROFILE}" \
      --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null || echo "")

    if [[ -n "${ENDPOINT_IDS}" ]]; then
      for endpoint_id in ${ENDPOINT_IDS}; do
        print_info "Deleting VPC endpoint ${endpoint_id}..."
        aws ec2 delete-vpc-endpoints \
          --vpc-endpoint-ids "${endpoint_id}" \
          --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
      done
      print_success "VPC endpoints deleted"
    else
      print_warning "No VPC endpoints found"
    fi
  else
    print_warning "VPC not found"
  fi
else
  print_info "[DRY-RUN] Would delete VPC endpoints"
fi
echo

# === Step 6: Delete shared security group ===

print_section "Step 6: Delete Shared Security Group"

if [[ $DRY_RUN -eq 0 ]]; then
  SG_ID=$(get_shared_sg_id)

  if [[ -n "${SG_ID}" ]] && [[ "${SG_ID}" != "None" ]]; then
    print_info "Waiting for ENIs to detach..."
    sleep 30

    print_info "Deleting security group ${SG_ID}..."
    aws ec2 delete-security-group \
      --group-id "${SG_ID}" \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1 || print_warning "Could not delete security group (may still be in use)"
    print_success "Security group deleted"
  else
    print_warning "Security group not found"
  fi
else
  print_info "[DRY-RUN] Would delete shared security group ${SHARED_SG_NAME}"
fi
echo

# === Step 7: Delete ECS cluster ===

print_section "Step 7: Delete ECS Cluster"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Deleting ECS cluster ${ECS_CLUSTER_NAME}..."
  aws ecs delete-cluster \
    --cluster "${ECS_CLUSTER_NAME}" \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  print_success "ECS cluster deleted"
else
  print_info "[DRY-RUN] Would delete ECS cluster ${ECS_CLUSTER_NAME}"
fi
echo

# === Step 8: Delete CloudWatch log groups ===

print_section "Step 8: Delete CloudWatch Log Groups"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Finding log groups for /ecs/*..."
  LOG_GROUPS=$(aws logs describe-log-groups \
    --log-group-name-prefix "/ecs/" \
    --profile "${TMP_PROFILE}" \
    --query 'logGroups[*].logGroupName' --output text 2>/dev/null || echo "")

  if [[ -n "${LOG_GROUPS}" ]]; then
    for log_group in ${LOG_GROUPS}; do
      print_info "Deleting log group ${log_group}..."
      aws logs delete-log-group \
        --log-group-name "${log_group}" \
        --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
    done
    print_success "Log groups deleted"
  else
    print_warning "No log groups found"
  fi
else
  print_info "[DRY-RUN] Would delete CloudWatch log groups /ecs/*"
fi
echo

# === Step 9: Delete task definitions ===

print_section "Step 9: Delete Task Definitions"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Finding task definitions..."
  TASK_DEFS=$(aws ecs list-task-definitions \
    --profile "${TMP_PROFILE}" \
    --query 'taskDefinitionArns[*]' --output text 2>/dev/null || echo "")

  if [[ -n "${TASK_DEFS}" ]]; then
    for task_def in ${TASK_DEFS}; do
      print_info "Deregistering task definition ${task_def}..."
      aws ecs deregister-task-definition \
        --task-definition "${task_def}" \
        --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
    done
    print_success "Task definitions deregistered"
  else
    print_warning "No task definitions found"
  fi
else
  print_info "[DRY-RUN] Would deregister task definitions"
fi
echo

# === Step 10: Delete ECR repository ===

print_section "Step 10: Delete ECR Repository"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Deleting ECR repository ${SHARED_ECR_REPO}..."
  aws ecr delete-repository \
    --repository-name "${SHARED_ECR_REPO}" \
    --force \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
  print_success "ECR repository deleted"
else
  print_info "[DRY-RUN] Would delete ECR repository ${SHARED_ECR_REPO}"
fi
echo

# === Step 11: Delete subnets ===

print_section "Step 11: Delete Subnets"

if [[ $DRY_RUN -eq 0 ]]; then
  VPC_ID=$(get_vpc_id)

  if [[ -n "${VPC_ID}" ]] && [[ "${VPC_ID}" != "None" ]]; then
    SUBNET_IDS=$(get_private_subnet_ids "${VPC_ID}")

    if [[ -n "${SUBNET_IDS}" ]]; then
      for subnet_id in ${SUBNET_IDS}; do
        print_info "Deleting subnet ${subnet_id}..."
        aws ec2 delete-subnet \
          --subnet-id "${subnet_id}" \
          --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
      done
      print_success "Subnets deleted"
    else
      print_warning "No subnets found"
    fi
  else
    print_warning "VPC not found"
  fi
else
  print_info "[DRY-RUN] Would delete private subnets"
fi
echo

# === Step 12: Delete VPC ===

print_section "Step 12: Delete VPC"

if [[ $DRY_RUN -eq 0 ]]; then
  VPC_ID=$(get_vpc_id)

  if [[ -n "${VPC_ID}" ]] && [[ "${VPC_ID}" != "None" ]]; then
    print_info "Deleting VPC ${VPC_ID}..."
    aws ec2 delete-vpc \
      --vpc-id "${VPC_ID}" \
      --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true
    print_success "VPC deleted"
  else
    print_warning "VPC not found"
  fi
else
  print_info "[DRY-RUN] Would delete VPC ${VPC_NAME}"
fi
echo

# === Step 13: Delete IAM roles ===

print_section "Step 13: Delete IAM Roles"

if [[ $DRY_RUN -eq 0 ]]; then
  print_info "Deleting spoke account roles..."

  # Delete SpokeECSRole
  aws iam delete-role-policy \
    --role-name SpokeECSRole \
    --policy-name SpokECSManagementPolicy \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  aws iam delete-role \
    --role-name SpokeECSRole \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  # Delete ecsTaskExecutionRole
  aws iam detach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  aws iam delete-role \
    --role-name ecsTaskExecutionRole \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  # Delete ecsTaskRole
  aws iam delete-role \
    --role-name ecsTaskRole \
    --profile "${TMP_PROFILE}" >/dev/null 2>&1 || true

  print_success "Spoke account roles deleted"

  print_info "Deleting hub account role..."

  # Delete HubECSRole
  aws iam delete-role-policy \
    --role-name HubECSRole \
    --policy-name AssumeSpokECSRole \
    --profile "${HUB_PROFILE}" >/dev/null 2>&1 || true

  aws iam delete-role \
    --role-name HubECSRole \
    --profile "${HUB_PROFILE}" >/dev/null 2>&1 || true

  print_success "Hub account role deleted"
else
  print_info "[DRY-RUN] Would delete all IAM roles"
fi
echo

# === Summary ===

print_section "Cleanup Summary"
print_success "All resources deleted!"
echo
print_info "Deleted resources:"
print_info "  ✓ ECS Services"
print_info "  ✓ Lambda Function"
print_info "  ✓ ALB, Listener Rules, Target Groups"
print_info "  ✓ VPC Endpoints"
print_info "  ✓ Shared Security Group"
print_info "  ✓ ECS Cluster"
print_info "  ✓ CloudWatch Logs"
print_info "  ✓ Task Definitions"
print_info "  ✓ ECR Repository"
print_info "  ✓ Subnets"
print_info "  ✓ VPC"
print_info "  ✓ IAM Roles"
echo

if [[ $DRY_RUN -eq 1 ]]; then
  print_warning "DRY-RUN COMPLETE: No changes were made. Run without --dry-run to execute."
fi
echo
