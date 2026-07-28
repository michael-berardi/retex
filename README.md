# Retex

Retex is a native, local workspace for Markdown CRMs and agent knowledge bases. The prototype combines a document workspace, a first-class Kanban, agent run records, multi-vault navigation, and a command-line interface.

The app is written in Swift 6 and SwiftUI. It has no third-party runtime dependencies, account system, analytics, remote database, or background upload.

## Run the prototype

Requirements: macOS 14 or later and Xcode 16 or later.

```bash
swift run RetexApp
```

Retex installs a writable Liberty CRM sample at:

```text
~/Library/Application Support/Retex/Vaults/Liberty CRM
```

Use the vault switcher to open any existing Markdown folder.

## Use the CLI

```bash
swift run retex --help
swift run retex board --vault "~/Library/Application Support/Retex/Vaults/Liberty CRM" --json
swift run retex list --vault ./CRM --type deal --json
swift run retex search "website rebuild" --vault ./CRM --json
```

Create and update a card:

```bash
swift run retex create \
  --vault ./CRM \
  --type deal \
  --title "Acme redesign" \
  --status Inbox \
  --set owner=Sam \
  --set 'tags=[crm, priority]' \
  --json

swift run retex move ./CRM/Deals/acme-redesign.md Proposal --rank 3 --json
swift run retex set ./CRM/Deals/acme-redesign.md due=2026-08-01 next_action="Send scope" --json
```

Every successful JSON response uses this envelope:

```json
{
  "ok": true,
  "data": {}
}
```

Invalid arguments exit with code 64. File and storage failures exit with code 74.

With `--json`, failures use the same machine-readable contract:

```json
{
  "ok": false,
  "error": {
    "code": 64,
    "message": "list requires --vault <folder>"
  }
}
```

## Markdown contract

Retex reads ordinary Markdown files. YAML properties turn a note into a card, contact, task, or agent run.

```markdown
---
title: Acme website rebuild
type: deal
status: Proposal
rank: 1
owner: Liberty Design Studio
value: $11500
due: 2026-08-06
next_action: Send revised scope
tags: [website, priority]
archived: false
---

# Acme website rebuild

Linked contact: [[Jamie Doe]]

- [x] Draft agreement
- [ ] Send revised scope
```

Retex preserves the note body and unknown YAML properties. Board moves update `status` and `rank`. Archiving writes `archived: true`; it does not delete the file.

## Architecture

- SwiftUI provides the macOS shell and a shared UI model for a future iOS target.
- `RetexCore` owns the file parser and mutations used by both the app and CLI.
- Markdown remains authoritative. A future search index must be disposable.
- The CLI is the first agent integration surface. MCP can wrap the same core operations later.
- The current parser supports the flat YAML properties Obsidian exposes in its property editor, inline lists, wiki links, and Markdown checklists.

## Prototype status

Implemented:

- Multi-vault workspace navigation
- Search across titles, bodies, properties, and labels
- Markdown editor with atomic writes
- Kanban card creation, editing, filtering, labels, owners, values, due dates, checklists, drag-and-drop movement, ordering, and non-destructive archiving
- Agent run records with status changes and output inspection
- Human-readable and JSON CLI output
- Obsidian comparison and architecture views

Still production work:

- iOS app target and device QA
- Security-scoped bookmark persistence for sandboxed App Store builds
- File watching and a disposable SQLite FTS index for large vaults
- Undo history for property mutations
- Custom board schemas and saved views
- Signed releases, auto-update, optional encrypted sync, and MCP packaging

## Naming note

Retex is the requested working name. `retex.com` is already registered, and Retex is used by existing software businesses and apps. Domain acquisition and trademark clearance remain unresolved.

## License

MIT. See `LICENSE`.
