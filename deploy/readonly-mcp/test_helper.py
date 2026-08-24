from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import gateway
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

    def test_authorization_requires_exact_bearer_token(self) -> None:
        original = gateway.TOKENS
        gateway.TOKENS = ("a" * 32, "b" * 32)
        try:
            self.assertTrue(gateway.authorized(b"Bearer " + b"b" * 32))
            self.assertFalse(gateway.authorized(b"Bearer " + b"c" * 32))
            self.assertFalse(gateway.authorized(b"Basic " + b"b" * 32))
        finally:
            gateway.TOKENS = original


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


if __name__ == "__main__":
    unittest.main()
