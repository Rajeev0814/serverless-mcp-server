#!/usr/bin/env bash
# Create the IAM role that AgentCore Runtime assumes when running the
# container. Prints the role ARN on success.
#
# Usage:
#   bash scripts/setup_iam.sh
set -euo pipefail

ROLE_NAME="${ROLE_NAME:-mcp-demo-runtime-role}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Creating IAM role '$ROLE_NAME'..."
if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  echo "   (role already exists, reusing)"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${SCRIPT_DIR}/iam_trust_policy.json" \
    > /dev/null
fi

echo ">> Attaching inline policy..."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name minimal \
  --policy-document "file://${SCRIPT_DIR}/iam_role_policy.json"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

cat <<EOF

============================================================
IAM role ready. Export this for the next step:

  export AGENTCORE_ROLE_ARN="$ROLE_ARN"
============================================================
EOF
