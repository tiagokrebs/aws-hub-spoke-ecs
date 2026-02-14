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

TMP_PROFILE="spoke-from-hub"

print_section "Invoke Lambda to Test ECS App"
echo

# Wait for Lambda function to be ready
print_info "Waiting for Lambda function to be ready..."
for i in {1..30}; do
  STATE=$(aws lambda get-function \
    --function-name ecs-caller \
    --profile "${TMP_PROFILE}" \
    --query 'Configuration.State' --output text 2>/dev/null || echo "Unknown")

  if [[ "${STATE}" == "Active" ]]; then
    print_success "Lambda function is ready"
    break
  fi

  if [[ $i -eq 30 ]]; then
    print_error "Lambda function failed to reach Active state"
    exit 1
  fi

  print_warning "Function state: ${STATE} (attempt $i/30)"
  sleep 2
done
echo

print_info "Invoking Lambda function..."
if aws lambda invoke \
  --function-name ecs-caller \
  --profile "${TMP_PROFILE}" \
  /tmp/response.json >/dev/null 2>&1; then
  echo
  print_section "Response from ECS App"
  cat /tmp/response.json | jq .
  echo
  print_success "Lambda invocation successful!"
else
  print_error "Lambda invocation failed"
  cat /tmp/response.json 2>/dev/null || true
  exit 1
fi

rm -f /tmp/response.json
