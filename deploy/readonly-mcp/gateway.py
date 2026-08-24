"""Token-authenticated, read-only Retex MCP over Streamable HTTP."""

from __future__ import annotations

import hmac
import json
import os
import sys
from collections.abc import Mapping

from fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Mount, Route

RETEX_BIN = os.environ.get("RETEX_BIN", "retex")
VAULT = os.environ.get("RETEX_VAULT", "/data/vault")
SERVICE_NAME = os.environ.get("RETEX_SERVICE_NAME", "retex-readonly")
MAX_REQUEST_BYTES = 1_048_576


def load_tokens(environ: Mapping[str, str] = os.environ) -> tuple[str, ...]:
    """Load one legacy token plus optional named tokens for rotation/agents."""
    candidates: list[object] = []
    if token := environ.get("RETEX_MCP_TOKEN", "").strip():
        candidates.append(token)

    if encoded := environ.get("RETEX_MCP_TOKENS_JSON", "").strip():
        try:
            configured = json.loads(encoded)
        except json.JSONDecodeError as exc:
            raise RuntimeError("RETEX_MCP_TOKENS_JSON must be valid JSON") from exc
        if isinstance(configured, dict):
            candidates.extend(configured.values())
        elif isinstance(configured, list):
            candidates.extend(configured)
        else:
            raise RuntimeError("RETEX_MCP_TOKENS_JSON must be an object or array")

    tokens: list[str] = []
    for candidate in candidates:
        if not isinstance(candidate, str) or len(candidate) < 32:
            raise RuntimeError("every Retex MCP token must be a string of at least 32 characters")
        if candidate not in tokens:
            tokens.append(candidate)
    if not tokens:
        raise RuntimeError("RETEX_MCP_TOKEN or RETEX_MCP_TOKENS_JSON is required")
    return tuple(tokens)


TOKENS: tuple[str, ...] = ()


def authorized(header: bytes) -> bool:
    try:
        scheme, separator, value = header.decode("ascii").partition(" ")
    except UnicodeDecodeError:
        return False
    if scheme.lower() != "bearer" or separator != " " or not value:
        return False
    matched = False
    for expected in TOKENS:
        matched = hmac.compare_digest(value, expected) or matched
    return matched


def build_proxy() -> FastMCP:
    command = [RETEX_BIN, "mcp", "--vault", VAULT]
    return FastMCP.as_proxy(
        {"mcpServers": {"retex": {"command": command[0], "args": command[1:]}}},
        name=SERVICE_NAME,
    )


def security_middleware(app):
    security_headers = {
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
        "X-Content-Type-Options": "nosniff",
    }

    async def middleware(scope, receive, send):
        if scope["type"] != "http":
            await app(scope, receive, send)
            return

        async def reject(message: str, status: int, *, authenticate: bool = False) -> None:
            headers = dict(security_headers)
            if authenticate:
                headers["WWW-Authenticate"] = 'Bearer realm="retex"'
            response = PlainTextResponse(message, status_code=status, headers=headers)
            await response(scope, receive, send)

        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        if not authorized(headers.get(b"authorization", b"")):
            await reject("unauthorized", 401, authenticate=True)
            return

        content_length = headers.get(b"content-length")
        if scope.get("method") == "POST" and content_length is None:
            await reject("content length required", 411)
            return
        try:
            length = int(content_length or b"0")
            too_large = length < 0 or length > MAX_REQUEST_BYTES
        except ValueError:
            too_large = True
        if too_large:
            await reject("request too large", 413)
            return

        secured_receive = receive
        if scope.get("method") == "POST":
            chunks: list[bytes] = []
            actual_length = 0
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    await reject("request disconnected", 400)
                    return
                if message["type"] != "http.request":
                    continue
                chunk = message.get("body", b"")
                actual_length += len(chunk)
                if actual_length > MAX_REQUEST_BYTES:
                    await reject("request too large", 413)
                    return
                chunks.append(chunk)
                if not message.get("more_body", False):
                    break
            if actual_length != length:
                await reject("content length mismatch", 400)
                return

            body = b"".join(chunks)
            replayed = False

            async def replay_receive():
                nonlocal replayed
                if replayed:
                    return await receive()
                replayed = True
                return {"type": "http.request", "body": body, "more_body": False}
            secured_receive = replay_receive

        async def secure_send(message):
            if message["type"] == "http.response.start":
                existing = {
                    key.lower()
                    for key, _value in message.get("headers", [])
                }
                response_headers = list(message.get("headers", []))
                response_headers.extend(
                    (key.lower().encode(), value.encode())
                    for key, value in security_headers.items()
                    if key.lower().encode() not in existing
                )
                message["headers"] = response_headers
            await send(message)

        await app(scope, secured_receive, secure_send)

    return middleware


async def health(_request: Request) -> JSONResponse:
    return JSONResponse({"status": "ok", "service": SERVICE_NAME, "mode": "read-only"})


def main() -> None:
    import uvicorn

    global TOKENS
    TOKENS = load_tokens()
    proxy = build_proxy()
    mcp_app = proxy.http_app(path="/mcp", stateless_http=True)
    app = Starlette(
        routes=[Route("/health", health, methods=["GET"]), Mount("/", mcp_app)],
        lifespan=mcp_app.lifespan,
    )
    port = int(os.environ.get("PORT", "8080"))
    print(f"{SERVICE_NAME} serving in read-only mode on :{port}")
    uvicorn.run(
        security_middleware(app),
        host=os.environ.get("HOST", "0.0.0.0"),
        port=port,
        access_log=False,
        date_header=False,
        server_header=False,
        proxy_headers=False,
        timeout_keep_alive=30,
    )


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
