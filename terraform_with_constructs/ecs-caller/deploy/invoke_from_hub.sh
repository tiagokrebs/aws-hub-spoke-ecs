#!/usr/bin/env bash
set -euo pipefail

HUB_PROFILE="${1:-hub-me}"
SPOKE_ACCOUNT_ID="445876755019"
REGION="us-west-2"
FUNCTION_NAME="ecs-caller"

echo "Assuming SpokeExecutionRole from ${HUB_PROFILE}..."

read -r AK SK ST < <(aws sts assume-role \
  --role-arn "arn:aws:iam::${SPOKE_ACCOUNT_ID}:role/SpokeExecutionRole" \
  --role-session-name "invoke-lambda-$(date +%s)" \
  --profile "${HUB_PROFILE}" \
  --region "${REGION}" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)

export AWS_ACCESS_KEY_ID="$AK"
export AWS_SECRET_ACCESS_KEY="$SK"
export AWS_SESSION_TOKEN="$ST"
export AWS_DEFAULT_REGION="$REGION"

echo "Invoking ${FUNCTION_NAME}..."

# Wait for Lambda to be Active
for i in {1..30}; do
  STATE=$(aws lambda get-function \
    --function-name "${FUNCTION_NAME}" \
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
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  /tmp/lambda-output.json >/dev/null

cat /tmp/lambda-output.json | python3 -m json.tool
rm -f /tmp/lambda-output.json
