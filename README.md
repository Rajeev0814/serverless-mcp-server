# Serverless MCP Server

A production-pattern Model Context Protocol (MCP) server that runs on **AWS Bedrock AgentCore Runtime** — no EC2, no ECS, no Lambda, no load balancers. Cognito-authenticated, role-based tool access, deployable with one AWS CLI command.

> Full walkthrough on Medium: **https://medium.com/towards-artificial-intelligence/0i-built-a-fully-authenticated-mcp-server-without-ma%E2%81%B6naging-any-servers-9330b0a7b8b8**

---

## What this is

A small, complete, runnable example of:

- An **MCP server** (FastMCP) exposing two tools — `get_weather` and `get_time`
- **Cognito JWT authentication** validated by the runtime before requests hit your code
- **Role-based tool access** via a 60-line ASGI middleware: `tools/list` is filtered per-user, unauthorized `tools/call` is blocked at the edge
- **Deployment to AWS Bedrock AgentCore Runtime** using only the AWS CLI — no Terraform, no SAM
- The one config flag (`requestHeaderAllowlist`) that makes the Authorization header reach your container

---

## Architecture

```
+--------+      Authorization: Bearer <Cognito JWT>      +---------------------+
| Client | ---------------------------------------------> |  AgentCore Runtime  |
+--------+                                                |  - validates JWT    |
                                                          |  - forwards allowed |
                                                          |    headers          |
                                                          +----------+----------+
                                                                     |
                                                                     v
                                                          +---------------------+
                                                          |  Your container     |
                                                          |  +---------------+  |
                                                          |  | RBACMiddleware|  |
                                                          |  | (60 lines)    |  |
                                                          |  +-------+-------+  |
                                                          |          |          |
                                                          |  +-------v-------+  |
                                                          |  |   FastMCP     |  |
                                                          |  |  get_weather  |  |
                                                          |  |  get_time     |  |
                                                          |  +---------------+  |
                                                          +---------------------+
```

---

## Project structure

```
serverless-mcp-server/
├── README.md               # This file
├── LICENSE                 # MIT
├── server.py               # The MCP server + RBAC middleware (single file)
├── client_example.py       # Sample client: authenticate, list tools, call a tool
├── requirements.txt
├── Dockerfile
├── .dockerignore
├── .gitignore
├── docs/
│   └── ARTICLE.md          # The companion Medium article
└── scripts/
    ├── setup_cognito.sh    # Create Cognito user pool + a user
    ├── setup_iam.sh        # Create the IAM role AgentCore will assume
    ├── deploy.sh           # Build image, push to ECR, create the runtime
    ├── update.sh           # Roll a new image into an existing runtime
    ├── iam_trust_policy.json
    └── iam_role_policy.json
```

---

## Quick start

### Prerequisites

- AWS CLI v2 configured with credentials (`aws configure`)
- Docker installed and running
- Python 3.11+ for the client
- An AWS region where Bedrock AgentCore Runtime is available (e.g. `us-east-1`, `us-west-2`)

### 1. Clone

```bash
git clone https://github.com/Rajeev0814/serverless-mcp-server.git
cd serverless-mcp-server
```

### 2. Run locally (optional)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python server.py
# Server is now at http://localhost:8000/mcp
```

Local mode skips JWT validation — `RBACMiddleware` returns an empty allowed-tools set when no `Authorization` header is present. Useful for sanity-checking the server, not for testing RBAC.

### 3. Set up Cognito

```bash
export REGION=us-east-1
export USERNAME=alice@example.com
export PASSWORD='Demo-Passw0rd!'

bash scripts/setup_cognito.sh
```

Capture the three values it prints — `POOL_ID`, `CLIENT_ID`, `DISCOVERY_URL`.

### 4. Set up IAM role

```bash
bash scripts/setup_iam.sh
```

Prints the role ARN. Export it:

```bash
export AGENTCORE_ROLE_ARN="arn:aws:iam::<account>:role/mcp-demo-runtime-role"
```

### 5. Deploy

```bash
export DISCOVERY_URL="<from step 3>"
export CLIENT_ID="<from step 3>"

