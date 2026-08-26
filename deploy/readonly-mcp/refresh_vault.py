"""Near-real-time vault refresh for hosted Retex serving layers.

Polls a GitHub-hosted vault with a cheap `git ls-remote` HEAD comparison,
and on change performs: shallow clone -> fail-closed validation -> atomic
rename-based swap of the serving directory. The Retex binary re-scans the vault
on every request, so refreshed content is visible to in-flight sessions
without restarting the MCP subprocess.

Configuration (environment):
  RETEX_VAULT_REPO           HTTPS URL of the vault repository. Unset or empty
                             disables polling; the baked image vault keeps serving.
  RETEX_VAULT_REF            Branch or tag to serve (default: main).
  RETEX_VAULT_SUBDIR         Subdirectory of the repo to serve (default: repo root).
  RETEX_VAULT_POLL_SECONDS   Seconds between HEAD comparisons (default: 45).
  RETEX_VAULT_TOKEN          Optional read-only token. Supplied to git through a
                             private GIT_ASKPASS helper; never logged, never
                             embedded in URLs, never visible in process arguments.
  RETEX_DATA_DIR             Runtime data root (default: /data).

Runtime layout under RETEX_DATA_DIR:
  volumes/<revision>/   Staged, validated revision (transient; renamed into place).
  vault                 Real serving directory (Retex does not scan a symlinked root).
  vault-sync.json       Status document surfaced on /health.

Failure policy: the previously served revision keeps serving; errors are
recorded in the status document and retried with bounded backoff.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from validate_vault import validate  # noqa: E402

DEFAULT_POLL_SECONDS = 45
MAX_BACKOFF_MULTIPLIER = 8
GIT_TIMEOUT_SECONDS = 120


def log(message: str) -> None:
    print(f"[vault-refresh] {message}", flush=True)


class VaultRefresher:
    def __init__(self, environ: dict[str, str] | None = None) -> None:
        env = dict(os.environ if environ is None else environ)
        self.env = env
        self.repo = env.get("RETEX_VAULT_REPO", "").strip()
        self.ref = env.get("RETEX_VAULT_REF", "main").strip() or "main"
        self.subdir = env.get("RETEX_VAULT_SUBDIR", "").strip().strip("/")
        try:
            self.poll_seconds = max(5, int(env.get("RETEX_VAULT_POLL_SECONDS", str(DEFAULT_POLL_SECONDS))))
        except ValueError:
            self.poll_seconds = DEFAULT_POLL_SECONDS
        self.data_dir = Path(env.get("RETEX_DATA_DIR", "/data"))
        self.volumes_dir = self.data_dir / "volumes"
        self.serving_dir = self.data_dir / "vault"  # real directory, never a symlink
        self.status_path = self.data_dir / "vault-sync.json"
        self.applied_revision: str | None = None
        self.consecutive_failures = 0
        self._askpass_dir: str | None = None

    # -- git plumbing ---------------------------------------------------------

    def git_env(self) -> dict[str, str]:
        """Environment for git/retex subprocesses; token only via askpass."""
        git_env = {**os.environ, **self.env}
        git_env["GIT_TERMINAL_PROMPT"] = "0"
        git_env["GIT_HTTP_LOW_SPEED_LIMIT"] = "1024"
        git_env["GIT_HTTP_LOW_SPEED_TIME"] = "30"
        if self.env.get("RETEX_VAULT_TOKEN"):
            if self._askpass_dir is None:
                self._askpass_dir = tempfile.mkdtemp(prefix="retex-askpass-")
                helper = Path(self._askpass_dir) / "askpass.sh"
                # The secret lives only in the inherited environment; the
                # helper script itself contains no credential material.
                helper.write_text(
                    "#!/bin/sh\nprintf '%s\\n' \"$RETEX_VAULT_TOKEN\"\n",
                    encoding="utf-8",
                )
                helper.chmod(0o700)
            git_env["GIT_ASKPASS"] = str(Path(self._askpass_dir) / "askpass.sh")
            git_env["SSH_ASKPASS_REQUIRE"] = "force"
        return git_env

    def _run(self, args: list[str], **kwargs):
        return subprocess.run(
            args, capture_output=True, text=True,
            timeout=GIT_TIMEOUT_SECONDS, env=self.git_env(), check=True, **kwargs,
        )

    def remote_revision(self) -> str:
        result = self._run(["git", "ls-remote", self.repo, f"refs/heads/{self.ref}", f"refs/tags/{self.ref}"])
        for line in result.stdout.splitlines():
            sha, _, name = line.partition("\t")
            if name.strip() in (f"refs/heads/{self.ref}", f"refs/tags/{self.ref}^{{}}"):
                return sha.strip()
        raise RuntimeError(f"ref {self.ref!r} not found on remote")

    def fetch_revision(self, revision: str) -> tuple[Path, Path]:
        """Shallow-clone the revision; returns (stage_root, content_dir)."""
        stage = Path(tempfile.mkdtemp(prefix="retex-fetch-"))
        try:
            self._run([
                "git", "clone", "--quiet", "--depth", "1", "--single-branch",
                "--branch", self.ref, "--", self.repo, str(stage / "repo"),
            ])
            content = stage / "repo"
            if self.subdir:
                content = content / self.subdir
            if not content.is_dir():
                raise RuntimeError(f"subdir {self.subdir!r} missing at {self.ref}")
            shutil.rmtree(stage / "repo" / ".git", ignore_errors=True)
            return stage, content
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise

    # -- layout and publish ---------------------------------------------------

    def bootstrap_layout(self) -> None:
        self.volumes_dir.mkdir(parents=True, exist_ok=True)
        # A baked build-time vault at serving_dir keeps serving as the seed
        # until the first successful refresh replaces it.

    def _publish(self, target: Path) -> Path | None:
        """Swap the staged volume into the serving path via two renames.

        Retex does not scan a vault whose root is a symlink (measured: zero
        results through a symlinked root), so /data/vault stays a real
        directory. The retired revision is moved aside first; the window in
        which the serving path does not exist is a single rename wide.
        """
        retired: Path | None = None
        if self.serving_dir.exists():
            retired = self.volumes_dir / f"retired-{target.name[:12]}"
            if retired.exists():
                shutil.rmtree(retired)
            os.replace(self.serving_dir, retired)
        os.replace(target, self.serving_dir)
        return retired

    def _write_status(self, error: str | None = None) -> None:
        status = {
            "repo_configured": bool(self.repo),
            "ref": self.ref,
            "revision": self.applied_revision,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        if error:
            status["last_error"] = error
            status["errored_at"] = status["updated_at"]
        tmp = self.status_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(status), encoding="utf-8")
        os.replace(tmp, self.status_path)

    def apply_revision(self, revision: str) -> None:
        stage, content = self.fetch_revision(revision)
        try:
            validate(content)
            target = self.volumes_dir / revision
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(content, target)
            # Initialize Retex vault-local state (idempotent) so MCP tools
            # index this revision; must precede the read-only lockdown.
            self._run([
                self.env.get("RETEX_BIN", "retex"),
                "init", "--vault", str(target),
            ])
            state_dir = target / ".retex"
            for path in sorted(target.rglob("*"), reverse=True):
                if path == state_dir or state_dir in path.parents:
                    continue  # Retex keeps per-note state here; must stay writable
                if path.is_dir():
                    path.chmod(path.stat().st_mode | 0o700)
                else:
                    path.chmod(path.stat().st_mode & ~0o222)  # content: read-only
            retired = self._publish(target)
            if retired and retired != self.serving_dir:
                shutil.rmtree(retired, ignore_errors=True)
            self.applied_revision = revision
            for stale in self.volumes_dir.iterdir():
                if stale.is_dir() and stale.name not in (revision, "seed"):
                    shutil.rmtree(stale, ignore_errors=True)
            self._write_status()
            log(f"serving revision {revision[:12]}")
        finally:
            shutil.rmtree(stage, ignore_errors=True)


    def poll_once(self) -> bool:
        """Return True when a revision was applied, False when unchanged."""
        if not self.repo:
            return False
        try:
            revision = self.remote_revision()
            if revision == self.applied_revision:
                self.consecutive_failures = 0
                return False
            self.apply_revision(revision)
            self.consecutive_failures = 0
            return True
        except subprocess.CalledProcessError as exc:
            # Never include stderr: git error output can embed auth context.
            detail = f"git {exc.cmd[0]} failed with code {exc.returncode}"
            self._record_failure(detail)
            return False
        except Exception as exc:  # noqa: BLE001 - keep serving, record, retry
            self._record_failure(f"{type(exc).__name__}: {exc}")
            return False

    def _record_failure(self, detail: str) -> None:
        self.consecutive_failures += 1
        self._write_status(error=detail)
        log(f"refresh failed, still serving {str(self.applied_revision)[:12]}: {detail}")

    def run_forever(self) -> None:
        if not self.repo:
            log("RETEX_VAULT_REPO unset; refresh disabled, serving baked vault")
            return
        log(f"polling {self.repo} ref={self.ref!r} subdir={self.subdir!r} every {self.poll_seconds}s")
        while True:
            self.poll_once()
            delay = self.poll_seconds * min(self.consecutive_failures + 1, MAX_BACKOFF_MULTIPLIER) \
                if self.consecutive_failures else self.poll_seconds
            time.sleep(max(1, delay))


def start_background() -> VaultRefresher | None:
    """Start the poller daemon thread; returns None when disabled."""
    refresher = VaultRefresher()
    if not refresher.repo:
        return None

    def _bootstrap_and_run() -> None:
        try:
            refresher.bootstrap_layout()
            refresher.poll_once()  # immediate first sync at boot
        except Exception as exc:  # noqa: BLE001
            log(f"bootstrap failed: {type(exc).__name__}: {exc}")
        refresher.run_forever()

    threading.Thread(target=_bootstrap_and_run, name="vault-refresh", daemon=True).start()
    return refresher


def load_status(data_dir: str | os.PathLike[str] = "/data") -> dict | None:
    try:
        return json.loads((Path(data_dir) / "vault-sync.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


if __name__ == "__main__":
    VaultRefresher().run_forever()
