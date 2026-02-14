#!/usr/bin/env bash
# Shared helper functions for hub-spoke scripts

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running in dry-run mode
DRY_RUN=${DRY_RUN:-0}

# Print with color
print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_section() {
  echo -e "\n${BLUE}===${NC} $1 ${BLUE}===${NC}\n"
}

# Check if command exists
check_command() {
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    print_error "Command not found: $cmd"
    return 1
  fi
  print_success "Command found: $cmd"
  return 0
}

# Check if AWS CLI profile exists
check_aws_profile() {
  local profile=$1
  if ! aws configure get aws_access_key_id --profile "$profile" >/dev/null 2>&1; then
    print_error "AWS profile not found: $profile"
    return 1
  fi
  print_success "AWS profile exists: $profile"
  return 0
}

# Check if AWS credentials are valid
check_aws_credentials() {
  local profile=$1
  if ! aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
    print_error "AWS credentials invalid for profile: $profile"
    return 1
  fi
  local account=$(aws sts get-caller-identity --profile "$profile" --query Account --output text 2>/dev/null)
  print_success "AWS credentials valid for profile: $profile (Account: $account)"
  return 0
}

# Check if Docker daemon is running
check_docker() {
  if ! docker ps >/dev/null 2>&1; then
    print_error "Docker daemon not running"
    return 1
  fi
  print_success "Docker daemon is running"
  return 0
}

# Check if .env file exists
check_env_file() {
  if [[ ! -f .env ]]; then
    print_error ".env file not found"
    return 1
  fi
  print_success ".env file exists"
  return 0
}

# Check if all required environment variables are set
check_env_vars() {
  local vars=("$@")
  local missing=()

  for var in "${vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    for var in "${missing[@]}"; do
      print_error "Environment variable not set: $var"
    done
    return 1
  fi

  print_success "All required environment variables are set"
  return 0
}

# Check AWS IAM role exists
check_iam_role() {
  local role_name=$1
  local profile=$2
  local region=${3:-us-west-2}

  if ! aws iam get-role --role-name "$role_name" --profile "$profile" --region "$region" >/dev/null 2>&1; then
    print_error "IAM role not found: $role_name"
    return 1
  fi
  print_success "IAM role exists: $role_name"
  return 0
}

# Check if ECR repository exists
check_ecr_repo() {
  local repo_name=$1
  local profile=$2
  local region=$3

  if ! aws ecr describe-repositories --repository-names "$repo_name" --profile "$profile" --region "$region" >/dev/null 2>&1; then
    print_warning "ECR repository does not exist: $repo_name (will be created)"
    return 1
  fi
  print_success "ECR repository exists: $repo_name"
  return 0
}

# Dry-run mode: print what would be executed
execute_or_dry_run() {
  local description=$1
  shift
  local cmd=("$@")

  if [[ $DRY_RUN -eq 1 ]]; then
    print_info "[DRY-RUN] $description"
    echo "  Command: ${cmd[*]}"
    return 0
  else
    print_info "$description"
    "${cmd[@]}"
  fi
}

# Print dry-run header
print_dry_run_header() {
  echo -e "${YELLOW}╔════════════════════════════════════════${NC}"
  echo -e "${YELLOW}║${NC} DRY-RUN MODE - No changes will be made"
  echo -e "${YELLOW}╚════════════════════════════════════════${NC}"
  echo
}

# Validate all prerequisites
validate_prerequisites() {
  local all_checks_passed=true

  print_section "Checking Prerequisites"

  # Check AWS CLI
  if ! check_command "aws"; then
    all_checks_passed=false
  fi

  # Check jq
  if ! check_command "jq"; then
    all_checks_passed=false
  fi

  echo
  return $([ "$all_checks_passed" = true ] && echo 0 || echo 1)
}

# === VPC/ALB/SG Discovery Helpers ===
# Assumes TMP_PROFILE is set (no --region; profile default is used)

get_vpc_id() {
  aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query 'Vpcs[0].VpcId' --output text \
    --profile "${TMP_PROFILE}"
}

get_private_subnet_ids() {
  local vpc_id=$1
  aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Type,Values=private" \
    --query 'Subnets[*].SubnetId' --output text \
    --profile "${TMP_PROFILE}"
}

get_shared_sg_id() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SHARED_SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text \
    --profile "${TMP_PROFILE}"
}

get_alb_arn() {
  aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text \
    --profile "${TMP_PROFILE}"
}

get_alb_listener_arn() {
  local alb_arn
  alb_arn=$(get_alb_arn)
  aws elbv2 describe-listeners \
    --load-balancer-arn "${alb_arn}" \
    --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text \
    --profile "${TMP_PROFILE}"
}

get_alb_dns() {
  aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --query 'LoadBalancers[0].DNSName' --output text \
    --profile "${TMP_PROFILE}"
}
