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
folder of Markdown files with YAML front matter, and Retex gives it a fast,
structured query surface — exact search, agent recall, arbitrary record types,
property filters, backlinks, boards, saved views, undo, watching, and MCP —
without locking files in a database.

Retex is intentionally headless. There is no bundled reader UI; the vault
format and the CLI are the product, and any reader consumes the same
`RetexCore` package. No account system, analytics, remote database, or
third-party runtime service.

## Features

- Model any Markdown collection with arbitrary record types and properties:
  CRM contacts and deals, invoices, tasks, agent memories, runbooks, or custom data.
- Query type, status, tag, and repeated `key=value` property filters.
- Recall natural-language questions with filler-word removal, partial-match
  ranking, evidence excerpts, provenance, and a strict context-byte budget.
- Resolve `[[wiki links]]`, backlinks, and unresolved targets without an editor.
- Navigate and query multiple Markdown vaults from one CLI.
- Preserve unknown YAML properties and edit notes atomically.
- Create, filter, rank, move, and archive Kanban cards without deleting files.
- Validate optional per-type folders, properties, and required fields.
- Undo any mutation (`retex undo`), inspect history (`retex log`).
- Watch vaults for external changes with native FSEvents on macOS and a
  lightweight polling fallback on Linux and Windows.
- Custom board columns and named saved views per vault.
- Drive a vault directly from any MCP host with the built-in MCP server.
- Encrypted vault export/import on macOS, Linux, and Windows.
- Self-update on macOS with checksum verification and rollback.

## Requirements

- macOS 14 or later, Linux, or Windows 10/11.
- Building from source requires a Swift 6.0+ toolchain. Xcode 16+ supplies it
  on macOS; Swift.org publishes Linux and Windows toolchains.
- The signed universal release asset is for macOS. Linux and Windows use the
  same tagged source and feature-complete `RetexCore`/CLI build; only the
  notarized self-updater is macOS-specific.

## Install and run

Build from source with Swift Package Manager:

```bash
git clone https://github.com/michael-berardi/retex.git
cd retex
swift build
.build/debug/retex --help
```

