#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Hub-Spoke Infrastructure Setup"
echo "=========================================="
echo ""

echo "Step 1: Setup IAM Roles"
"${SCRIPT_DIR}/setup_roles.sh" || exit 1
echo ""

echo "Step 2: Setup Shared Infrastructure (VPC, Subnets, VPC Endpoints, ECS Cluster, ALB)"
"${SCRIPT_DIR}/setup_shared_infra.sh" || exit 1
echo ""

echo "=========================================="
echo "Infrastructure Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Build and push image: APP_NAME=fastapi-app APP_VERSION=v1 ./scripts/build_push_app.sh"
echo "  2. Deploy application: APP_NAME=fastapi-app APP_VERSION=v1 ./scripts/deploy_app_ecs.sh"
echo "  3. Deploy Lambda caller: APP_NAME=fastapi-app ./scripts/deploy_lambda.sh"
echo "  4. Test: ./scripts/invoke_lambda.sh"
echo ""
