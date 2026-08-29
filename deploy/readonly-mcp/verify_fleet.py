from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

READ_TOOLS = {
    "list_notes",
    "search_notes",
    "read_note",
    "query_records",
    "recall_context",
    "get_links",
    "get_schema",
    "get_board",
    "get_stats",
}
ESCAPE_PATHS = ("/etc/passwd", "../../.env.md", "~/.ssh/id_rsa.md")


@dataclass(frozen=True, slots=True)
class FleetService:
    name: str
    url: str
    token_env: str | None = None
    token_command: tuple[str, ...] | None = None
    token_json_key: str | None = None


def load_config(path: Path) -> list[FleetService]:
    path = path.expanduser()
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_048_576:
        raise ValueError("fleet config must be a regular, non-symlink file no larger than 1 MiB")
    if os.name != "nt" and path.stat().st_mode & 0o077:
        raise ValueError("fleet config permissions must be 0600 or stricter")
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("version") != 1:
        raise ValueError("fleet config version must be 1")
    raw_services = document.get("services")
    if not isinstance(raw_services, list) or not 1 <= len(raw_services) <= 100:
        raise ValueError("fleet config must contain 1-100 services")

    services: list[FleetService] = []
    names: set[str] = set()
    for raw in raw_services:
        if not isinstance(raw, dict) or "token" in raw:
            raise ValueError("literal tokens are forbidden; use token_env or token_command")
        name = raw.get("name")
        url = raw.get("url")
        token_env = raw.get("token_env")
        token_command = raw.get("token_command")
        token_json_key = raw.get("token_json_key")
        if not isinstance(name, str) or re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name) is None:
            raise ValueError("service names must use 1-64 letters, numbers, dots, underscores, or hyphens")
        parsed = urllib.parse.urlparse(url if isinstance(url, str) else "")
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(f"{name}: service URL must be a credential-free HTTPS URL without query or fragment")
        if name in names:
            raise ValueError(f"duplicate service name: {name}")
        names.add(name)

        has_env = isinstance(token_env, str) and bool(token_env)
        has_command = isinstance(token_command, list) and bool(token_command)
        if has_env == has_command:
            raise ValueError(f"{name}: configure exactly one of token_env or token_command")
        if has_env and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token_env) is None:
            raise ValueError(f"{name}: invalid token environment name")
        command: tuple[str, ...] | None = None
        if has_command:
            if len(token_command) > 32 or any(not isinstance(item, str) or not item or len(item) > 1024 for item in token_command):
                raise ValueError(f"{name}: token command must contain 1-32 bounded string arguments")
            command = tuple(token_command)
        if token_json_key is not None and (not has_command or not isinstance(token_json_key, str) or not token_json_key):
            raise ValueError(f"{name}: token_json_key requires token_command")
        services.append(FleetService(name, url, token_env if has_env else None, command, token_json_key))
    return services


def resolve_token(
    service: FleetService,
    environment: Mapping[str, str] = os.environ,
    runner: Callable[[tuple[str, ...]], str] | None = None,
) -> str:
    if service.token_env is not None:
        value = environment.get(service.token_env, "")
    else:
        command = service.token_command or ()
        if runner is None:
            runner = lambda args: subprocess.run(
                args, check=True, capture_output=True, text=True, timeout=30
            ).stdout
        output = runner(command)
        if service.token_json_key is None:
            value = output
        else:
            payload = json.loads(output)
            value = payload.get(service.token_json_key, "") if isinstance(payload, dict) else ""
    token = str(value).strip()
    if not 32 <= len(token) <= 4096 or not token.isascii() or any(character.isspace() for character in token):
        raise ValueError(f"{service.name}: resolved token is invalid")
    return token


def select_services(services: list[FleetService], names: list[str]) -> list[FleetService]:
    if not names:
        return services
    by_name = {service.name: service for service in services}
    unknown = sorted(set(names) - by_name.keys())
    if unknown:
        raise ValueError(f"unknown fleet services: {unknown}")
    return [service for service in services if service.name in set(names)]


def first_note_title(payload: dict[str, Any]) -> str:
    notes = payload.get("notes", "")
    title = str(notes).splitlines()[0].split("\t", 1)[0].strip() if notes else ""
    if not title:
        raise ValueError("hosted vault has no record available for a retrieval probe")
    return title


def http_status(url: str, token: str | None) -> int:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def tool_text(result: Any) -> str:
    return "\n".join(getattr(item, "text", "") for item in result.content)