On Windows, run `.build\debug\retex.exe --help`.

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
ln -sfn "$(pwd)/skills/retex" ~/.config/agents/skills/retex
```

The skill contains no organization-specific paths, credentials, client rules,
or deployment workflow.

## CLI

```bash
retex query --vault ~/Documents/CRM --type invoice --tag priority --where owner=Sam --json
retex search "website rebuild" --vault ~/Documents/CRM --json
retex search "release Retex" --vault ~/Documents/CRM --ranked --limit 20 --json
retex recall "what changed in the Retex release" --vault ~/Documents/CRM --budget 12000 --json
retex links ~/Documents/CRM/Notes/release.md --vault ~/Documents/CRM --json
retex create --vault ./CRM --type invoice --title "Acme August" --folder Invoices --set amount=11500 --json
retex set ./CRM/Invoices/acme-august.md due=2026-09-01 'client=Acme' --json
retex board --vault ./CRM --view pipeline --json
```

Use `list` and `search` for their stable v0.5-compatible output contracts.
Use `query` for structured records with exact arbitrary types and metadata.
Use `recall` for natural agent questions: it removes common filler, ranks
partial matches, returns source paths plus evidence excerpts, and keeps the
encoded record array within `--budget` bytes. `list`, `query`, `search`,
`recall`, and `count` accept arbitrary `--type`, `--status`, `--tag`, and
repeated `--where key=value` filters.

Commands: `list`, `query`, `search`, `recall`, `links`, `show`, `create`,
`set`, `move`, `archive`, `board`, `views`, `schema`, `count`, `undo`, `log`,
`doctor`, `watch`, `mcp`, `export`, `import`, `update`, `version`. Run
`retex schema --vault ...` to discover built-in, configured, and existing
record types and properties.

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
with the same `schema_version` field. `doctor --strict` emits its normal report
and exits nonzero when it finds an unreadable note, invalid config, or corrupt
journal.

Exit codes: `0` success, `2` failed strict health gate, `64` invalid usage,
`74` file or storage failure.

### Undo, views, and doctor

Initialize a vault once before its first mutation:

```bash
retex init --vault ~/Documents/CRM --json
```

- **Undo** — every mutation records the file's previous content in
  `<vault>/.retex/history.jsonl` (capped at 50 entries per file, so total
  journal size scales with how many distinct files a vault touches). POSIX
  state is mode `0700` with `0600` files; Windows uses the current user's
  directory ACL. Cross-process locks serialize journal updates. `retex undo
  <file>` restores the prior Markdown; `retex log <file>` lists history.
- **Schemas and views** — `<vault>/.retex/config.json` can define board
  columns, named views with arbitrary property filters, and optional record
  schemas. Schemas choose the default folder, advertise properties to agents,
  and let `doctor --strict` enforce required fields:

```json
{
  "columns": [{ "title": "Backlog", "statuses": ["Inbox", "New"] }],
  "views": [{
    "name": "my-pipeline",
    "type": "deal",
    "status": "Proposal",
    "properties": { "owner": "Sam" }
  }],
  "recordTypes": [{
    "name": "invoice",
    "folder": "Invoices",
    "required": ["client", "amount"],
    "properties": ["client", "amount", "currency", "due"]
  }]
}
```

Configuration is optional. Ad-hoc types retain the v0.5-compatible `Notes/`
default; use `--folder` or a record schema for intentional collections.
Existing built-in folders remain unchanged. Use `retex schema --vault ...`,
`retex views`, and `retex doctor --strict` to discover and validate the
contract.

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

The server preserves `list_notes`, `search_notes`, `read_note`, `get_board`,
and `get_stats`, and adds structured `query_records`, budgeted
`recall_context`, `get_links`, and `get_schema`. Mutation tools are rejected
even when invoked directly, and note paths are confined to the selected vault
after resolving symlinks. A trusted local host can explicitly opt into
`create_note`, `set_property`, `move_card`, and `archive_note` with
`--allow-write`; the hosted helper never enables it. Responses use
newline-delimited JSON-RPC 2.0; diagnostics go to stderr only.

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
key derivation and AES-GCM authenticated encryption through CryptoKit on
Apple platforms and Swift Crypto elsewhere. The file format is identical
across operating systems. The passphrase comes from an environment variable
or interactive prompt, never a process-list-visible argument.

## Updates

Check availability without changing the installation:

```bash
retex update --check --json
```

After validating the candidate on disposable vault clones:

```bash
retex update
```

The macOS updater verifies the exact SHA-256 entry, Developer ID requirement,
Gatekeeper notarization, regular-file boundary, and reported candidate version
before atomically replacing the binary. The previous version remains at
`<path>/retex.previous` for rollback. A failed check leaves the installed
binary untouched. Linux and Windows self-update checks fail closed and use the
tagged source; the universal release asset is macOS-only.

## Vault format

A Retex vault is just a folder of Markdown files — no app, account, or
credential is ever required to read or write one:

```
MyVault/
├── Deals/acme-redesign.md     # built-in CRM type
├── Invoices/acme-august.md    # configured custom type
├── Records/runbook.md         # explicit custom folder
└── .retex/                    # optional internal state
    ├── config.json            # schemas, columns, and saved views
    └── history.jsonl          # undo journal
```

Every file outside `.retex/` is ordinary Markdown readable in any editor.
Everything inside `.retex/` is derived state: delete the folder and Retex
rebuilds it on demand. The full contract is documented above and versioned
through `retex schema`.

## Data API (Markdown contract)

Retex reads ordinary Markdown files. YAML front matter may describe any record
type. Built-ins (`note`, `contact`, `deal`, `task`, `agent-run`) retain their
convenient defaults; values such as `invoice`, `memory`, `runbook`, or a
project-specific type are preserved exactly. The parser supports flat
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

- Arbitrary record types, discoverable schemas, required-field validation,
  generic property filters, saved views, and non-destructive archiving
- Exact search plus agent recall with partial matching, evidence excerpts,
  provenance, and output budgets
- Derived wiki-link graph with outgoing links, backlinks, and unresolved targets
- Multi-vault navigation and atomic editing with unknown-property preservation
- Undo history with cross-process journal locking
- Native FSEvents watching on macOS and lightweight polling on Linux/Windows
- Vault health checks (`retex doctor`)
- Backwards-compatible MCP tools plus structured query, recall, link, and
  schema interfaces
- Cross-platform encrypted export/import (PBKDF2 + AES-GCM)
- macOS self-update with checksum, Developer ID, notarization,
  candidate-version, atomic replacement, and rollback verification
- Versioned JSON envelope on every CLI response
- Regression coverage for parsing, mutations, CLI/MCP contracts, undo, config,
  watching, crypto, update logic, and hosted gateway security

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
public issues. macOS release assets are Developer ID–signed and notarized;
verify `SHA256SUMS` and Gatekeeper acceptance before installing.

## License

Retex is released under the [MIT License](LICENSE).
