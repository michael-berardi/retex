---
name: retex
description: >
  Use when an agent needs to search, read, count, validate, organize, or safely
  update a Retex Markdown vault through the Retex CLI or MCP server. Prefer this
  structured interface over recursive file discovery or editor-specific APIs.
category: knowledge
version: 1.4.0
author: Retex contributors
tags: [retex, markdown, vault, knowledge, mcp, cli]
trigger_keywords: [retex, markdown vault, knowledge vault, agent memory, kanban]
---

# Retex agent workflow

Retex is a local-first, cross-platform Markdown data engine with a
machine-readable CLI and MCP server. Markdown stays authoritative. Arbitrary
record types support agent memory, CRM, operations, and project-specific data
without an editor, account, remote database, or proprietary file format.

## Resolve the binary and vault

Use `RETEX_BIN` when configured; otherwise use `retex` from `PATH`. Use
`RETEX_VAULT` or the vault path supplied by the task. Stop with a clear error if
either is unavailable.

## Read commands

Choose the narrowest command that answers the request:

```bash
retex doctor --vault "$RETEX_VAULT" --strict --json
retex count --vault "$RETEX_VAULT" --type invoice --where owner=alex --json
retex query --vault "$RETEX_VAULT" --type invoice --status Inbox --tag priority --where owner=alex --limit 100 --json
retex query --vault "$RETEX_VAULT" --on-or-before review_after=2026-08-28 --limit 100 --json
retex search "exact terms" --vault "$RETEX_VAULT" --ranked --limit 20 --json
retex recall "what changed in the release" --vault "$RETEX_VAULT" --budget 12000 --json
retex links "$RETEX_VAULT/Notes/example.md" --vault "$RETEX_VAULT" --json
retex show "$RETEX_VAULT/Notes/example.md" --json
retex schema --vault "$RETEX_VAULT" --json
retex board --vault "$RETEX_VAULT" --json
```

- Known path: `show`.
- Total or existence check: `count`.
- Structured slice: `query` with `--type`, `--status`, `--tag`, repeated
  `--where key=value`, inclusive `--on-or-before key=YYYY-MM-DD` /
  `--on-or-after key=YYYY-MM-DD`, and a bounded `--limit`. Use `list` only when
  a v0.5-compatible compact summary is required. Missing or invalid record
  dates do not satisfy a date filter.
- Natural agent question: `recall` with a bounded `--budget`; it returns
  ranked evidence excerpts and provenance.
- Exact phrase or stable compatibility comparison: `search` without
  `--ranked`. Use `--ranked` for all-term relevance ordering.
- Relationships: `links`.
- Discover record types and properties: `schema --vault`.
- Workflow state: `board` or `views`.
- Integrity gate: `doctor --strict`.

Use one targeted Retex command instead of recursive filesystem queries. Agents
must never open or automate an editor as a vault fallback. If Retex or the
configured vault is unavailable, report that failure rather than switching
knowledge APIs. For multiple queries, prefer a long-lived read-only MCP session
so startup and transport are amortized.

## Safe writes

Read the target first and keep its returned `contentHash`. Retex mutations are
explicit, journaled, and optionally compare-and-set:

Initialize each vault once so future undo records stay in its private
vault-root state directory:

```bash
retex init --vault "$RETEX_VAULT" --json
```

```bash
retex create --vault "$RETEX_VAULT" --type invoice --folder Invoices --title "August" --set client=Acme --set amount=11500 --json
retex set "$RETEX_VAULT/Invoices/august.md" owner=alex due=2026-09-01 --if-hash "$INVOICE_HASH" --json
retex move "$RETEX_VAULT/Tasks/follow-up.md" "In Progress" --if-hash "$TASK_HASH" --json
retex archive "$RETEX_VAULT/Tasks/follow-up.md" --if-hash "$FRESH_TASK_HASH" --json
retex undo "$RETEX_VAULT/Tasks/follow-up.md" --json
```

Pass the hash from the immediately preceding read as `--if-hash`; read again
between mutations. A change since the read then fails instead of being
overwritten. Run `doctor` after a write batch. Use `undo` for the latest
journaled mutation. Do not replace an entire note to change one property.

## Import and encrypted export

Import only into a new or empty destination. Notion should be exported as
Markdown & CSV; Obsidian and ordinary Markdown vaults may be imported from
their directories:

```bash
retex import --from notion-export.zip --into ~/Vaults/notion --format notion --json
retex import --from ~/Documents/Obsidian --into ~/Vaults/obsidian --format obsidian --json
```

Imports preserve attachments, reject symlinks/path escapes, skip hidden
editor/VCS state, and initialize Retex only after content succeeds.

Encrypted exports include Markdown and portable document/media attachments with
per-file SHA-256 validation. Export passphrases require at least 12 characters
and come from a prompt or named environment variable, never a command-line value:

```bash
retex export --vault "$RETEX_VAULT" --out backup.retex --passphrase-env RETEX_PASS
retex import --from backup.retex --into ~/Vaults/restored --passphrase-env RETEX_PASS
```

## MCP

Run the stdio server with:

```bash
retex mcp --vault "$RETEX_VAULT"
```

MCP is read-only by default. The compatibility tools remain, with structured
`query_records`, budgeted `recall_context`, `get_links`, and `get_schema`
available for agents. `read_note` returns `contentHash`; write tools accept
optional `expected_hash`; query and recall accept semicolon-separated
`on_or_before` and `on_or_after` filters. Mutation tools require explicit
`--allow-write` and a trusted local host.

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

Opt-in fleet automation does not weaken the gate. Register the complete fleet,
then enable auto-update only on vaults whose owner authorized it:

```bash
retex fleet register --vault "$RETEX_VAULT" --auto-update --json
retex fleet status --json
retex fleet initialize --json
retex fleet install-updater --json
```

Scheduled `update --auto --fleet` must clone-verify every registered scope,
require strict doctor, exact list/search/board compatibility, and a full
mutation/undo probe; confirm previous-version readability, retain rollback,
and only then initialize opted-in live vaults. Any confirmation failure
restores the previous binary.

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
9. Use `retex update --fleet` for registered scopes; it performs the clone
   compatibility gate before replacement and reports numeric verification.
10. On each live vault, keep post-install verification to idempotent `init` and
    read-only `doctor --strict`; retain rollback until the window closes.
11. For hosted services, pin the immutable release tag or commit, deploy one
    canary, rerun authentication/path-escape/write-denial tests, then roll out
    the remaining services and verify each live endpoint.

Never run an unverified build or first-time write against a live vault. Never
mass-update services merely because a new version exists.

## Performance

Retex exact search and recall use compiled byte-level fast paths for common
ASCII terms and parse only matching notes. Bound both result count and recall
bytes; do not wrap Retex in another recursive scan. Benchmark candidates on a
disposable vault clone with matching result counts before claiming speedups.
