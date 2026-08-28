# Real-Time Vault Sync for Hosted Retex Serving Layers

Status: implemented in `deploy/readonly-mcp/` (gateway.py + refresh_vault.py)
Applies to: any Git-hosted Retex vault served by the read-only MCP gateway.

## Problem

Hosted serving layers often bake a vault into a container image at build time.
That freezes content until another image is built even when the canonical vault
keeps changing. The serving layer needs bounded refresh latency without adding
a public mutation endpoint or granting write access to the source repository.

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
   directory** so path confinement and atomic publication remain explicit.
   The window where the serving path does not exist is one `rename(2)` wide;
   a request landing exactly inside it fails once and succeeds on retry.
4. **Zero-restart visibility** — Retex re-scans the vault directory on each
   MCP request, so active sessions see the new revision on their next tool call.

Failure policy: validation or git failures never touch the currently-served
revision. Errors are written to `vault-sync.json` (surfaced as `"status":
"degraded"` on `/health`) and retried with bounded backoff (poll interval ×
consecutive failures, capped at 8×). A fresh good commit resets the backoff.

### Why not the alternatives

| Option | Verdict |
| --- | --- |
| Polling trigger pushed by one workstation | Rejected: couples refresh to one writer and misses changes from every other writer. |
| Git-provider webhooks | Rejected by default: adds a public mutation endpoint, replay protection, and another secret boundary. |
| CI-driven deployment | Rejected by default: couples content freshness to image builds and CI availability. |
| Keep build-time baking | Staleness remains unbounded until a manual rebuild. |

Polling trades up to ~45 s of latency for zero new attack surface, zero
inbound ports, no secrets in repos, and identical behavior regardless of who
pushed. This supports seconds-to-a-minute propagation; lower
`RETEX_VAULT_POLL_SECONDS` only when the extra Git request rate is acceptable.

## Configuration

Environment variables (set in the hosting platform secret/config store; never committed):

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
  (hosting-platform secret variables), alongside `RETEX_MCP_TOKEN`.
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

## Deployment notes

- Downstream images should pin an immutable Retex release or commit through
  `RETEX_REF`; refresh behavior changes only after an explicit image update.
- Canary one service first; verify authentication, invalid-token denial,
  path confinement, tool surface, and write denial before wider rollout.
- Verify after deploy: `GET /health` shows `vault_sync.revision`; push a test
  commit and confirm the revision changes within one poll interval; confirm
  an invalid commit leaves the revision unchanged with `status: degraded`.

## Local verification

`deploy/readonly-mcp/test_helper.py::VaultRefresherTests` exercises the full
loop offline against a local bare remote: apply, no-op on unchanged HEAD,
second-commit propagation with stale-volume pruning, fail-closed rejection of
non-shareable content while continuing to serve the previous revision, and
subdir-only serving.
