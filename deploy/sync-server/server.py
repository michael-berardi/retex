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


def make_handler(data_dir: str, token: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "retex-sync/1"

        def log_message(self, fmt, *args):  # no tokens/bodies; method+path+status only
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

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
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._err(411, "Content-Length required")
            if length <= len(MAGIC) or length > MAX_BYTES:
                return self._err(413, "body size out of range")
            body = self.rfile.read(length)
            if not body.startswith(MAGIC):
                return self._err(400, "body is not a RETEXENC1 encrypted export")
            if_match = (self.headers.get("If-Match") or "").strip('"')
            if_none = self.headers.get("If-None-Match")
            with LOCK:
                current = self._current(path)
                digest = hashlib.sha256(current).hexdigest() if current is not None else None
                if if_none == "*" and current is not None:
                    return self._err(412, "vault already exists; pull first")
                if if_match and if_match != digest:
                    return self._err(412, "revision is stale; pull first")
                fd, tmp = tempfile.mkstemp(dir=data_dir, prefix=".tmp-")
                try:
                    with os.fdopen(fd, "wb") as f:
                        f.write(body)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(tmp, path)
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
