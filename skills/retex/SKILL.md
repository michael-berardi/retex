---
name: retex
description: >
  Use when an agent needs to search, read, count, validate, organize, or safely
  update a Retex Markdown vault through the Retex CLI or MCP server. Prefer this
  structured interface over recursive file discovery or editor-specific APIs.
category: knowledge
version: 1.1.0
author: Retex contributors
tags: [retex, markdown, vault, knowledge, mcp, cli]
trigger_keywords: [retex, markdown vault, knowledge vault, agent memory, kanban]
---

# Retex agent workflow

Retex is a local-first Markdown vault engine with a machine-readable CLI and an
MCP server. Markdown stays authoritative. Retex supplies deterministic search,
structured records, boards, health checks, undo, and explicit mutations without
requiring an editor, account, remote database, or proprietary file format.

## Resolve the binary and vault

Use `RETEX_BIN` when configured; otherwise use `retex` from `PATH`. Use
`RETEX_VAULT` or the vault path supplied by the task. Stop with a clear error if
either is unavailable.

## Read commands

Choose the narrowest command that answers the request:

```bash
retex doctor --vault "$RETEX_VAULT" --strict --json
retex count --vault "$RETEX_VAULT" --json
retex list --vault "$RETEX_VAULT" --type task --limit 100 --json
retex search "query terms" --vault "$RETEX_VAULT" --ranked --limit 20 --json
retex show "$RETEX_VAULT/Notes/example.md" --json
retex board --vault "$RETEX_VAULT" --json
retex views --vault "$RETEX_VAULT" --json
```

- Known path: `show`.
- Total or existence check: `count`.
- Structured slice: `list` with supported filters and a bounded `--limit`.
- Unknown path or text query: ranked `search` with a bounded `--limit`.
- Exact phrase or compatibility comparison: omit `--ranked`.
- Workflow state: `board` or `views`.
- Integrity gate: `doctor --strict`.

Use one targeted Retex command instead of recursive glob/search/read sequences.
For multiple agent queries, prefer a long-lived read-only MCP session so startup
and transport are amortized.

## Safe writes

Read the target first. Retex mutations are explicit and journaled:

Initialize each vault once so future undo records stay in its private
vault-root state directory:

```bash
retex init --vault "$RETEX_VAULT" --json
```

```bash
retex create --vault "$RETEX_VAULT" --type task --title "Follow up" --status Inbox --json
retex set "$RETEX_VAULT/Tasks/follow-up.md" owner=alex due=2026-09-01 --json
retex move "$RETEX_VAULT/Tasks/follow-up.md" "In Progress" --json
retex archive "$RETEX_VAULT/Tasks/follow-up.md" --json
retex undo "$RETEX_VAULT/Tasks/follow-up.md" --json
```

Run `doctor` after a write batch. Use `undo` for the latest journaled mutation.
Do not replace an entire note to change one property.

## MCP

Run the stdio server with:

```bash
retex mcp --vault "$RETEX_VAULT"
```

MCP is read-only by default and exposes `list_notes`, `search_notes`,
`read_note`, `get_board`, and `get_stats`. Mutation tools require the explicit
`--allow-write` flag and should be limited to a trusted local host.

Remote agent access must use the hosted read-only helper, TLS at the platform
edge, and a random bearer token of at least 32 characters. Never put tokens in
vault files, source control, URLs, logs, examples, or MCP tool arguments.

## Security boundaries

- Keep each client, team, or trust domain in a separately authenticated service
  or separately assigned MCP config.
- Never expose repository roots. Host only an explicitly curated knowledge
  directory.
- Hosted notes must opt in with `shareable: true` and pass the bundled validator.
- The validator rejects symlinks, hidden paths, non-Markdown files, oversized
  notes, and common credential patterns.
- Retex confines MCP note paths to the selected vault after symlink resolution.
- Read-only mode rejects mutation calls even when a client invokes an unlisted
  tool directly.

## Release and live-vault safety

Treat a live vault like a production database. At the start of Retex
maintenance, check without mutating:

```bash
retex version
retex update --check --json
```

A newer release is not permission to update. Before using its binary against a
live vault:

1. Inventory every Retex-managed local vault and hosted Retex service.
2. Download the immutable release and verify its published SHA-256. On macOS,
   require the expected Developer ID team and Gatekeeper notarization.
3. Keep the installed binary and its `.previous` rollback copy.
4. Copy or clone every live vault to a disposable location.
5. Run the full Retex test suite for the exact candidate binary.
6. Run `init` and `doctor --strict` on every clone.
7. Compare exact-mode `list`, `search`, and `board` JSON with the previous
   release. Ranked search is additive and evaluated separately.
8. Test representative create/set/move/archive/undo mutations only on clones,
   then confirm the previous release can still read every touched file.
9. Update the local binary, run `init` and `doctor --strict` on every live
   vault, and retain rollback until the verification window closes.
10. For hosted services, pin the immutable release tag or commit, deploy one
    canary, rerun authentication/path-escape/write-denial tests, then roll out
    the remaining services and verify each live endpoint.

Never run an unverified build or first-time write against a live vault. Never
mass-update services merely because a new version exists.

## Performance

Retex search uses a compiled byte-level fast path for common ASCII queries and
parses only matching notes. Preserve machine-readable JSON output and avoid
wrapping Retex in a second recursive filesystem scan. Benchmark performance on
a disposable vault clone, with matching result counts, before claiming a
speedup.
