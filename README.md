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
- Use the same core operations from the human-readable or JSON CLI.
- Undo mutations, watch vaults for changes, and define custom board columns
  and saved views.
- Drive a vault directly from any MCP host with the built-in MCP server.

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
`archive`, `board`, `views`, `schema`, `undo`, `log`, `doctor`, `watch`, and
`mcp`. Run `swift run retex schema` for the record types, core properties, and
board statuses understood by the current build.

- **Undo** — every mutation records the file's previous content in
  `<vault>/.retex/history.jsonl` (capped at 50 entries per file, so total
  journal size scales with how many distinct files a vault touches). Cross-
  process safe: an MCP server and CLI runs against one vault serialize their
  journal writes through an advisory lock. `retex undo <file>` restores it;
  `retex log <file>` lists the journal.
- **Saved views** — `<vault>/.retex/config.json` can define custom board
  columns and named views:

```json
{
  "columns": [{ "title": "Backlog", "statuses": ["Inbox", "New"] }],
  "views": [{ "name": "pipeline", "type": "deal", "status": "Proposal" }]
}
```

Use them with `retex board --view pipeline`, list with `retex views`, and
validate a vault's structure, config, and journal with `retex doctor`.

### Watching

`retex watch --vault ./CRM` streams change batches until Ctrl-C. With
`--json`, each batch is one line: `{"changed":["Notes/foo.md", ...]}`.
Internal `.retex/` state never appears in the stream.

### MCP server

Retex ships a zero-dependency MCP (Model Context Protocol) server so any MCP
host can drive a vault directly over stdio:

```bash
swift run retex mcp --vault ./CRM
```

Tools: `list_notes`, `search_notes`, `read_note`, `create_note`,
`set_property`, `move_card`, `archive_note`, and `get_board`. Responses use
newline-delimited JSON-RPC 2.0; diagnostics go to stderr only.

### JSON output

Successful JSON responses use this envelope (`schema_version` is bumped when
the contract changes):

```json
{
  "ok": true,
  "schema_version": 1,
  "data": {}
}
```

With `--json`, invalid arguments exit with code 64 and file or storage
failures exit with code 74. Failures use the same machine-readable contract:

```json
{
  "ok": false,
  "schema_version": 1,
  "error": {
    "code": 64,
    "message": "list requires --vault <folder>"
  }
}
```

Exit codes: `0` success, `64` invalid usage, `74` file or storage failure.

## Project status

Implemented today:

- Multi-vault workspace navigation
- Search across titles, bodies, properties, and labels
- Markdown editing with atomic writes
- Kanban card creation, editing, filtering, labels, owners, values, due dates,
  checklists, drag-and-drop movement, ordering, and non-destructive archiving
- Agent-run records with status changes and output inspection
- Human-readable and JSON CLI output with a versioned machine-readable envelope
- Undo history (`retex undo`, `retex log`) backed by a per-vault journal
- Custom board columns and saved views via `.retex/config.json`
- Vault health checks (`retex doctor`)
- FSEvents-based file watching (`retex watch`) that ignores internal state
- An MCP server (`retex mcp`) exposing the vault to any MCP host
- A 38-test XCTest suite covering parsing, mutations, the CLI contract,
  undo, config, watching, and the MCP server

Not yet shipped:

- A distributable signed release or auto-update channel
- An iOS application target
- A disposable full-text index for very large vaults (plain scans stay fast)
- Optional encrypted sync

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
