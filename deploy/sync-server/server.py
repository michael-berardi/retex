#!/usr/bin/env python3
"""Retex encrypted sync server (reference implementation, stdlib only).

Stores opaque RETEXENC1 blobs; it never sees a passphrase or plaintext.
  GET/HEAD/PUT /v1/vaults/<id>   Authorization: Bearer <RETEX_SYNC_TOKEN>
PUT is optimistic: If-Match "<sha256>" for updates, If-None-Match: * for
creation; a stale precondition returns 412. ETag is the blob's SHA-256.
Run behind TLS (a reverse proxy or Cloudflare tunnel); the client refuses
plain http except for localhost.
"""
import hashlib
import hmac
import os
import re
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAGIC = b"RETEXENC1"
MAX_BYTES = int(os.environ.get("RETEX_SYNC_MAX_BYTES", str(1024 * 1024 * 1024 + 4096)))
ID_RE = re.compile(r"^/v1/vaults/([A-Za-z0-9._-]{1,64})$")
LOCK = threading.Lock()
READ_CHUNK = 65536


def fsync_dir(path):
    """Flush a directory entry so a completed rename survives a crash."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def make_handler(data_dir: str, token: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "retex-sync/1"

        def log_message(self, fmt, *args):  # no client IP, tokens or bodies
            sys.stderr.write("%s\n" % (fmt % args,))

        def _send(self, code, body=b"", etag=None, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            if etag:
                self.send_header("ETag", '"%s"' % etag)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _err(self, code, message):
            import json
            self._send(code, json.dumps({"error": message}).encode())

        def _target(self):
            supplied = self.headers.get("Authorization", "")
            expected = "Bearer " + token
            if not hmac.compare_digest(supplied.encode(), expected.encode()):
                self._err(401, "invalid or missing bearer token")
                return None
            m = ID_RE.match(self.path)
            if not m or m.group(1) in (".", ".."):
                self._err(404, "unknown route")
                return None
            return os.path.join(data_dir, m.group(1) + ".retexenc")

        def _current(self, path):
            try:
                with open(path, "rb") as f:
                    return f.read()
            except FileNotFoundError:
                return None

        def _read_exact(self, length):
            """Read exactly `length` body bytes; None when the body is truncated."""
            chunks = []
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, READ_CHUNK))
                if not chunk:
                    return None
                chunks.append(chunk)
                remaining -= len(chunk)
            return b"".join(chunks)

        def _etags(self, name):
            """Entity tags offered by the client; `*` is preserved verbatim."""
            tags = set()
            for raw in self.headers.get_all(name) or []:
                for part in raw.split(","):
                    tag = part.strip()
                    if not tag:
                        continue
                    if tag == "*":
                        tags.add("*")
                        continue
                    if tag.startswith("W/"):
                        tag = tag[2:].strip()
                    tags.add(tag.strip('"').strip())
            return tags

        def do_GET(self):
            path = self._target()
            if path is None:
                return
            blob = self._current(path)
            if blob is None:
                return self._err(404, "vault not found")
            self._send(200, blob, hashlib.sha256(blob).hexdigest(), "application/octet-stream")

        def do_HEAD(self):
            path = self._target()
            if path is None:
                return
            blob = self._current(path)
            if blob is None:
                return self._send(404)
            self.send_response(200)
            self.send_header("Content-Length", str(len(blob)))
            self.send_header("ETag", '"%s"' % hashlib.sha256(blob).hexdigest())
            self.end_headers()

        def do_PUT(self):
            path = self._target()
            if path is None:
                return
            raw_length = self.headers.get("Content-Length")
            if raw_length is None or not raw_length.strip():
                return self._err(411, "Content-Length required")
            try:
                length = int(raw_length.strip())
            except ValueError:
                return self._err(411, "Content-Length required")
            if length < 0:
                return self._err(400, "invalid Content-Length")
            if length <= len(MAGIC) or length > MAX_BYTES:
                return self._err(413, "body size out of range")
            # A short read means the client vanished mid-upload; reject before the
            # lock and before any temporary file exists so a truncated export can
            # never replace a good vault.
            body = self._read_exact(length)
            if body is None or len(body) != length:
                return self._err(400, "incomplete body")
            if not body.startswith(MAGIC):
                return self._err(400, "body is not a RETEXENC1 encrypted export")
            if_match = self._etags("If-Match")
            if_none = self._etags("If-None-Match")
            with LOCK:
                current = self._current(path)
                digest = hashlib.sha256(current).hexdigest() if current is not None else None
                if "*" in if_none and current is not None:
                    return self._err(412, "vault already exists; pull first")
                if digest is not None and digest in if_none:
                    return self._err(412, "vault is unchanged since the offered revision")
                if if_match:
                    matched = ("*" in if_match and current is not None) or (
                        digest is not None and digest in if_match
                    )
                    if not matched:
                        return self._err(412, "revision is stale; pull first")
                fd, tmp = tempfile.mkstemp(dir=data_dir, prefix=".tmp-")
                try:
                    with os.fdopen(fd, "wb") as f:
                        f.write(body)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(tmp, path)
                    # Durability: the rename itself must reach the parent directory
                    # entry, otherwise a crash can lose a fully acknowledged PUT.
                    fsync_dir(data_dir)
                except BaseException:
                    if os.path.exists(tmp):
                        os.unlink(tmp)
                    raise
            self._send(201 if current is None else 200, b"{}", hashlib.sha256(body).hexdigest())

    return Handler


def main():
    token = os.environ.get("RETEX_SYNC_TOKEN", "")
    if len(token) < 24:
        sys.exit("RETEX_SYNC_TOKEN must be set to at least 24 characters")
    data_dir = os.environ.get("RETEX_SYNC_DIR", "./sync-data")
    os.makedirs(data_dir, mode=0o700, exist_ok=True)
    host = os.environ.get("RETEX_SYNC_HOST", "127.0.0.1")
    port = int(os.environ.get("RETEX_SYNC_PORT", "8787"))
    ThreadingHTTPServer((host, port), make_handler(data_dir, token)).serve_forever()


if __name__ == "__main__":
    main()
