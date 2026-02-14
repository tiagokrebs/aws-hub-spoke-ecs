#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-app parameters (allow override from environment)
APP_NAME="${APP_NAME:-fastapi-app}"
APP_VERSION="${APP_VERSION:-v1}"

echo "=========================================="
echo "Hub-Spoke ECS Deployment"
echo "=========================================="
echo "App Name:    ${APP_NAME}"
echo "App Version: ${APP_VERSION}"
echo "=========================================="
echo ""

echo "Step 1: Build and Push Docker Image"
APP_NAME="${APP_NAME}" APP_VERSION="${APP_VERSION}" \
  "${SCRIPT_DIR}/build_push_app.sh" || exit 1
echo ""

echo "Step 2: Deploy ECS Application"
APP_NAME="${APP_NAME}" APP_VERSION="${APP_VERSION}" \
  "${SCRIPT_DIR}/deploy_app_ecs.sh" || exit 1
echo ""

echo "Step 3: Deploy Lambda Function"
APP_NAME="${APP_NAME}" \
  "${SCRIPT_DIR}/deploy_lambda.sh" || exit 1
echo ""

echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "To test the application:"
echo "  ./scripts/invoke_lambda.sh"
echo ""
