"""
Serverless MCP server with Cognito auth and role-based tool access.

Exposes two MCP tools:
  - get_weather(city)
  - get_time(timezone)

Wraps the FastMCP ASGI app in a middleware that:
  1. Reads the Authorization header forwarded by AgentCore.
  2. Decodes the Cognito JWT to identify the caller.
  3. Filters tools/list responses to only tools the caller's role allows.
  4. Blocks tools/call requests for tools the caller isn't allowed to invoke.

The runtime must be created with `requestHeaderAllowlist=["Authorization"]`
or the Authorization header is stripped and every caller is treated as
anonymous (zero tools).
"""

from __future__ import annotations

import base64
import json
import logging
from datetime import datetime
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from mcp.server.fastmcp import FastMCP

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mcp-server")


# ---------------------------------------------------------------------------
# MCP server + tools
# ---------------------------------------------------------------------------

mcp = FastMCP(
    host="0.0.0.0",
    port=8000,
    stateless_http=True,
    name="serverless-mcp-demo",
    instructions="A small demo MCP server with Cognito auth and RBAC.",
)


@mcp.tool()
def get_weather(city: str) -> str:
    """Return the current weather for a given city (mocked)."""
    # In production, call an actual weather API here.
    return f"Weather in {city}: 24C, partly cloudy."


@mcp.tool()
def get_time(timezone: str = "UTC") -> str:
    """Return the current time in the given IANA timezone (e.g. 'America/New_York')."""
    try:
        now = datetime.now(ZoneInfo(timezone))
    except Exception:
        return f"Unknown timezone: {timezone}"
    return now.isoformat()


# ---------------------------------------------------------------------------
# Role-based access control
# ---------------------------------------------------------------------------

# Role-to-tools mapping. Hardcoded for clarity.
# In production, fetch this from DynamoDB, RDS, or your IdP claims:
#     SELECT tool_name FROM role_tools WHERE role_id = :role
ROLE_TOOLS: dict[str, set[str]] = {
    "viewer": {"get_time"},                  # read-only: time only
    "admin":  {"get_weather", "get_time"},   # full access
}

# Hardcoded user-to-role mapping.
# In production: JOIN users -> roles table, or read a custom claim like
# `custom:role` from the Cognito ID token instead of a separate lookup.
USER_ROLES: dict[str, str] = {
    "alice@example.com": "viewer",
    "bob@example.com":   "admin",
}


def allowed_tools_for(email: str) -> set[str]:
    """Return the set of tool names this user is allowed to use."""
    role = USER_ROLES.get(email)
    return ROLE_TOOLS.get(role or "", set())


# ---------------------------------------------------------------------------
# JWT decoding (no signature check — AgentCore already validated the token)
# ---------------------------------------------------------------------------

def decode_jwt_email(authorization: str) -> str:
    """Pull the email claim out of a Cognito JWT.

    AgentCore Runtime validates the signature before our code runs. If a
    request reaches us, the token is valid; we just decode the payload to
    learn who the caller is.
    """
    if not authorization:
        return ""
    token = authorization.removeprefix("Bearer ").strip()
    if token.count(".") != 2:
        return ""
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * ((4 - len(payload_b64) % 4) % 4)
        payload = json.loads(base64.b64decode(payload_b64))
        return (
            payload.get("email")
            or payload.get("cognito:username")
            or ""
        )
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# ASGI middleware enforcing RBAC at the MCP protocol layer
# ---------------------------------------------------------------------------

ASGIReceive = Callable[[], Awaitable[dict]]
ASGISend = Callable[[dict], Awaitable[None]]


def _filter_tools(body: bytes, allowed: set[str]) -> bytes:
    """Strip tools not in `allowed` from a JSON-RPC tools/list response body."""
    try:
        payload = json.loads(body)
        if isinstance(payload, dict) and "tools" in payload.get("result", {}):
            payload["result"]["tools"] = [
                t for t in payload["result"]["tools"]
                if t.get("name") in allowed
            ]
            return json.dumps(payload).encode()
    except Exception:
        pass
    return body


class RBACMiddleware:
    """Enforce role-based MCP tool access on top of any ASGI MCP server."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive: ASGIReceive, send: ASGISend):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        # 1. Identify caller from the JWT.
        headers = dict(scope.get("headers", []))
        auth = headers.get(b"authorization", b"").decode()
        email = decode_jwt_email(auth)
        allowed = allowed_tools_for(email)
        log.info("rbac email=%r tools=%s", email, sorted(allowed))

        # 2. Buffer the body so we can both inspect and replay it.
        chunks: list[bytes] = []
        more = True
        while more:
            msg = await receive()
            chunks.append(msg.get("body", b""))
            more = msg.get("more_body", False)
        body = b"".join(chunks)

        method = ""
        rpc: dict = {}
        try:
            rpc = json.loads(body)
            method = rpc.get("method", "")
        except Exception:
            pass

        delivered = False

        async def replay_receive():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        # 3. Block forbidden tools/call before the tool executes.
        if method == "tools/call":
            name = rpc.get("params", {}).get("name", "")
            if name not in allowed:
                log.warning("denied email=%r tool=%r", email, name)
                error = {
                    "jsonrpc": "2.0",
                    "id": rpc.get("id"),
                    "result": {
                        "content": [{
                            "type": "text",
                            "text": (
                                f"Access denied: '{name}' is not available "
                                "for your role."
                            ),
                        }],
                        "isError": True,
                    },
                }
                await send({
                    "type": "http.response.start",
                    "status": 200,
                    "headers": [(b"content-type", b"application/json")],
                })
                await send({
                    "type": "http.response.body",
                    "body": json.dumps(error).encode(),
                })
                return

        # 4. Filter tools/list response inline.
        if method == "tools/list":
            async def filtering_send(msg):
                if msg["type"] == "http.response.start":
                    # Body size changes after filtering — drop content-length.
                    msg = {**msg, "headers": [
                        h for h in msg.get("headers", [])
                        if h[0].lower() != b"content-length"
                    ]}
                    await send(msg)
                elif msg["type"] == "http.response.body":
                    await send({
                        **msg,
                        "body": _filter_tools(msg.get("body", b""), allowed),
                    })
                else:
                    await send(msg)

            await self.app(scope, replay_receive, filtering_send)
            return

        # 5. Everything else passes through.
        await self.app(scope, replay_receive, send)


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    app = mcp.streamable_http_app()
    app = RBACMiddleware(app)
    log.info("Starting MCP server on 0.0.0.0:8000")
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