async def verify_service(service: FleetService, token: str) -> dict[str, Any]:
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client
    from mcp.shared.exceptions import McpError

    started = time.monotonic()
    anonymous_status, invalid_status, authenticated_status = await asyncio.gather(
        asyncio.to_thread(http_status, service.url, None),
        asyncio.to_thread(http_status, service.url, "invalid-invalid-invalid-invalid-0000"),
        asyncio.to_thread(http_status, service.url, token),
    )
    if anonymous_status != 401 or invalid_status != 401:
        raise RuntimeError(f"{service.name}: unauthenticated request was not denied")
    if authenticated_status in {401, 403} or authenticated_status >= 500:
        raise RuntimeError(f"{service.name}: authenticated endpoint returned {authenticated_status}")

    async with (
        streamablehttp_client(service.url, headers={"Authorization": f"Bearer {token}"}) as streams,
        ClientSession(streams[0], streams[1]) as session,
    ):
        initialized = await asyncio.wait_for(session.initialize(), timeout=30)
        tools = await asyncio.wait_for(session.list_tools(), timeout=30)
        names = {tool.name for tool in tools.tools}
        if names != READ_TOOLS:
            raise RuntimeError(f"{service.name}: unsafe tool surface {sorted(names)}")

        listing = await asyncio.wait_for(session.call_tool("list_notes", {"limit": 1}), timeout=30)
        title = first_note_title(json.loads(tool_text(listing)))
        search = await asyncio.wait_for(
            session.call_tool("search_notes", {"query": title, "ranked": True, "limit": 5}),
            timeout=30,
        )
        search_text = tool_text(search)
        search_payload = json.loads(search_text)
        if int(search_payload.get("count", 0)) > 5 or title.casefold() not in search_text.casefold():
            raise RuntimeError(f"{service.name}: bounded retrieval probe failed")

        recall = await asyncio.wait_for(
            session.call_tool("recall_context", {"query": title, "limit": 5, "budget": 4000}),
            timeout=30,
        )
        recall_text = tool_text(recall)
        recall_payload = json.loads(recall_text)
        if int(recall_payload.get("usedBytes", 4001)) > 4000 or title.casefold() not in recall_text.casefold():
            raise RuntimeError(f"{service.name}: bounded recall probe failed")

        for path in ESCAPE_PATHS:
            blocked = await asyncio.wait_for(session.call_tool("read_note", {"path": path}), timeout=30)
            blocked_text = tool_text(blocked)
            if not getattr(blocked, "isError", False) or "root:" in blocked_text or "BEGIN PRIVATE KEY" in blocked_text:
                raise RuntimeError(f"{service.name}: path confinement probe failed")

        try:
            write_result = await asyncio.wait_for(
                session.call_tool("create_note", {"title": "must-not-exist"}),
                timeout=30,
            )
            write_blocked = bool(getattr(write_result, "isError", False))
        except McpError:
            write_blocked = True
        if not write_blocked:
            raise RuntimeError(f"{service.name}: write denial probe failed")

    return {
        "name": service.name,
        "url": service.url,
        "passed": True,
        "latency_ms": round((time.monotonic() - started) * 1000, 1),
        "protocol_version": initialized.protocolVersion,
        "tools": sorted(names),
        "probe_title": title,
        "anonymous_status": anonymous_status,
        "invalid_status": invalid_status,
        "authenticated_status": authenticated_status,
        "path_escapes_blocked": len(ESCAPE_PATHS),
        "ranked_limit": 5,
        "recall_budget": 4000,
        "write_call_blocked": write_blocked,
    }


async def verify_fleet(services: list[FleetService]) -> dict[str, Any]:
    tokens = await asyncio.gather(
        *(asyncio.to_thread(resolve_token, service) for service in services)
    )
    results = await asyncio.gather(
        *(verify_service(service, token) for service, token in zip(services, tokens, strict=True))
    )
    return {"coverage": f"{len(results)}/{len(services)}", "results": results}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify a token-authenticated, read-only Retex MCP fleet without persisting credentials."
    )
    parser.add_argument("--config", type=Path, required=True, help="0600 JSON fleet config")
    parser.add_argument("--service", action="append", default=[], help="Verify one named service; repeatable")
    args = parser.parse_args()
    try:
        services = select_services(load_config(args.config), args.service)
        report = asyncio.run(verify_fleet(services))
    except (
        ImportError,
        OSError,
        ValueError,
        RuntimeError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
    ) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "data": report}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
