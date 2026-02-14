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
: "${SHARED_ECR_REPO:?must be set}"

# Per-app parameters (from environment or defaults from .env)
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

print_section "Build and Push Application Image"
print_info "App Name:           ${APP_NAME}"
print_info "App Version:        ${APP_VERSION}"
print_info "Image Tag:          ${SHARED_ECR_REPO}:${APP_NAME}-${APP_VERSION}"
echo

# Validate prerequisites
validate_prerequisites || exit 1

print_section "Step 1: Assume SpokeECSRole"

if ! aws sts get-caller-identity --profile "${TMP_PROFILE}" >/dev/null 2>&1; then
  print_info "Assuming SpokeECSRole using hub profile ${HUB_PROFILE} ..."
  SPOKE_ROLE_ARN="arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/${SPOKE_ROLE_NAME}"
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "${SPOKE_ROLE_ARN}" \
      --role-session-name "hub-to-spoke-build" \
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

# === Step 2: Get ECR repo URI ===

print_section "Step 2: Get ECR Repository URI"

ECR_REPO_URI=$(aws ecr describe-repositories \
  --repository-names "${SHARED_ECR_REPO}" \
  --profile "${TMP_PROFILE}" \
  --query 'repositories[0].repositoryUri' --output text)

if [[ -z "${ECR_REPO_URI}" ]] || [[ "${ECR_REPO_URI}" == "None" ]]; then
  print_error "ECR repository not found: ${SHARED_ECR_REPO}"
  exit 1
fi

print_success "ECR Repository: ${ECR_REPO_URI}"
echo

# === Step 3: Docker login to ECR ===

print_section "Step 3: Docker Login to ECR"

print_info "Logging in to ECR..."
aws ecr get-login-password \
  --profile "${TMP_PROFILE}" | \
  docker login --username AWS --password-stdin "${ECR_REPO_URI}" >/dev/null 2>&1

print_success "Docker login successful"
echo

# === Step 4: Build image ===

print_section "Step 4: Build Docker Image"

IMAGE_NAME="${SHARED_ECR_REPO}:${APP_NAME}-${APP_VERSION}"
print_info "Building image: ${IMAGE_NAME}"

docker build \
  --platform linux/amd64 \
  -t "${IMAGE_NAME}" \
  -f app/Dockerfile \
  . || exit 1

print_success "Image built successfully"
echo

# === Step 5: Tag for ECR ===

print_section "Step 5: Tag Image for ECR"

ECR_IMAGE_URI="${ECR_REPO_URI}:${APP_NAME}-${APP_VERSION}"
print_info "Tagging as: ${ECR_IMAGE_URI}"

docker tag "${IMAGE_NAME}" "${ECR_IMAGE_URI}"

print_success "Image tagged"
echo

# === Step 6: Push to ECR ===

print_section "Step 6: Push Image to ECR"

print_info "Pushing image to ECR..."
docker push "${ECR_IMAGE_URI}" || exit 1

print_success "Image pushed successfully"
echo

print_section "Build and Push Complete"
print_success "Image available at: ${ECR_IMAGE_URI}"
echo
