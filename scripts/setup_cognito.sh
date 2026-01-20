#!/usr/bin/env bash
# Create a Cognito user pool, an app client, and one user for testing.
# Prints POOL_ID, CLIENT_ID, and DISCOVERY_URL on success.
#
# Usage:
#   export REGION=us-east-1
#   export USERNAME=alice@example.com
#   export PASSWORD='Demo-Passw0rd!'
#   bash scripts/setup_cognito.sh
set -euo pipefail

: "${REGION:?REGION env var is required (e.g. us-east-1)}"
: "${USERNAME:?USERNAME env var is required (e.g. alice@example.com)}"
: "${PASSWORD:?PASSWORD env var is required}"

POOL_NAME="${POOL_NAME:-mcp-demo-pool}"
CLIENT_NAME="${CLIENT_NAME:-mcp-demo-client}"

echo ">> Creating user pool '$POOL_NAME' in $REGION..."
POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "$POOL_NAME" \
  --policies '{"PasswordPolicy":{"MinimumLength":8}}' \
  --auto-verified-attributes email \
  --schema 'Name=email,AttributeDataType=String,Required=true,Mutable=true' \
  --region "$REGION" \
  --query 'UserPool.Id' --output text)

echo ">> Creating app client '$CLIENT_NAME'..."
CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-name "$CLIENT_NAME" \
  --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region "$REGION" \
  --query 'UserPoolClient.ClientId' --output text)

echo ">> Creating user '$USERNAME'..."
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username "$USERNAME" \
  --user-attributes "Name=email,Value=$USERNAME" "Name=email_verified,Value=true" \
  --message-action SUPPRESS \
  --region "$REGION" > /dev/null

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "$USERNAME" \
  --password "$PASSWORD" \
  --permanent \
  --region "$REGION"

DISCOVERY_URL="https://cognito-idp.${REGION}.amazonaws.com/${POOL_ID}/.well-known/openid-configuration"

cat <<EOF

============================================================
Cognito setup complete. Export these for the next steps:

  export POOL_ID="$POOL_ID"
  export CLIENT_ID="$CLIENT_ID"
  export DISCOVERY_URL="$DISCOVERY_URL"

User: $USERNAME (password set, permanent)
============================================================
EOF
