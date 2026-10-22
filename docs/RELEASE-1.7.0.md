# Retex 1.7.0 — encrypted vault sync

`retex sync push|pull|status` moves a vault between machines through a server
that stores only ciphertext. The vault is archived and encrypted locally
(`RETEXENC1`, PBKDF2 + AES-GCM); the server never sees the passphrase or notes.

- Optimistic concurrency: stale pushes are refused as conflicts.
- Pulls validate everything first, mirror remote deletions, and refuse to
  overwrite unsynced local changes without `--force`.
- https required (http only for localhost); token from the environment.
- Reference server: `deploy/sync-server/server.py` (stdlib only).
