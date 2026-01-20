#!/usr/bin/env bash
# Roll a new image into an existing AgentCore Runtime.
#
# Required env vars:
#   AWS_REGION
#   RUNTIME_ID             (the id, not the ARN — output of deploy.sh)
#
# Optional env vars:
#   ECR_REPO_NAME          (default: mcp-demo)
#   IMAGE_TAG              (default: timestamp)
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${RUNTIME_ID:?RUNTIME_ID is required}"

ECR_REPO_NAME="${ECR_REPO_NAME:-mcp-demo}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo ">> Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo ">> Building image ${ECR_REPO_NAME}:${IMAGE_TAG}..."
docker build -t "${ECR_REPO_NAME}:${IMAGE_TAG}" "$PROJECT_DIR"

echo ">> Pushing..."
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo ">> Updating runtime $RUNTIME_ID..."
aws bedrock-agentcore-control update-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" \
  --agent-runtime-artifact "{
    \"containerConfiguration\": {
      \"containerUri\": \"${ECR_URI}:${IMAGE_TAG}\"
    }
  }" \
  --region "$AWS_REGION" > /dev/null

echo "Done. New image: ${ECR_URI}:${IMAGE_TAG}"
