#!/usr/bin/env bash
set -euo pipefail

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
: "${CONTAINER_PORT:?must be set}"

# Per-app parameters
APP_NAME="${APP_NAME:-fastapi-app}"
APP_VERSION="${APP_VERSION:-v1}"

# Validate parameters
if [[ -z "${APP_NAME}" ]]; then
  print_error "APP_NAME not set"
  exit 1
fi
if [[ -z "${APP_VERSION}" ]]; then
  print_error "APP_VERSION not set"
  exit 1
fi

TMP_PROFILE="spoke-from-hub"

print_section "Deploy ECS Application"
print_info "App Name:           ${APP_NAME}"
print_info "App Version:        ${APP_VERSION}"
print_info "Cluster:            ${ECS_CLUSTER_NAME}"
print_info "Container Port:     ${CONTAINER_PORT}"
echo

# Validate prerequisites
validate_prerequisites || exit 1

# === Step 1: Assume SpokeECSRole ===

print_section "Step 1: Assume SpokeECSRole"

if ! aws sts get-caller-identity --profile "${TMP_PROFILE}" >/dev/null 2>&1; then
  print_info "Assuming SpokeECSRole using hub profile ${HUB_PROFILE} ..."
  SPOKE_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/${SPOKE_ROLE_NAME}"
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "${SPOKE_ROLE_ARN}" \
      --role-session-name "hub-to-spoke-deploy-app" \
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

# === Step 2: Discover shared resources ===

print_section "Step 2: Discover Shared Resources"

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

# Get ALB listener ARN
LISTENER_ARN=$(get_alb_listener_arn)
if [[ -z "${LISTENER_ARN}" ]] || [[ "${LISTENER_ARN}" == "None" ]]; then
  print_error "ALB listener not found: ${ALB_NAME}"
  exit 1
fi
print_success "ALB Listener: ${LISTENER_ARN}"

# Get ECR repo URI
ECR_REPO_URI=$(aws ecr describe-repositories \
  --repository-names "${SHARED_ECR_REPO}" \
  --profile "${TMP_PROFILE}" \
  --query 'repositories[0].repositoryUri' --output text)
if [[ -z "${ECR_REPO_URI}" ]]; then
  print_error "ECR repository not found: ${SHARED_ECR_REPO}"
  exit 1
fi
print_success "ECR Repository: ${ECR_REPO_URI}"

# Get task role ARNs
TASK_EXEC_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/ecsTaskExecutionRole"
TASK_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/ecsTaskRole"
print_success "Task Roles: ${TASK_EXEC_ROLE_ARN}"

echo

# === Step 3: Create CloudWatch Log Group ===

print_section "Step 3: Create CloudWatch Log Group"

LOG_GROUP="/ecs/${APP_NAME}"
print_info "Creating log group: ${LOG_GROUP}"

aws logs create-log-group \
  --log-group-name "${LOG_GROUP}" \
  --profile "${TMP_PROFILE}" >/dev/null 2>&1 || print_warning "Log group already exists"

print_success "Log group ready: ${LOG_GROUP}"
echo

# === Step 4: Register Task Definition ===

print_section "Step 4: Register ECS Task Definition"

print_info "Creating task definition: ${APP_NAME}"

