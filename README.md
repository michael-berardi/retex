# Retex

<p align="center">
  <strong>A local-first Markdown workspace and machine-readable CLI for people and agents.</strong><br />
  <a href="#install-and-run">Run the app</a> ·
  <a href="#cli">CLI</a> ·
  <a href="#data-api-markdown-contract">Markdown contract</a> ·
  <a href="#contributing">Contributing</a>
</p>

Retex is a local-first Markdown workspace for CRM records, notes, Kanban
boards, and agent runs. Your vault stays an ordinary folder of Markdown files,
so it remains readable, editable, and portable outside the app.

Retex is an early macOS prototype with a command-line interface. It has no
account system, analytics, remote database, background upload, or third-party
runtime dependency.

## Features

- Navigate multiple Markdown vaults from one workspace.
- Search titles, bodies, properties, and labels.
- Edit notes with atomic writes while preserving unknown YAML properties.
- Create, filter, rank, move, and archive Kanban cards without deleting files.
- Inspect agent-run records and their output.
- Use the same core operations from the human-readable or JSON CLI.

## Requirements

- macOS 14 or later for the SwiftUI app and CLI.
- A Swift 6.0 toolchain. Xcode 16 or later includes a compatible toolchain.

The package declares iOS 17 for shared SwiftUI and model code, but the current
release does not ship an iOS application target.

## Install and run

Clone the repository, then run the macOS app with Swift Package Manager:

```bash
git clone https://github.com/michael-berardi/retex.git
cd retex
swift run RetexApp
```

On first launch, Retex copies its bundled fixture to:

```text
~/Library/Application Support/Retex/Vaults/Sample CRM
```

Use the vault switcher to open any existing Markdown folder. The fixture is
sample data; it is safe to edit or remove.

## CLI

The `retex` executable reads and writes a vault without opening the app:

```bash
swift run retex --help
swift run retex board --vault "$HOME/Library/Application Support/Retex/Vaults/Sample CRM" --json
swift run retex list --vault ./CRM --type deal --json
swift run retex search "website rebuild" --vault ./CRM --json
```

Create and update a record:

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
swift run retex set ./CRM/Deals/acme-redesign.md due=2026-08-01 'next_action=Send scope' --json
```

Available commands are `list`, `search`, `show`, `create`, `set`, `move`,
`archive`, `board`, and `schema`. Run `swift run retex schema` for the record
types, core properties, and board statuses understood by the current build.

### JSON output

Successful JSON responses use this envelope:

```json
{
  "ok": true,
  "data": {}
}
```

With `--json`, invalid arguments exit with code 64 and file or storage
failures exit with code 74. Failures use the same machine-readable contract:

```json
{
  "ok": false,
  "error": {
    "code": 64,
    "message": "list requires --vault <folder>"
  }
}
```

## Data API (Markdown contract)

Retex reads ordinary Markdown files. YAML front matter describes each record
as a note, contact, deal, task, or agent-run. The parser supports flat
properties and inline lists; note bodies remain intact, including wiki links
and Markdown checklists.

```markdown
---
title: Acme website rebuild
type: deal
status: Proposal
rank: 1
owner: Retex Team
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

Retex preserves the note body and unknown YAML properties. Board moves update
`status` and `rank`. Archiving writes `archived: true`; it does not delete the
file.

## Architecture

- SwiftUI provides the macOS shell and shared UI/model code.
- `RetexCore` owns parsing and mutations used by both the app and CLI.
- Markdown remains authoritative; any future search index must be disposable.
- The CLI is the first integration surface for scripts and agents.

## Project status

Implemented today:

- Multi-vault workspace navigation
- Search across titles, bodies, properties, and labels
- Markdown editing with atomic writes
- Kanban card creation, editing, filtering, labels, owners, values, due dates,
  checklists, drag-and-drop movement, ordering, and non-destructive archiving
- Agent-run records with status changes and output inspection
- Human-readable and JSON CLI output
- Comparison and architecture views

Not yet shipped:

- A distributable signed release or auto-update channel
- An iOS application target
- File watching or a disposable full-text index for large vaults
- Undo history for property mutations
- Custom board schemas and saved views
- Optional encrypted sync or MCP packaging

## Contributing

Bug reports and focused pull requests are welcome on
[GitHub](https://github.com/michael-berardi/retex). Keep Markdown as the source
of truth, avoid committing private vault data or credentials, and include
documentation updates when a user-facing command or record property changes.

## License

Retex is released under the [MIT License](LICENSE).
