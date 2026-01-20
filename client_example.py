"""
Sample MCP client for the deployed AgentCore Runtime.

Usage:
    export COGNITO_CLIENT_ID="<from setup_cognito.sh>"
    export RUNTIME_ARN="<from deploy.sh>"
    export EMAIL="alice@example.com"
    export PASSWORD="Demo-Passw0rd!"
    export AWS_REGION="us-east-1"
    python client_example.py

The script logs into Cognito, opens an MCP session against the runtime,
lists the tools the caller is allowed to see, and calls one of them.
"""

from __future__ import annotations

import asyncio
import os
import sys

import boto3
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"Missing required env var: {name}", file=sys.stderr)
        sys.exit(1)
    return value


def get_cognito_id_token(region: str, client_id: str, email: str, password: str) -> str:
    """Authenticate against Cognito and return the IdToken."""
    cognito = boto3.client("cognito-idp", region_name=region)
    resp = cognito.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": email, "PASSWORD": password},
        ClientId=client_id,
    )
    return resp["AuthenticationResult"]["IdToken"]


def build_invocation_url(region: str, runtime_arn: str) -> str:
    encoded = runtime_arn.replace(":", "%3A").replace("/", "%2F")
    return (
        f"https://bedrock-agentcore.{region}.amazonaws.com"
        f"/runtimes/{encoded}/invocations?qualifier=DEFAULT"
    )


async def main() -> None:
    region = os.environ.get("AWS_REGION", "us-east-1")
    client_id = env("COGNITO_CLIENT_ID")
    runtime_arn = env("RUNTIME_ARN")
    email = env("EMAIL")
    password = env("PASSWORD")

    print(f"Authenticating as {email}...")
    token = get_cognito_id_token(region, client_id, email, password)
    print(f"Got IdToken ({len(token)} chars).")

    url = build_invocation_url(region, runtime_arn)
    headers = {"authorization": f"Bearer {token}"}

    print(f"Connecting to {url}")
    async with streamablehttp_client(url, headers=headers, timeout=30) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            print(f"\nAllowed tools ({len(tools.tools)}):")
            for t in tools.tools:
                print(f"  - {t.name}: {t.description}")

            if not tools.tools:
                print("\n(No tools — likely the Authorization header isn't reaching")
                print(" the runtime, or this user has no role mapping.)")
                return

            # Call the first allowed tool.
            target = tools.tools[0].name
            print(f"\nCalling {target}()...")
            if target == "get_weather":
                result = await session.call_tool(target, {"city": "New York"})
            elif target == "get_time":
                result = await session.call_tool(target, {"timezone": "America/New_York"})
            else:
                result = await session.call_tool(target, {})

            for content in result.content:
                if hasattr(content, "text"):
                    print(f"Result: {content.text}")


if __name__ == "__main__":
    asyncio.run(main())
