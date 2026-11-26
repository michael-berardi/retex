from __future__ import annotations

import asyncio
import hashlib
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import gateway
import refresh_vault
import validate_vault
import verify_fleet


def load_sync_server():
    """Import deploy/sync-server/server.py, which is not on sys.path."""
    path = Path(__file__).resolve().parent.parent / "sync-server" / "server.py"
    spec = importlib.util.spec_from_file_location("retex_sync_server_under_test", path)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


try:
    sync_server = load_sync_server()
except (OSError, ImportError):  # the deploy helper is absent from some checkouts
    sync_server = None


class TokenTests(unittest.TestCase):
    def test_loads_legacy_and_named_tokens(self) -> None:
        legacy = "a" * 32
        named = "b" * 32
        self.assertEqual(
            gateway.load_tokens(
                {
                    "RETEX_MCP_TOKEN": legacy,
                    "RETEX_MCP_TOKENS_JSON": '{"agent": "' + named + '"}',
                }
            ),
            (legacy, named),
        )

    def test_rejects_missing_or_short_tokens(self) -> None:
        with self.assertRaises(RuntimeError):
            gateway.load_tokens({})
        with self.assertRaises(RuntimeError):
            gateway.load_tokens({"RETEX_MCP_TOKEN": "too-short"})
        with self.assertRaises(RuntimeError):
            gateway.load_tokens({"RETEX_MCP_TOKEN": "é" * 32})

    def test_resolves_rotation_only_named_tokens(self) -> None:
        first = "c" * 32
        second = "d" * 32
        # Rotation-only deployments set no legacy token at all; the HEALTHCHECK
        # and the gateway must both find a usable token in RETEX_MCP_TOKENS_JSON.
        self.assertEqual(
            gateway.load_tokens({"RETEX_MCP_TOKENS_JSON": json.dumps({"one": first, "two": second})}),
            (first, second),
        )
        self.assertEqual(
            gateway.load_tokens({"RETEX_MCP_TOKENS_JSON": json.dumps([first, second])}),
            (first, second),
        )
        with self.assertRaises(RuntimeError):
            gateway.load_tokens({"RETEX_MCP_TOKENS_JSON": json.dumps([])})

    def test_authorization_requires_exact_bearer_token(self) -> None:
        original = gateway.TOKENS
        gateway.TOKENS = ("a" * 32, "b" * 32)
        try:
            self.assertTrue(gateway.authorized(b"Bearer " + b"b" * 32))
            self.assertFalse(gateway.authorized(b"Bearer " + b"c" * 32))
            self.assertFalse(gateway.authorized(b"Basic " + b"b" * 32))
        finally:
            gateway.TOKENS = original


