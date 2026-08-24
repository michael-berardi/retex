"""Fail-closed validation for knowledge copied into a hosted Retex service."""

from __future__ import annotations

import re
import sys
from pathlib import Path

MAX_NOTE_BYTES = 512 * 1024
SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    "Stripe live secret": re.compile(r"\b[rs]k_live_[A-Za-z0-9]{16,}\b"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "Google API key": re.compile(r"\bAIza[A-Za-z0-9_-]{30,}\b"),
    "Slack token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "secret assignment": re.compile(
        r"(?im)^\s*(?:api[_-]?key|client[_-]?secret|password|private[_-]?key|secret|token)"
        r"\s*[:=]\s*[\"']?(?!<|\$\{|example\b|replace\b|your[_-])[^\s\"']{16,}"
    ),
}


def frontmatter_is_shareable(text: str) -> bool:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return False
    try:
        end = next(index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---")
    except StopIteration:
        return False
    return any(re.fullmatch(r"(?i)shareable\s*:\s*true\s*", line) for line in lines[1:end])


def validate(root: Path) -> int:
    if not root.is_dir() or root.is_symlink():
        raise ValueError("knowledge root must be a real directory")

    count = 0
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if path.is_symlink():
            raise ValueError(f"symlinks are forbidden: {relative}")
        if any(part.startswith(".") for part in relative.parts):
            raise ValueError(f"hidden paths are forbidden: {relative}")
        if path.is_dir():
            continue
        if not path.is_file() or path.suffix.lower() != ".md":
            raise ValueError(f"only Markdown notes are allowed: {relative}")
        if path.stat().st_size > MAX_NOTE_BYTES:
            raise ValueError(f"note exceeds {MAX_NOTE_BYTES} bytes: {relative}")

        text = path.read_text(encoding="utf-8")
        if "\x00" in text:
            raise ValueError(f"NUL byte is forbidden: {relative}")
        if not frontmatter_is_shareable(text):
            raise ValueError(f"note must opt in with frontmatter shareable: true: {relative}")
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                raise ValueError(f"possible {label} in {relative}")
        count += 1

    if count == 0:
        raise ValueError("knowledge vault must contain at least one shareable Markdown note")
    return count


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "knowledge")
    try:
        count = validate(root)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"Retex knowledge validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(f"Validated {count} shareable Retex knowledge note(s)")


if __name__ == "__main__":
    main()
