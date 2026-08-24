# Retex

<p align="center">
  <strong>A local-first Markdown vault engine and machine-readable CLI for people and agents.</strong><br />
  <a href="#install-and-run">Install</a> ·
  <a href="#cli">CLI</a> ·
  <a href="#mcp-server">MCP</a> ·
  <a href="#encrypted-sync">Encrypted sync</a> ·
  <a href="#updates">Updates</a>
</p>

Retex is a local-first Markdown vault architecture: your vault is an ordinary
folder of Markdown files with YAML front matter, and Retex gives it a fast
query surface — search, boards, saved views, undo, watching, and an MCP
server — without ever locking your files in a database.

Retex is intentionally headless. There is no bundled reader UI; the vault
format and the CLI are the product, and any future reader consumes the same
`RetexCore` package. No account system, analytics, remote database, or
third-party runtime dependency.

## Features

- Navigate and query multiple Markdown vaults from one CLI.
- Search titles, bodies, properties, and labels.
- Edit notes with atomic writes while preserving unknown YAML properties.
- Create, filter, rank, move, and archive Kanban cards without deleting files.
- Undo any mutation (`retex undo`), inspect history (`retex log`).
- Watch vaults for external changes (`retex watch`).
- Custom board columns and named saved views per vault.
- Drive a vault directly from any MCP host with the built-in MCP server.
- Encrypted vault export/import on macOS for sync by any channel.
- Self-update with checksum verification and rollback.

## Requirements

- macOS 14 or later, or Linux with a Swift 6.0+ toolchain.
- Building from source requires Swift Package Manager (Xcode 16+ on macOS).
- File watching and encrypted export/import require macOS. All other CLI
  commands, including the MCP server, are supported on Linux.

## Install and run

Build from source with Swift Package Manager:

```bash
git clone https://github.com/michael-berardi/retex.git
cd retex
swift build
.build/debug/retex --help
```