class MiddlewareTests(unittest.IsolatedAsyncioTestCase):
    async def invoke(self, body: bytes, declared_length: int) -> tuple[int, bool, list[tuple[bytes, bytes]]]:
        called = False

        async def app(_scope, receive, send):
            nonlocal called
            called = True
            request = await receive()
            self.assertEqual(request["type"], "http.request")
            self.assertEqual((await receive())["type"], "http.disconnect")
            await send(
                {
                    "type": "http.response.start",
                    "status": 200,
                    "headers": [(b"content-type", b"text/plain")],
                }
            )
            await send({"type": "http.response.body", "body": b"ok"})

        messages = iter(
            [
                {"type": "http.request", "body": body, "more_body": False},
            ]
        )

        async def receive():
            return next(messages, {"type": "http.disconnect"})

        sent = []

        async def send(message):
            sent.append(message)

        original = gateway.TOKENS
        gateway.TOKENS = ("a" * 32,)
        try:
            await gateway.security_middleware(app)(
                {
                    "type": "http",
                    "method": "POST",
                    "scheme": "https",
                    "headers": [
                        (b"authorization", b"Bearer " + b"a" * 32),
                        (b"content-length", str(declared_length).encode()),
                    ],
                },
                receive,
                send,
            )
        finally:
            gateway.TOKENS = original

        start = next(message for message in sent if message["type"] == "http.response.start")
        return start["status"], called, start["headers"]

    async def test_rejects_actual_body_larger_than_declared(self) -> None:
        status, called, _headers = await self.invoke(b"unexpected", declared_length=1)
        self.assertEqual(status, 400)
        self.assertFalse(called)

    async def test_rejects_actual_body_over_limit(self) -> None:
        body = b"x" * (gateway.MAX_REQUEST_BYTES + 1)
        status, called, _headers = await self.invoke(
            body,
            declared_length=gateway.MAX_REQUEST_BYTES,
        )
        self.assertEqual(status, 413)
        self.assertFalse(called)

    async def test_adds_api_security_headers(self) -> None:
        status, called, headers = await self.invoke(b"{}", declared_length=2)
        self.assertEqual(status, 200)
        self.assertTrue(called)
        names = {name.lower() for name, _value in headers}
        self.assertTrue(
            {
                b"cache-control",
                b"x-content-type-options",
                b"strict-transport-security",
                b"content-security-policy",
                b"referrer-policy",
            }.issubset(names)
        )

    async def test_concurrency_guard_sheds_excess_requests(self) -> None:
        """A burst must be bounded so `retex mcp` children cannot exhaust the host."""
        release = asyncio.Event()
        entered = asyncio.Event()

        async def slow_app(_scope, receive, send):
            await receive()
            entered.set()
            await release.wait()
            await send({"type": "http.response.start", "status": 200, "headers": []})
            await send({"type": "http.response.body", "body": b"ok"})

        def scope() -> dict:
            return {
                "type": "http",
                "method": "POST",
                "scheme": "https",
                "headers": [
                    (b"authorization", b"Bearer " + b"a" * 32),
                    (b"content-length", b"2"),
                ],
            }

        def receive_factory():
            state = {"sent": False}

            async def receive():
                if not state["sent"]:
                    state["sent"] = True
                    return {"type": "http.request", "body": b"{}", "more_body": False}
                return {"type": "http.disconnect"}

            return receive

        def collector(bucket: list) -> object:
            async def send(message):
                bucket.append(message)

            return send

        def status_of(bucket: list) -> int:
            return next(m for m in bucket if m["type"] == "http.response.start")["status"]

        original = (gateway.TOKENS, gateway.MAX_CONCURRENT_REQUESTS, gateway.CONCURRENCY_WAIT_SECONDS)
        gateway.TOKENS = ("a" * 32,)
        gateway.MAX_CONCURRENT_REQUESTS = 1
        gateway.CONCURRENCY_WAIT_SECONDS = 0.05
        try:
            middleware = gateway.security_middleware(slow_app)
            first: list = []
            first_task = asyncio.create_task(
                middleware(scope(), receive_factory(), collector(first))
            )
            await asyncio.wait_for(entered.wait(), 5)
            second: list = []
            await middleware(scope(), receive_factory(), collector(second))
            self.assertEqual(status_of(second), 503)
            release.set()
            await first_task
            self.assertEqual(status_of(first), 200)
            # The permit is handed back, so the next request is served normally.
            third: list = []
            await middleware(scope(), receive_factory(), collector(third))
            self.assertEqual(status_of(third), 200)
        finally:
            gateway.TOKENS = original[0]
            gateway.MAX_CONCURRENT_REQUESTS = original[1]
            gateway.CONCURRENCY_WAIT_SECONDS = original[2]


class VaultValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_note(self, body: str = "# Safe project facts") -> Path:
        note = self.root / "project.md"
        note.write_text(f"---\nshareable: true\ntype: note\n---\n\n{body}\n", encoding="utf-8")
        return note

    def test_accepts_explicitly_shareable_markdown(self) -> None:
        self.write_note()
        self.assertEqual(validate_vault.validate(self.root), 1)

    def test_rejects_note_without_shareable_marker(self) -> None:
        (self.root / "project.md").write_text("# Internal only\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "shareable"):
            validate_vault.validate(self.root)

    def test_rejects_known_secret_patterns(self) -> None:
        self.write_note("token: " + "s" * 32)
        with self.assertRaisesRegex(ValueError, "secret assignment"):
            validate_vault.validate(self.root)

    def test_rejects_telegram_tokens_and_credentialed_urls(self) -> None:
        self.write_note("bot " + "1234567890:" + "A" * 35)
        with self.assertRaisesRegex(ValueError, "Telegram"):
            validate_vault.validate(self.root)

        self.write_note("endpoint https://user:long-password-value@example.com/api")
        with self.assertRaisesRegex(ValueError, "credentialed URL"):
            validate_vault.validate(self.root)

    def test_rejects_non_markdown_files(self) -> None:
        self.write_note()
        (self.root / "config.json").write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "only Markdown"):
            validate_vault.validate(self.root)

    def test_rejects_symlinks(self) -> None:
        outside = self.root.parent / f"outside-{self.root.name}.md"
        outside.write_text("protected", encoding="utf-8")
        try:
            (self.root / "project.md").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "symlinks"):
                validate_vault.validate(self.root)
        finally:
            outside.unlink(missing_ok=True)



