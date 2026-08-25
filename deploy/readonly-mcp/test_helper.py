from __future__ import annotations


import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import gateway
import refresh_vault
import validate_vault


class TokenTests(unittest.TestCase):
    def test_loads_legacy_and_named_tokens(self) -> None:
        legacy = "a" * 32
        named = "b" * 32
        self.assertEqual(
            gateway.load_tokens(
                {
                    "RETEX_MCP_TOKEN": legacy,
                    "RETEX_MCP_TOKENS_JSON": '{"felix": "' + named + '"}',
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
        served = (Path(os.readlink(refresher.serving_link)))
        self.assertTrue(served.is_relative_to("volumes"))
        self.assertEqual((refresher.serving_link / "project.md").read_text(), self._note_text("# Safe project facts"))
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
        self.assertIn("# Updated facts", (refresher.serving_link / "project.md").read_text())
        remaining = [p.name for p in refresher.volumes_dir.iterdir() if p.is_dir()]
        self.assertEqual(remaining, [second_status["revision"]])

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
        self.assertIn("# Safe project facts", (refresher.serving_link / "project.md").read_text())
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
        names = sorted(p.name for p in refresher.serving_link.iterdir())
        self.assertEqual(names, ["c.md"])




if __name__ == "__main__":
    unittest.main()