Or grab a signed, notarized release from the
[Releases](https://github.com/michael-berardi/retex/releases) page:

```bash
shasum -a 256 -c SHA256SUMS      # verify the download
unzip retex-universal.zip        # retex binary + docs
sudo mv retex /usr/local/bin/
```

### Agent skill

Retex includes a provider-neutral agent skill with CLI, MCP, security, and
live-vault safety instructions:

```bash
mkdir -p ~/.config/agents/skills
ln -sfn \"$(pwd)/skills/retex\" ~/.config/agents/skills/retex
```

The skill contains no organization-specific paths, credentials, client rules,
or deployment workflow.

## CLI

```bash
retex list --vault ~/Documents/CRM --type deal --json
retex search "website rebuild" --vault ~/Documents/CRM --json
retex create --vault ./CRM --type deal --title "Acme redesign" --status Inbox --set owner=Sam --json
retex set ./CRM/Deals/acme-redesign.md due=2026-08-01 'next_action=Send scope' --json
retex move ./CRM/Deals/acme-redesign.md Proposal --rank 3 --json
retex board --vault ./CRM --view pipeline --json
```

Commands: `list`, `search`, `show`, `create`, `set`, `move`, `archive`,
`board`, `views`, `schema`, `undo`, `log`, `doctor`, `watch`, `mcp`,
`export`, `import`, `update`, `version`. Run `retex schema` for the record
types, core properties, and board statuses understood by the current build.

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
failures exit with code 74. Failures use the same machine-readable contract
with the same `schema_version` field.

Exit codes: `0` success, `64` invalid usage, `74` file or storage failure.

### Undo, views, and doctor

- **Undo** — every mutation records the file's previous content in
  `<vault>/.retex/history.jsonl` (capped at 50 entries per file, so total
  journal size scales with how many distinct files a vault touches).
  Cross-process safe: an MCP server and CLI runs against one vault serialize
  their journal writes through an advisory lock. `retex undo <file>` restores
  it; `retex log <file>` lists the journal.
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

## MCP server

Retex ships a zero-dependency MCP (Model Context Protocol) server so any MCP
host can query a vault directly over stdio. MCP is read-only by default:

```bash
retex mcp --vault ./CRM
```

The server exposes `list_notes`, `search_notes`, `read_note`, `get_board`, and
`get_stats`. Mutation tools are rejected even when called directly, and note
paths are confined to the selected vault after resolving symlinks. A trusted
local host can explicitly opt into `create_note`, `set_property`, `move_card`,
and `archive_note` with `--allow-write`; the hosted helper never enables it.
Responses use newline-delimited JSON-RPC 2.0; diagnostics go to stderr only.

Example host configuration (placeholders, no credentials):

```json
{
  "mcpServers": {
    "retex": {
      "command": "/usr/local/bin/retex",
      "args": ["mcp", "--vault", "/path/to/vault"]
    }
  }
}
```

### Hosted read-only helper

`deploy/readonly-mcp/` is the secure default for connecting authenticated
agents to a curated repository knowledge folder. Copy its `Dockerfile` to
`.retex/Dockerfile`, add explicitly shareable Markdown under
`.retex/knowledge/`, and deploy only that directory as the build context:

```bash
railway up .retex --path-as-root --service retex-project
```

Every note must opt in through front matter:

```yaml
---
shareable: true
type: note
---
```

The image refuses symlinks, hidden files, non-Markdown files, oversized notes,
notes without the opt-in marker, and common credential patterns. It copies no
other repository content, runs as a non-root user against a non-writable vault,
and leaves Retex in its default read-only mode.

Set a random token of at least 32 characters in `RETEX_MCP_TOKEN`. For
per-agent tokens or rotation, `RETEX_MCP_TOKENS_JSON` accepts a JSON object
whose values are tokens. Clients send
`Authorization: Bearer <token>`; tokens are compared in constant time, never
logged, and every route is denied when authentication is missing or invalid.

## Encrypted sync

Vault contents stay plain Markdown on disk; when you need to move a vault
through a third-party channel (iCloud, Dropbox, git, email), export it
encrypted:

```bash
export RETEX_PASS='your passphrase'
retex export --vault ~/Vaults/CRM --out crm.retex --passphrase-env RETEX_PASS
# sync crm.retex anywhere, then:
retex import --from crm.retex --into ~/Vaults/CRM-restored --passphrase-env RETEX_PASS
```

The export is a single `RETEXENC1` file: PBKDF2-HMAC-SHA256 (600k iterations)
key derivation and AES-GCM authenticated encryption via Apple CryptoKit. The
passphrase is read from an environment variable or an interactive prompt —
never a command-line argument, so it never leaks through process listings.

## Updates

```bash
retex update
```

Checks the latest GitHub release, verifies the SHA-256 checksum of the
release archive before installing, swaps the binary atomically, and keeps the
previous binary at `<path>/retex.previous` for manual rollback. A failed
download, checksum mismatch, or bad archive leaves your current binary
untouched.

## Vault format

A Retex vault is just a folder of Markdown files — no app, account, or
credential is ever required to read or write one:

```
MyVault/
├── Deals/acme-redesign.md     # plain Markdown + YAML front matter
├── Contacts/jamie-doe.md
└── .retex/                    # optional internal state
    ├── config.json            # custom columns / saved views
    └── history.jsonl          # undo journal
```

Every file outside `.retex/` is ordinary Markdown readable in any editor.
Everything inside `.retex/` is derived state: delete the folder and Retex
rebuilds it on demand. The full contract is documented above and versioned
through `retex schema`.

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

- `RetexCore` owns parsing, mutations, watching, crypto, the MCP server, and
  the update channel. It is a plain Swift package usable from any app.
- `RetexCLI` is the human and agent surface over `RetexCore`.
- Markdown remains authoritative; internal state lives under `<vault>/.retex/`
  and is always safe to delete (it is rebuilt on demand).
- A vault reader UI is planned as a separate product consuming `RetexCore`.

## Project status

Implemented today:

- Multi-vault navigation, search, atomic editing with unknown-property
  preservation
- Kanban boards with custom columns, saved views, and non-destructive
  archiving
- Undo history with cross-process journal locking
- FSEvents-based file watching on macOS that ignores internal state
- Vault health checks (`retex doctor`)
- An MCP server exposing the vault to any MCP host
- Encrypted export/import on macOS (PBKDF2 + AES-GCM)
- Self-update with checksum verification, atomic swap, and rollback
- Versioned JSON envelope on every CLI response
- 56 XCTests covering parsing, mutations, the CLI contract, undo, config,
  watching, crypto, update logic, and the MCP server

Not yet shipped:

- A disposable full-text index for very large vaults (plain scans stay fast)
- Optional encrypted sync server

## Contributing

Bug reports and focused pull requests are welcome on
[GitHub](https://github.com/michael-berardi/retex). Keep Markdown as the
source of truth, avoid committing private vault data or credentials, and
include documentation updates when a user-facing command or record property
changes.

## Security

Report vulnerabilities privately via GitHub Security Advisories rather than
public issues. Release assets are Developer ID–signed, notarized, and stapled; verify
the `SHA256SUMS` file before installing.

## License

Retex is released under the [MIT License](LICENSE).