class VaultRefresherTests(unittest.TestCase):
    """Offline end-to-end refresh against a local git remote."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        self.work = self.root / "seed-work"
        self.data = self.root / "data"
        # Explicit branch: the tests must not depend on init.defaultBranch.
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=main", str(self.remote)], check=True)
        self._commit_note("# Safe project facts")
        self.env = {
            "RETEX_VAULT_REPO": str(self.remote),
            "RETEX_VAULT_REF": "main",
            "RETEX_DATA_DIR": str(self.data),
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _note_text(self, body: str) -> str:
        return f"---\nshareable: true\ntype: note\n---\n\n{body}\n"

    def _commit_note(self, body: str, name: str = "project.md") -> None:
        if not self.work.exists():
            subprocess.run(["git", "clone", "--quiet", str(self.remote), str(self.work)], check=True)
            subprocess.run(["git", "-C", str(self.work), "config", "user.email", "t@t"], check=True)
            subprocess.run(["git", "-C", str(self.work), "config", "user.name", "t"], check=True)
            subprocess.run(["git", "-C", str(self.work), "checkout", "--quiet", "-B", "main"], check=True)
        (self.work / name).write_text(self._note_text(body), encoding="utf-8")
        subprocess.run(["git", "-C", str(self.work), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.work), "commit", "--quiet", "-m", f"note {body}"], check=True)
        subprocess.run(["git", "-C", str(self.work), "push", "--quiet", "origin", "main"], check=True)

    def _refresher(self, **overrides) -> refresh_vault.VaultRefresher:
        return refresh_vault.VaultRefresher({**self.env, **overrides})

    def test_applies_new_revision_and_serves_content(self) -> None:
        refresher = self._refresher()
        refresher.bootstrap_layout()
        self.assertTrue(refresher.poll_once())
        self.assertTrue(refresher.serving_dir.is_dir())
        self.assertFalse(refresher.serving_dir.is_symlink())
        self.assertEqual((refresher.serving_dir / "project.md").read_text(), self._note_text("# Safe project facts"))
        status = json.loads(refresher.status_path.read_text())
        self.assertIsNone(status.get("last_error"))
        self.assertEqual(len(status["revision"]), 40)

    def test_second_commit_propagates_and_old_volume_is_pruned(self) -> None:
        refresher = self._refresher()
        refresher.bootstrap_layout()
        refresher.poll_once()
        first_status = json.loads(refresher.status_path.read_text())
        self.assertFalse(refresher.poll_once())  # unchanged HEAD is a no-op
        self._commit_note("# Updated facts")
        self.assertTrue(refresher.poll_once())
        second_status = json.loads(refresher.status_path.read_text())
        self.assertNotEqual(first_status["revision"], second_status["revision"])
        self.assertIn("# Updated facts", (refresher.serving_dir / "project.md").read_text())
        # The current revision lives at the serving path; volumes keeps no
        # stale copies.
        remaining = sorted(p.name for p in refresher.volumes_dir.iterdir() if p.is_dir())
        self.assertEqual(remaining, [])
        self.assertEqual(second_status["revision"], refresher.applied_revision)

    def test_disabled_without_repo(self) -> None:
        refresher = refresh_vault.VaultRefresher({"RETEX_VAULT_REPO": ""})
        self.assertFalse(refresher.poll_once())

    def test_invalid_revision_is_rejected_fail_closed(self) -> None:
        refresher = self._refresher()
        refresher.bootstrap_layout()
        refresher.poll_once()
        good = json.loads(refresher.status_path.read_text())["revision"]
        # A note without shareable frontmatter must never be served.
        (self.work / "leak.md").write_text("# internal only\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.work), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.work), "commit", "--quiet", "-m", "bad"], check=True)
        subprocess.run(["git", "-C", str(self.work), "push", "--quiet", "origin", "main"], check=True)
        self.assertFalse(refresher.poll_once())
        self.assertEqual(json.loads(refresher.status_path.read_text())["revision"], good)
        self.assertIn("# Safe project facts", (refresher.serving_dir / "project.md").read_text())
        self.assertIn("last_error", json.loads(refresher.status_path.read_text()))

    def test_subdir_serving(self) -> None:
        (self.work / "curated").mkdir(exist_ok=True)
        (self.work / "curated" / "c.md").write_text(self._note_text("# Curated"), encoding="utf-8")
        (self.work / "secret.md").write_text(self._note_text("# Not served"), encoding="utf-8")
        subprocess.run(["git", "-C", str(self.work), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.work), "commit", "--quiet", "-m", "subdir"], check=True)
        subprocess.run(["git", "-C", str(self.work), "push", "--quiet", "origin", "main"], check=True)
        refresher = self._refresher(RETEX_VAULT_SUBDIR="curated")
        refresher.bootstrap_layout()
        refresher.poll_once()
        names = sorted(p.name for p in refresher.serving_dir.iterdir())
        self.assertEqual(names, [".retex", "c.md"])

    def test_commit_outside_served_subdir_does_not_download_or_swap(self) -> None:
        """Regression: every commit anywhere in the vault repo used to trigger a full
        clone + copy of the whole repo (186 refreshes / ~110 GB written in 5 days)."""
        (self.work / "curated").mkdir(exist_ok=True)
        (self.work / "curated" / "c.md").write_text(self._note_text("# Curated"), encoding="utf-8")
        subprocess.run(["git", "-C", str(self.work), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.work), "commit", "--quiet", "-m", "subdir"], check=True)
        subprocess.run(["git", "-C", str(self.work), "push", "--quiet", "origin", "main"], check=True)
        refresher = self._refresher(RETEX_VAULT_SUBDIR="curated")
        refresher.bootstrap_layout()
        self.assertTrue(refresher.poll_once())
        first_inode = refresher.serving_dir.stat().st_ino
        self._commit_note("# Elsewhere", name="other.md")  # outside curated/
        calls: list[list[str]] = []
        original = refresher._run

        def spy(args, **kwargs):
            calls.append(list(args))
            return original(args, **kwargs)

        refresher._run = spy  # type: ignore[method-assign]
        self.assertFalse(refresher.poll_once())
        flat = [" ".join(c) for c in calls]
        self.assertTrue(any("--filter=blob:none" in c for c in flat))
        self.assertFalse(any(" checkout " in f" {c} " for c in flat), flat)   # no content download
        self.assertFalse(any(" init " in f" {c} " and "--vault" in c for c in flat), flat)  # no re-index
        self.assertEqual(refresher.serving_dir.stat().st_ino, first_inode)  # no swap
        self.assertEqual(json.loads(refresher.status_path.read_text())["revision"], refresher.applied_revision)
        # A later change inside the subdir still propagates.
        (self.work / "curated" / "c.md").write_text(self._note_text("# Curated v2"), encoding="utf-8")
        subprocess.run(["git", "-C", str(self.work), "commit", "--quiet", "-am", "v2"], check=True)
        subprocess.run(["git", "-C", str(self.work), "push", "--quiet", "origin", "main"], check=True)
        self.assertTrue(refresher.poll_once())
        self.assertIn("Curated v2", (refresher.serving_dir / "c.md").read_text())

    def _run_git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.work), *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    @staticmethod
    def _health_status(data_dir: Path) -> dict:
        """What the gateway's /health endpoint would report for this data dir."""
        with mock.patch.dict(os.environ, {"RETEX_DATA_DIR": str(data_dir)}):
            response = asyncio.run(gateway.health(None))  # type: ignore[arg-type]
        return json.loads(response.body)

    def test_lightweight_tag_ref_resolves_to_commit(self) -> None:
        head = self._run_git("rev-parse", "HEAD")
        self._run_git("tag", "v1.0")  # lightweight: advertises no peeled line
        self._run_git("push", "--quiet", "origin", "refs/tags/v1.0")
        refresher = self._refresher(RETEX_VAULT_REF="v1.0")
        self.assertEqual(refresher.remote_revision(), head)
        refresher.bootstrap_layout()
        self.assertTrue(refresher.poll_once())
        self.assertEqual(
            (refresher.serving_dir / "project.md").read_text(),
            self._note_text("# Safe project facts"),
        )

    def test_annotated_tag_prefers_peeled_commit(self) -> None:
        head = self._run_git("rev-parse", "HEAD")
        self._run_git("tag", "-a", "v2.0", "-m", "release two")
        self._run_git("push", "--quiet", "origin", "refs/tags/v2.0")
        tag_object = self._run_git("rev-parse", "refs/tags/v2.0")
        self.assertNotEqual(tag_object, head)
        refresher = self._refresher(RETEX_VAULT_REF="v2.0")
        # The peeled commit is what gets fetched and served, not the tag object id.
        self.assertEqual(refresher.remote_revision(), head)

    def test_health_recovers_after_transient_failure(self) -> None:
        refresher = self._refresher()
        refresher.bootstrap_layout()
        self.assertTrue(refresher.poll_once())
        self.assertEqual(self._health_status(refresher.data_dir)["status"], "ok")
        original = refresher.remote_revision

        def boom() -> str:
            raise RuntimeError("transient git failure")

        refresher.remote_revision = boom  # type: ignore[method-assign]
        self.assertFalse(refresher.poll_once())
        self.assertEqual(refresher.consecutive_failures, 1)
        degraded = self._health_status(refresher.data_dir)
        self.assertEqual(degraded["status"], "degraded")
        self.assertIn("last_error", degraded["vault_sync"])

        refresher.remote_revision = original  # type: ignore[method-assign]
        self.assertFalse(refresher.poll_once())  # same revision, no new commit
        recovered = self._health_status(refresher.data_dir)
        self.assertEqual(recovered["status"], "ok")
        self.assertNotIn("last_error", recovered["vault_sync"])
        self.assertEqual(refresher.consecutive_failures, 0)


class HostedFleetVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.config = self.root / "fleet.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_config(self, services: list[dict[str, object]]) -> None:
        self.config.write_text(
            json.dumps({"version": 1, "services": services}),
            encoding="utf-8",
        )
        self.config.chmod(0o600)

    def test_loads_private_config_with_environment_and_command_tokens(self) -> None:
        self.write_config(
            [
                {
                    "name": "alpha",
                    "url": "https://alpha.example/mcp",
                    "token_env": "ALPHA_TOKEN",
                },
                {
                    "name": "beta",
                    "url": "https://beta.example/mcp",
                    "token_command": ["secret-cli", "read", "beta"],
                    "token_json_key": "token",
                },
            ]
        )

        services = verify_fleet.load_config(self.config)

        self.assertEqual([service.name for service in services], ["alpha", "beta"])
        self.assertEqual(services[1].token_command, ("secret-cli", "read", "beta"))

    def test_rejects_literal_tokens_and_insecure_config_permissions(self) -> None:
        self.write_config(
            [{"name": "alpha", "url": "https://alpha.example/mcp", "token": "secret"}]
        )
        with self.assertRaises(ValueError):
            verify_fleet.load_config(self.config)

        self.write_config(
            [{"name": "alpha", "url": "https://user@alpha.example/mcp", "token_env": "TOKEN"}]
        )
        with self.assertRaises(ValueError):
            verify_fleet.load_config(self.config)

        self.write_config(
            [{"name": "alpha", "url": "https://alpha.example/mcp", "token_env": "TOKEN"}]
        )
        if os.name != "nt":
            self.config.chmod(0o644)
            with self.assertRaises(ValueError):
                verify_fleet.load_config(self.config)

    def test_resolves_tokens_without_persisting_or_printing_them(self) -> None:
        token = "a" * 32
        self.write_config(
            [
                {
                    "name": "alpha",
                    "url": "https://alpha.example/mcp",
                    "token_env": "ALPHA_TOKEN",
                },
                {
                    "name": "beta",
                    "url": "https://beta.example/mcp",
                    "token_command": ["secret-cli", "read"],
                    "token_json_key": "value",
                },
            ]
        )
        alpha, beta = verify_fleet.load_config(self.config)

        self.assertEqual(
            verify_fleet.resolve_token(alpha, {"ALPHA_TOKEN": token}, lambda _: ""),
            token,
        )
        self.assertEqual(
            verify_fleet.resolve_token(beta, {}, lambda _: json.dumps({"value": token})),
            token,
        )
        self.assertNotIn(token, repr(alpha))
        self.assertNotIn(token, repr(beta))

    def test_discovers_probe_title_and_filters_canary(self) -> None:
        self.write_config(
            [
                {"name": "alpha", "url": "https://alpha.example/mcp", "token_env": "A"},
                {"name": "beta", "url": "https://beta.example/mcp", "token_env": "B"},
            ]
        )
        services = verify_fleet.load_config(self.config)

        self.assertEqual(
            verify_fleet.first_note_title(
                {
                    "count": "2",
                    "notes": "First note\t/vault/first.md\nSecond note\t/vault/second.md",
                }
            ),
            "First note",
        )
        self.assertEqual(
            [service.name for service in verify_fleet.select_services(services, ["beta"])],
            ["beta"],
        )
        with self.assertRaises(ValueError):
            verify_fleet.first_note_title({"count": "0", "notes": ""})

    def test_parses_tool_json_and_rejects_non_json(self) -> None:
        self.assertEqual(verify_fleet.parse_tool_json('{"count": 1}'), {"count": 1})
        with self.assertRaises(ValueError):
            verify_fleet.parse_tool_json("not json")

    def test_bundled_docker_default_matches_cli_version(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        app_version = re.search(
            r'static let version = "([^"]+)"',
            (repository / "Sources/RetexCore/RetexVersion.swift").read_text(
                encoding="utf-8"
            ),
        )
        docker_version = re.search(
            r"^ARG RETEX_REF=v(.+)$",
            (repository / "deploy/readonly-mcp/Dockerfile").read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        self.assertIsNotNone(app_version)
        self.assertIsNotNone(docker_version)
        self.assertEqual(app_version.group(1), docker_version.group(1))


if __name__ == "__main__":
    unittest.main()


class ToolSurfaceTests(unittest.IsolatedAsyncioTestCase):
    """The proxy must expose exactly the verifier's read tools."""

    def test_gateway_and_verifier_agree(self) -> None:
        self.assertEqual(set(gateway.READ_TOOLS), verify_fleet.READ_TOOLS)

    async def test_proxy_hides_and_refuses_other_tools(self) -> None:
        binary = os.environ.get("RETEX_TEST_BIN")
        if not binary:
            self.skipTest("set RETEX_TEST_BIN to a retex binary to run the proxy test")
        from fastmcp import Client
        from fastmcp.exceptions import ToolError

        with tempfile.TemporaryDirectory() as vault:
            Path(vault, "note.md").write_text("---\nshareable: true\n---\n# Note\nhello\n")
            original = (gateway.RETEX_BIN, gateway.VAULT)
            gateway.RETEX_BIN, gateway.VAULT = binary, vault
            try:
                async with Client(gateway.build_proxy()) as client:
                    names = {tool.name for tool in await client.list_tools()}
                    self.assertEqual(names, set(gateway.READ_TOOLS))
                    with self.assertRaises(ToolError):
                        await client.call_tool("memory_recall", {"query": "hello"})
                    result = await client.call_tool("search_notes", {"query": "hello"})
                    self.assertIn("note.md", result.content[0].text)
            finally:
                gateway.RETEX_BIN, gateway.VAULT = original


class SyncServerTests(unittest.TestCase):
    """Protocol tests for deploy/sync-server/server.py over a real socket."""

    token = "t" * 32

    def setUp(self) -> None:
        if sync_server is None:
            self.skipTest("deploy/sync-server/server.py is not available")
        self.temporary = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.temporary.name)
        handler = sync_server.make_handler(str(self.data_dir), self.token)
        self.httpd = sync_server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=10)
        self.temporary.cleanup()

    def vault_path(self, name: str = "acme-vault") -> Path:
        return self.data_dir / f"{name}.retexenc"

    def request(self, method: str, path: str, *, headers: dict | None = None,
                body: bytes = b"", truncated: int | None = None) -> bytes:
        """Send one raw request and return the raw response.

        `truncated` sends only a prefix of `body` while the Content-Length header
        still announces the full length, reproducing a client that dies mid-upload.
        """
        payload = body if truncated is None else body[:truncated]
        lines = [
            f"{method} {path} HTTP/1.1",
            "Host: 127.0.0.1",
            f"Authorization: Bearer {self.token}",
        ]
        lines.extend(f"{name}: {value}" for name, value in (headers or {}).items())
        raw = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + payload
        received = []
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as sock:
            sock.sendall(raw)
            sock.shutdown(socket.SHUT_WR)
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                received.append(chunk)
        return b"".join(received)

    @staticmethod
    def status_of(response: bytes) -> int:
        return int(response.split(b"\r\n", 1)[0].split(b" ")[1])

    def test_truncated_put_is_rejected_and_blob_untouched(self) -> None:
        blob = sync_server.MAGIC + b"original ciphertext"
        self.vault_path().write_bytes(blob)
        replacement = sync_server.MAGIC + b"replacement ciphertext"
        response = self.request(
            "PUT",
            "/v1/vaults/acme-vault",
            headers={
                "Content-Length": str(len(replacement)),
                "If-Match": '"' + hashlib.sha256(blob).hexdigest() + '"',
            },
            body=replacement,
            truncated=len(replacement) - 4,
        )
        self.assertEqual(self.status_of(response), 400)
        self.assertIn(b"incomplete body", response)
        self.assertEqual(self.vault_path().read_bytes(), blob)
        # No temporary upload file and no partial blob survives the rejection.
        self.assertEqual(
            sorted(p.name for p in self.data_dir.iterdir()),
            ["acme-vault.retexenc"],
        )

    def test_complete_put_still_creates_and_updates(self) -> None:
        first = sync_server.MAGIC + b"first ciphertext"
        created = self.request(
            "PUT",
            "/v1/vaults/acme-vault",
            headers={"Content-Length": str(len(first)), "If-None-Match": "*"},
            body=first,
        )
        self.assertEqual(self.status_of(created), 201)
        self.assertEqual(self.vault_path().read_bytes(), first)
        second = sync_server.MAGIC + b"second ciphertext"
        updated = self.request(
            "PUT",
            "/v1/vaults/acme-vault",
            headers={
                "Content-Length": str(len(second)),
                "If-Match": '"' + hashlib.sha256(first).hexdigest() + '"',
            },
            body=second,
        )
        self.assertEqual(self.status_of(updated), 200)
        self.assertEqual(self.vault_path().read_bytes(), second)

    def test_negative_content_length_is_rejected(self) -> None:
        response = self.request(
            "PUT", "/v1/vaults/acme-vault", headers={"Content-Length": "-12"}
        )
        self.assertEqual(self.status_of(response), 400)
        self.assertEqual(list(self.data_dir.iterdir()), [])

    def test_preconditions_reject_stale_and_missing_vaults(self) -> None:
        blob = sync_server.MAGIC + b"current ciphertext"
        self.vault_path().write_bytes(blob)
        body = sync_server.MAGIC + b"next ciphertext"
        stale = self.request(
            "PUT",
            "/v1/vaults/acme-vault",
            headers={"Content-Length": str(len(body)), "If-Match": '"' + "0" * 64 + '"'},
            body=body,
        )
        self.assertEqual(self.status_of(stale), 412)
        self.assertEqual(self.vault_path().read_bytes(), blob)
        missing = self.request(
            "PUT",
            "/v1/vaults/absent-vault",
            headers={"Content-Length": str(len(body)), "If-Match": "*"},
            body=body,
        )
        self.assertEqual(self.status_of(missing), 412)
        self.assertFalse((self.data_dir / "absent-vault.retexenc").exists())
        wildcard = self.request(
            "PUT",
            "/v1/vaults/acme-vault",
            headers={"Content-Length": str(len(body)), "If-Match": "*"},
            body=body,
        )
        self.assertEqual(self.status_of(wildcard), 200)
        self.assertEqual(self.vault_path().read_bytes(), body)


class DeploymentHardeningTests(unittest.TestCase):
    def test_healthcheck_never_puts_the_token_on_a_command_line(self) -> None:
        text = (Path(__file__).resolve().parent / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("HEALTHCHECK", text)
        # A bearer token in the HEALTHCHECK command line is visible in
        # /proc/<pid>/cmdline for as long as it runs, and rotation-only
        # deployments export no legacy RETEX_MCP_TOKEN at all.
        self.assertNotIn("Authorization: Bearer $", text)
        healthcheck = text.split("HEALTHCHECK", 1)[1].split("CMD [", 1)[0]
        self.assertIn("python3 -c", healthcheck)
        self.assertIn("RETEX_MCP_TOKENS_JSON", healthcheck)
        self.assertIn("/health", healthcheck)
        self.assertNotIn("curl", healthcheck)

