#!/usr/bin/env bash
# Build the container image, push to ECR, and create an AgentCore Runtime
# with a Cognito JWT authorizer and the Authorization header allowlisted.
#
# Required env vars:
#   AWS_REGION             (e.g. us-east-1)
#   AGENTCORE_ROLE_ARN     (output of setup_iam.sh)
#   DISCOVERY_URL          (output of setup_cognito.sh)
#   CLIENT_ID              (output of setup_cognito.sh)
#
# Optional env vars:
#   ECR_REPO_NAME          (default: mcp-demo)
#   IMAGE_TAG              (default: v1)
#   RUNTIME_NAME           (default: mcp_demo)
#
# Prints the runtime ARN on success.
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${AGENTCORE_ROLE_ARN:?AGENTCORE_ROLE_ARN is required}"
: "${DISCOVERY_URL:?DISCOVERY_URL is required}"
: "${CLIENT_ID:?CLIENT_ID is required}"

ECR_REPO_NAME="${ECR_REPO_NAME:-mcp-demo}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
RUNTIME_NAME="${RUNTIME_NAME:-mcp_demo}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo ">> Ensuring ECR repo '$ECR_REPO_NAME' exists..."
aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" > /dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" > /dev/null

echo ">> Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo ">> Building image..."
docker build -t "${ECR_REPO_NAME}:${IMAGE_TAG}" "$PROJECT_DIR"

echo ">> Pushing image to ECR..."
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

echo ">> Creating AgentCore Runtime '$RUNTIME_NAME'..."
RESPONSE=$(aws bedrock-agentcore-control create-agent-runtime \
  --agent-runtime-name "$RUNTIME_NAME" \
  --role-arn "$AGENTCORE_ROLE_ARN" \
  --network-configuration '{"networkMode":"PUBLIC"}' \
  --protocol-configuration '{"serverProtocol":"MCP"}' \
  --authorizer-configuration "{
    \"customJWTAuthorizer\": {
      \"discoveryUrl\": \"${DISCOVERY_URL}\",
      \"allowedAudience\": [\"${CLIENT_ID}\"]
    }
  }" \
  --request-header-configuration '{"requestHeaderAllowlist":["Authorization"]}' \
  --agent-runtime-artifact "{
    \"containerConfiguration\": {
      \"containerUri\": \"${ECR_URI}:${IMAGE_TAG}\"
    }
  }" \
  --region "$AWS_REGION")

RUNTIME_ID=$(echo "$RESPONSE" | python -c "import sys,json; print(json.load(sys.stdin)['agentRuntimeId'])")
RUNTIME_ARN=$(echo "$RESPONSE" | python -c "import sys,json; print(json.load(sys.stdin)['agentRuntimeArn'])")

cat <<EOF

============================================================
Deployment complete.

  RUNTIME_ID=$RUNTIME_ID
  RUNTIME_ARN=$RUNTIME_ARN

Export for the client:
  export RUNTIME_ARN="$RUNTIME_ARN"
  export COGNITO_CLIENT_ID="$CLIENT_ID"
============================================================
EOF