# Create task definition JSON
cat > /tmp/task-definition-${APP_NAME}.json <<EOF
{
  "family": "${APP_NAME}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${TASK_EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "${APP_NAME}",
      "image": "${ECR_REPO_URI}:${APP_NAME}-${APP_VERSION}",
      "portMappings": [
        {
          "containerPort": ${CONTAINER_PORT},
          "hostPort": ${CONTAINER_PORT},
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "APP_PREFIX",
          "value": "/${APP_NAME}"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF

aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-definition-${APP_NAME}.json \
  --profile "${TMP_PROFILE}" >/dev/null

print_success "Task definition registered"
rm -f /tmp/task-definition-${APP_NAME}.json
echo

# === Step 5: Create Target Group ===

print_section "Step 5: Create Target Group"

TG_NAME="tg-${APP_NAME}"
print_info "Target Group: ${TG_NAME}"

TG_EXISTS=$(aws elbv2 describe-target-groups \
  --names "${TG_NAME}" \
  --profile "${TMP_PROFILE}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")

if [[ "${TG_EXISTS}" == "None" ]] || [[ -z "${TG_EXISTS}" ]]; then
  print_info "Creating target group..."
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port 80 \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-enabled \
    --health-check-protocol HTTP \
    --health-check-path "/${APP_NAME}/health" \
    --matcher HttpCode=200 \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text \
    --profile "${TMP_PROFILE}")
  print_success "Target group created: ${TG_ARN}"
else
  TG_ARN="${TG_EXISTS}"
  print_success "Target group already exists: ${TG_ARN}"
fi
echo

# === Step 6: Create ALB Listener Rule ===

print_section "Step 6: Create ALB Listener Rule"

print_info "Path pattern: /${APP_NAME}/*"

# Check if rule already exists
RULE_EXISTS=$(aws elbv2 describe-rules \
  --listener-arn "${LISTENER_ARN}" \
  --profile "${TMP_PROFILE}" \
  --query "Rules[?Conditions[0].Values[0]=='/${APP_NAME}/*'].RuleArn" --output text 2>/dev/null || echo "None")

if [[ "${RULE_EXISTS}" == "None" ]] || [[ -z "${RULE_EXISTS}" ]]; then
  print_info "Creating listener rule..."

  # Get current max priority
  MAX_PRIORITY=$(aws elbv2 describe-rules \
    --listener-arn "${LISTENER_ARN}" \
    --profile "${TMP_PROFILE}" \
    --query 'max(Rules[?!IsDefault].Priority)' --output text 2>/dev/null || echo "0")

  # Convert to number and add 10
  if [[ "${MAX_PRIORITY}" == "None" ]] || [[ "${MAX_PRIORITY}" == "null" ]]; then
    PRIORITY=10
  else
    PRIORITY=$((MAX_PRIORITY + 10))
  fi

  aws elbv2 create-rule \
    --listener-arn "${LISTENER_ARN}" \
    --priority "${PRIORITY}" \
    --conditions Field=path-pattern,Values="/${APP_NAME}/*" \
    --actions Type=forward,TargetGroupArn="${TG_ARN}" \
    --profile "${TMP_PROFILE}" >/dev/null

  print_success "Listener rule created (priority: ${PRIORITY})"
else
  print_success "Listener rule already exists"
fi
echo

# === Step 7: Create or Update ECS Service ===

print_section "Step 7: Create or Update ECS Service"

SERVICE_NAME="${APP_NAME}"

# Check if service exists
SERVICE_STATUS=$(aws ecs describe-services \
  --cluster "${ECS_CLUSTER_NAME}" \
  --services "${SERVICE_NAME}" \
  --profile "${TMP_PROFILE}" \
  --query 'services[0].status' --output text 2>/dev/null || echo "None")

if [[ "${SERVICE_STATUS}" == "ACTIVE" ]]; then
  print_info "Service exists, forcing new deployment..."
  aws ecs update-service \
    --cluster "${ECS_CLUSTER_NAME}" \
    --service "${SERVICE_NAME}" \
    --force-new-deployment \
    --profile "${TMP_PROFILE}" >/dev/null
  print_success "Service updated with new deployment"
else
  print_info "Creating new ECS service..."
  aws ecs create-service \
    --cluster "${ECS_CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --task-definition "${APP_NAME}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID_1},${SUBNET_ID_2}],securityGroups=[${SG_ID}],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${APP_NAME},containerPort=${CONTAINER_PORT}" \
    --profile "${TMP_PROFILE}" >/dev/null
  print_success "ECS service created"
fi
echo

# === Step 8: Wait for service to stabilize ===

print_section "Step 8: Wait for Service to Stabilize"

print_info "Waiting for service ${SERVICE_NAME} to stabilize (up to 120s)..."

for i in {1..24}; do
  SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --profile "${TMP_PROFILE}" \
    --query 'services[0].status' --output text 2>/dev/null || echo "None")

  RUNNING_COUNT=$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${SERVICE_NAME}" \
    --profile "${TMP_PROFILE}" \
    --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")

  if [[ "${SERVICE_STATUS}" == "ACTIVE" ]] && [[ "${RUNNING_COUNT}" == "1" ]]; then
    print_success "Service is stable!"
    break
  fi

  print_warning "Service status: ${SERVICE_STATUS}, running count: ${RUNNING_COUNT} (attempt $i/24)"
  sleep 5
done
echo

print_section "ECS Deployment Complete"
print_success "Service Name:       ${SERVICE_NAME}"
print_success "Task Definition:    ${APP_NAME}"
print_success "Target Group:       ${TG_NAME}"
print_success "ALB Path Pattern:   /${APP_NAME}/*"
echo
