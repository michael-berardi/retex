from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import gateway
import refresh_vault
import validate_vault
import verify_fleet


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
        subprocess.run(["git", "init", "--quiet", "--bare", str(self.remote)], check=True)
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

    def test_bundled_docker_default_matches_cli_version(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        app_version = re.search(
            r'static let version = "([^"]+)"',
            (repository / "Sources/RetexCLI/AppVersion.swift").read_text(
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
