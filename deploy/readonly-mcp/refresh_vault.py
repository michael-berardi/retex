"""Near-real-time vault refresh for hosted Retex serving layers.

Polls a GitHub-hosted vault with a cheap `git ls-remote` HEAD comparison,
and on change performs: shallow clone -> fail-closed validation -> atomic
symlink swap of the serving directory. The Retex binary re-scans the vault
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
  volumes/<revision>/   Validated, read-only content for one revision.
  vault                 Symlink -> volumes/<revision>, swapped atomically.
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
        self.serving_link = self.data_dir / "vault"
        self.status_path = self.data_dir / "vault-sync.json"
        self.applied_revision: str | None = None
        self.consecutive_failures = 0

    # -- git plumbing ---------------------------------------------------------

    def git_env(self) -> dict[str, str]:
        """Environment for git subprocesses; auth token only via askpass."""
        git_env = dict(self.env)
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

    # -- layout and swap ------------------------------------------------------

    def bootstrap_layout(self) -> None:
        self.volumes_dir.mkdir(parents=True, exist_ok=True)
        if not self.serving_link.is_symlink() and self.serving_link.exists():
            # Baked build-time vault becomes the seed volume until first refresh.
            seed = self.volumes_dir / "seed"
            if not seed.exists():
                self.serving_link.rename(seed)
            os.symlink(os.path.relpath(seed, self.data_dir), self.serving_link)

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

    def _prune_volumes(self, keep: str) -> None:
        for path in self.volumes_dir.iterdir():
            if path.is_dir() and path.name not in (keep, "seed"):
                shutil.rmtree(path, ignore_errors=True)

    def apply_revision(self, revision: str) -> None:
        stage, content = self.fetch_revision(revision)
        try:
            validate(content)
            target = self.volumes_dir / revision
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(content, target)
            for path in sorted(target.rglob("*"), reverse=True):
                path.chmod(path.stat().st_mode & ~0o222)  # best-effort read-only
            new_link = self.data_dir / f".vault.{revision}.link"
            if new_link.is_symlink() or new_link.exists():
                new_link.unlink()
            os.symlink(f"volumes/{revision}", new_link)
            os.replace(new_link, self.serving_link)  # atomic swap
            previous, self.applied_revision = self.applied_revision, revision
            self._prune_volumes(revision)
            self._write_status()
            log(f"serving revision {revision[:12]} (previous: {(previous or 'none')[:12]})")
        finally:
            shutil.rmtree(stage, ignore_errors=True)

    # -- loop -----------------------------------------------------------------

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
