#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-spoke-me}"
REGION="us-west-2"
FUNCTION_NAME="ecs-caller"

echo "Invoking ${FUNCTION_NAME} using profile ${PROFILE}..."

# Wait for Lambda to be Active
for i in {1..30}; do
  STATE=$(aws lambda get-function \
    --function-name "${FUNCTION_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query 'Configuration.State' --output text 2>/dev/null || echo "Unknown")

  if [[ "${STATE}" == "Active" ]]; then
    echo "Lambda is Active"
    break
  fi

  if [[ $i -eq 30 ]]; then
    echo "ERROR: Lambda failed to reach Active state (last state: ${STATE})"
    exit 1
  fi

  echo "Waiting... state: ${STATE} (attempt $i/30)"
  sleep 2
done

aws lambda invoke \
  --function-name "${FUNCTION_NAME}" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  /tmp/lambda-output.json >/dev/null

cat /tmp/lambda-output.json | python3 -m json.tool
rm -f /tmp/lambda-output.json
