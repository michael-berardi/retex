# Real-Time Vault Sync for Hosted Retex Serving Layers

Status: implemented in `deploy/readonly-mcp/` (gateway.py + refresh_vault.py)
Applies to: any GitHub-hosted Retex vault served by the readonly MCP gateway
(Felix's Railway `retex-felix` service, future hosted vault services).

## Problem

Hosted serving layers baked the vault into the Docker image at build time
(`COPY knowledge /data/vault`). Content was therefore frozen at whatever
moment someone last ran a manual rebuild — Felix answered from stale memory
even though the canonical Obsidian vault on this machine syncs to GitHub
within seconds via fswatch → `~/bin/sync_vault.sh` (LaunchAgent
`com.libertydesignstudio.obsidian.sync`).

## Design chosen: service-side HEAD polling + rename-based swap

The gateway process runs a background poller (`refresh_vault.py`):

1. **Cheap change detection** — every `RETEX_VAULT_POLL_SECONDS` (default 45,
   minimum 5), run one `git ls-remote <repo> <ref>` round trip (a few hundred
   bytes, no clone) and compare the remote SHA against the revision currently
   served.
2. **On change** — shallow-clone (`--depth 1 --single-branch --branch <ref>`),
   take `RETEX_VAULT_SUBDIR` if set, delete `.git`, run the fail-closed
   validator (`validate_vault.validate`: shareable frontmatter required,
   Markdown only, no symlinks/hidden paths, secret-pattern scan).
3. **Publish** — copy the validated tree to `$RETEX_DATA_DIR/volumes/<sha>/`,
   run idempotent `retex init` so MCP tools index it, make everything
   read-only except `.retex/` (Retex keeps per-note state there and must be
   able to write), then swap it into the serving path with two renames
   (retire old, rename new in). The serving path must be a **real
   directory**: measured on this fleet, Retex returns zero results when the
   vault root is a symlink. The window where the serving path does not exist
   is a single `rename(2)` wide; a request landing exactly inside it fails
   once and succeeds on retry.
4. **Zero-restart visibility** — the Retex binary re-scans the vault
   directory on every MCP request (no persistent index), so in-flight Felix
   sessions see new content on their next tool call.

Failure policy: validation or git failures never touch the currently-served
revision. Errors are written to `vault-sync.json` (surfaced as `"status":
"degraded"` on `/health`) and retried with bounded backoff (poll interval ×
consecutive failures, capped at 8×). A fresh good commit resets the backoff.

### Why not the alternatives

| Option | Verdict |
| --- | --- |
| Post-commit webhook from `sync_vault.sh` → service refresh endpoint | Rejected: requires an authenticated mutation endpoint on each public service plus coupling to one machine's sync script; commits from any other writer would be missed. Polling covers all writers for free. |
| Push events via GitHub webhooks | Same inbound-endpoint problem; also needs a public URL per vault and replay/secret management. |
| GitHub Actions | Banned fleet-wide by standing rule. |
| Keep build-time baking | Previous behavior; staleness is unbounded (until a manual rebuild). |

Polling trades up to ~45 s of latency for zero new attack surface, zero
inbound ports, no secrets in repos, and identical behavior regardless of who
pushed. This matches the requirement of seconds-to-a-minute propagation; set
`RETEX_VAULT_POLL_SECONDS=15` if a tighter window is ever needed (cost is one
HTTPS round trip per interval per service). Measured end-to-end latency on
this fleet: commit push → visible to MCP search in 6 s at a 10 s interval.

## Configuration

Environment variables (set per Railway service; never committed):

| Variable | Default | Meaning |
| --- | --- | --- |
| `RETEX_VAULT_REPO` | *(unset = refresh disabled)* | HTTPS URL of the vault repo |
| `RETEX_VAULT_REF` | `main` | Branch or tag to serve |
| `RETEX_VAULT_SUBDIR` | repo root | Curated subdirectory to serve |
| `RETEX_VAULT_POLL_SECONDS` | `45` | Polling interval |
| `RETEX_VAULT_TOKEN` | *(none)* | Read-only fine-grained GitHub PAT |

Secret handling:

- The token is supplied to git through a private `GIT_ASKPASS` helper whose
  script only echoes the inherited environment variable — the credential is
  never embedded in URLs, argv, logs, or files inside the image.
- Git stderr is never logged (it can echo auth context); failures log only
  the failing git subcommand and exit code.
- Scope the token to *Contents: Read* on the single vault repository. It
  grants strictly read access — no capability beyond what the serving layer's
  job already implies — and lives only in the platform secret store
  (Railway variables), like `RETEX_MCP_TOKEN` today.
- The vault repo itself gains nothing sensitive: no hooks, no tokens, no
  config changes are required there.

Runtime layout under `$RETEX_DATA_DIR` (default `/data`):

```
/data/volumes/<sha>/   staged validated revision (transient)
/data/vault            real serving directory, swapped by rename
/data/vault-sync.json  {revision, ref, updated_at, last_error?} → /health
```

If the image baked a seed vault, it keeps serving as `/data/vault` until the
first successful refresh replaces it — a repo outage at boot degrades
nothing.

## Rollout notes (fleet)

- `deploy/readonly-mcp/gateway.py`, `validate_vault.py`,
  `refresh_vault.py` are consumed by downstream Dockerfiles **from the retex
  repo at the pinned `RETEX_REF`** (e.g. overseer-telegram's
  `deploy/retex-service/Dockerfile`). Services pick this up when their pin is
  bumped past the commit adding these files and they are redeployed.
- Per the Retex vault upgrade standard: canary one service first, verify
  auth, invalid-token, path-escape, tool-surface, write-denial, then roll out.
- Verify after deploy: `GET /health` shows `vault_sync.revision`; push a test
  commit and confirm the revision changes within one poll interval; confirm
  an invalid commit leaves the revision unchanged with `status: degraded`.

## Local verification

`deploy/readonly-mcp/test_helper.py::VaultRefresherTests` exercises the full
loop offline against a local bare remote: apply, no-op on unchanged HEAD,
second-commit propagation with stale-volume pruning, fail-closed rejection of
non-shareable content while continuing to serve the previous revision, and
subdir-only serving.