bash scripts/deploy.sh
```

This builds the Docker image, pushes it to ECR, and creates the AgentCore Runtime with the JWT authorizer and the `Authorization` header allowlist enabled. Prints the runtime ARN.

### 6. Call your server

```bash
export RUNTIME_ARN="<from step 5>"
export COGNITO_CLIENT_ID="<from step 3>"
export EMAIL=alice@example.com
export PASSWORD='Demo-Passw0rd!'

python client_example.py
```

You should see Alice's allowed tools (`get_time` only — she has the `viewer` role) and the result of a `get_time` call.

To see the admin view, add `bob@example.com` to the Cognito user pool and to `USER_ROLES` in `server.py`, then redeploy with `bash scripts/update.sh`.

---

## How the RBAC works

`USER_ROLES` and `ROLE_TOOLS` are hardcoded in [`server.py`](server.py) for clarity. In production these would come from a database — DynamoDB, RDS, or whatever your org uses. The middleware logic doesn't change; only the lookup function does.

| Role  | Tools                       |
|-------|-----------------------------|
| viewer| `get_time`                  |
| admin | `get_weather`, `get_time`   |

The middleware:

1. Reads `Authorization` from the request headers (forwarded by AgentCore via the allowlist).
2. Decodes the JWT payload — no signature check needed, AgentCore did that.
3. Looks up the caller's role → set of allowed tools.
4. On `tools/list`: filters the response body to only allowed tools.
5. On `tools/call`: rejects unauthorized invocations with an MCP-level `isError: true`.
6. Everything else passes through untouched.

---

## The Authorization-header allowlist

If you take one thing from this repo, take this:

**AgentCore strips the client's `Authorization` header by default.** Your container will never see it unless you opt in with:

```
--request-header-configuration '{"requestHeaderAllowlist":["Authorization"]}'
```

That flag is set in [`scripts/deploy.sh`](scripts/deploy.sh). Without it, every request reaches your code with no identifying header, RBAC silently denies everything, and you'll lose a day finding the right doc page.

The relevant AWS doc is the "Propagate a JWT token to AgentCore Runtime" section of [Inbound/Outbound Auth](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-oauth.html).

---

## Updating the runtime

After changes to `server.py`:

```bash
bash scripts/update.sh
```

This builds a new image tag, pushes it, and calls `update-agent-runtime`. AgentCore handles the swap with no downtime.

---

## Cleanup

```bash
# Delete the runtime
aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id <id>

# Delete the IAM role
aws iam delete-role-policy --role-name mcp-demo-runtime-role --policy-name minimal
aws iam delete-role --role-name mcp-demo-runtime-role

# Delete the ECR repo
aws ecr delete-repository --repository-name mcp-demo --force

# Delete the Cognito pool
aws cognito-idp delete-user-pool --user-pool-id <POOL_ID>
```

---

## Limits & costs

- **Per-invocation timeout**: ~15 minutes (undocumented; longer work must span multiple invocations within a session)
- **Payload size**: up to 100 MB per request
- **Session lifetime**: up to 8 hours (`maxLifetime`)
- **Idle session timeout**: default 15 min, configurable 1 min – 8 hr
- **Cost model**: per-request (compute time + data transfer). For low-to-medium traffic, materially cheaper than a 24/7 Fargate task.

---

## What's next

- Swap the hardcoded `USER_ROLES` / `ROLE_TOOLS` dicts for a real lookup against your IdP / DB.
- Add an in-process TTL cache around the role lookup — calling the DB on every request is the obvious bottleneck.
- Add a custom Cognito claim (e.g. `custom:role`) so the role comes from the token itself instead of a separate lookup.
- Add an outbound auth provider (Google, GitHub, Salesforce) using `bedrock-agentcore-control create-oauth2-credential-provider`.

---

## License

MIT — see [LICENSE](LICENSE).

---

## Companion article

For the full narrative explanation — why AgentCore exists, what the trade-offs are, and the war story behind the Authorization header — read **https://medium.com/towards-artificial-intelligence/0i-built-a-fully-authenticated-mcp-server-without-ma%E2%81%B6naging-any-servers-9330b0a7b8b8**
