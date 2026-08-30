# Retex

<p align="center">
  <strong>A local-first Markdown vault engine and machine-readable CLI for people and agents.</strong><br />
  <a href="#install-and-run">Install</a> ·
  <a href="#cli">CLI</a> ·
  <a href="#mcp-server">MCP</a> ·
  <a href="#import-existing-knowledge">Import</a> ·
  <a href="#encrypted-export">Encrypted export</a> ·
  <a href="#updates">Updates</a>
</p>

Retex is a local-first Markdown vault architecture: your vault is an ordinary
folder of Markdown files with YAML front matter, and Retex gives it a fast,
structured query surface — exact search, agent recall, arbitrary record types,
property filters, backlinks, boards, saved views, undo, watching, and MCP —
without locking files in a database.

Retex is intentionally headless. There is no bundled reader UI; the vault
format and the CLI are the product, and any reader consumes the same
`RetexCore` package. Retex has no account system, remote database, or network
telemetry. The optional UltraCompact engine records local usage metrics only
when an operator explicitly enables its telemetry sink; note content never
leaves the machine.

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
- Import Notion Markdown/CSV ZIP exports, Obsidian vaults, and ordinary
  Markdown directories while preserving attachments and rejecting symlinks.
- Encrypted, checksummed vault-and-attachment export/import on every platform.
- Opt-in fleet updates verify disposable clones before changing the binary or
  initializing registered live vaults; rollback remains automatic on failure.
- Audit agent-facing `memory`, `report`, and `audit` metadata with the bundled,
  read-only `scripts/contract_scan.py`.

## Requirements

- macOS 14 or later, Linux, or Windows 10/11.
- Building from source requires a Swift 6.0+ toolchain. Xcode 16+ supplies it
  on macOS; Swift.org publishes Linux and Windows toolchains.
- Releases provide a signed universal macOS archive and static Linux archives.
  Windows source builds are supported; self-update requires a matching Windows
  release asset, which is not currently published.

## Install and run

Build from source with Swift Package Manager:

```bash
git clone https://github.com/michael-berardi/retex.git
cd retex
swift build
.build/debug/retex --help
```

On Windows, run `.build\debug\retex.exe --help`.

On macOS, source builds fetch the UltraCompact engine, a proprietary static
library from Implose Cybernetics. Official macOS binaries and the hosted Linux
MCP image use it for token-minimized machine output. Standalone Linux builds
remain canonical JSON unless linked with the engine explicitly; Windows builds
always use canonical JSON.
The engine is governed by `LICENSE-ULTRACOMPACT`, not Retex's MIT license. Build
without it with `ULTRACOMPACT_DIST=0 swift build`.

Or grab a signed, notarized release from the
[Releases](https://github.com/michael-berardi/retex/releases) page:

```bash
grep ' retex-universal.zip$' SHA256SUMS | shasum -a 256 -c -
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
retex query --vault ~/Documents/CRM --on-or-before review_after=2026-08-28 --json
retex search "website rebuild" --vault ~/Documents/CRM --json
retex search "release Retex" --vault ~/Documents/CRM --ranked --limit 20 --json
retex recall "what changed in the Retex release" --vault ~/Documents/CRM --budget 12000 --json
retex links ~/Documents/CRM/Notes/release.md --vault ~/Documents/CRM --json
retex create --vault ./CRM --type invoice --title "Acme August" --folder Invoices --set amount=11500 --json
retex set ./CRM/Invoices/acme-august.md due=2026-09-01 'client=Acme' --json
retex set ./CRM/Invoices/acme-august.md status=Approved --if-hash <sha256-from-show> --json
retex board --vault ./CRM --view pipeline --json
```

Use `list` and `search` for their stable v0.5-compatible output contracts.
Use `query` for structured records with exact arbitrary types and metadata.
Use `recall` for natural agent questions: it removes common filler, ranks
partial matches, returns source paths plus evidence excerpts, and keeps the
encoded record array within `--budget` bytes. `list`, `query`, `search`,
`recall`, and `count` accept arbitrary `--type`, `--status`, `--tag`, repeated
`--where key=value`, and inclusive `--on-or-before key=YYYY-MM-DD` /
`--on-or-after key=YYYY-MM-DD` filters. Date filters match only records with a
valid ISO date for that property.

`show` returns a SHA-256 `contentHash`. Pass it back as `--if-hash` to `set`,
`move`, or `archive` to reject stale agent writes without changing the default
workflow. Retex holds the vault journal lock across the comparison, undo record,
and atomic file write. Wiki links in front matter are part of the derived graph,
so optional properties such as `supersedes: "[[Older Decision]]"` and
`related: "[[Project Brief]]"` appear in `links` and backlinks without a new
storage format.

Commands: `list`, `query`, `search`, `recall`, `links`, `show`, `create`,
`set`, `move`, `archive`, `board`, `views`, `schema`, `count`, `undo`, `log`,
`doctor`, `watch`, `mcp`, `export`, `import`, `fleet`, `update`, `version`. Run
`retex schema --vault ...` to discover built-in, configured, and existing
record types and properties.

### Machine-readable output

Successful responses use one logical envelope (`schema_version` is bumped when
the contract changes):

```json
{
  "ok": true,
  "schema_version": 1,
  "data": {}
}
```

On builds linked with UltraCompact — the official macOS binary and hosted Linux
MCP image — `--json` emits a token-minimized UC packet when that packet is
smaller than JSON; small payloads remain JSON. Decode UC with `uc decode`, or
pass `--raw-json` to force canonical JSON. Engine-free Linux and Windows builds
and `ULTRACOMPACT_DIST=0` builds always emit JSON.

Invalid machine-readable invocations exit with code 64; file or storage
failures exit with code 74. Both use the same logical envelope and
`schema_version`. `doctor --strict` emits its normal report and exits nonzero
when it finds an unreadable note, invalid config, or corrupt journal.

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
`recall_context`, `get_links`, and `get_schema`. `read_note` returns
`contentHash`; write tools accept optional `expected_hash`; and query/recall
accept semicolon-separated `on_or_before` and `on_or_after` date filters.
Mutation tools are rejected even when invoked directly, and note paths are
confined to the selected vault after resolving symlinks. A trusted local host
can explicitly opt into `create_note`, `set_property`, `move_card`, and
`archive_note` with `--allow-write`; the hosted helper never enables it.
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

`deploy/readonly-mcp/` ships in source and every release archive.
`verify_fleet.py` provides the matching live fleet gate without storing or
printing credentials. Keep the private inventory outside the repository with
mode `0600`; token values come from an environment variable or a command
executed directly without a shell:

```json
{
  "version": 1,
  "services": [
    {
      "name": "canary",
      "url": "https://retex-canary.example.com/mcp",
      "token_env": "RETEX_CANARY_TOKEN"
    },
    {
      "name": "tenant-b",
      "url": "https://retex-tenant-b.example.com/mcp",
      "token_command": ["secret-cli", "read", "tenant-b"],
      "token_json_key": "token"
    }
  ]
}
```

```bash
chmod 600 ~/.config/retex/hosted-fleet.json
uv run --with mcp==1.16.0 python deploy/readonly-mcp/verify_fleet.py \
  --config ~/.config/retex/hosted-fleet.json --service canary
# Deploy the remaining services only after the canary passes.
uv run --with mcp==1.16.0 python deploy/readonly-mcp/verify_fleet.py \
  --config ~/.config/retex/hosted-fleet.json
```

The verifier discovers a live probe record, checks authentication, the exact
read-only tool surface, bounded search and recall, path confinement, and write
denial. Selected services run concurrently. Provider-specific service names,
URLs, token bindings, and deploy commands remain in the private inventory.

## Import existing knowledge

Import a Notion **Markdown & CSV** export directly from its ZIP:

```bash
retex import --from ~/Downloads/notion-export.zip \
  --into ~/Vaults/Notion --format notion --json
```

Retex strips Notion's opaque page IDs from names, rewrites local Markdown
links, preserves attachments, and converts CSV databases into readable
Markdown tables while retaining the source CSV.

Import an Obsidian or generic Markdown vault from an extracted directory:

```bash
retex import --from ~/Documents/Obsidian \
  --into ~/Vaults/Imported --format obsidian --json
```

Imports require a new or empty destination, reject symlinks and path escapes,
skip hidden editor/VCS state, cap individual files at 64 MiB and total input at
1 GiB, and initialize private Retex state only after content succeeds.

## Encrypted export

Vault contents stay plain Markdown on disk; when you need to move a vault
through a third-party channel (iCloud, Dropbox, git, email), export it
encrypted:

```bash
read -s RETEX_PASS
export RETEX_PASS
retex export --vault ~/Vaults/CRM --out crm.retex --passphrase-env RETEX_PASS
retex import --from crm.retex --into ~/Vaults/CRM-restored --passphrase-env RETEX_PASS
unset RETEX_PASS
```

The single `RETEXENC1` envelope uses PBKDF2-HMAC-SHA256 (600,000 iterations)
and AES-GCM authenticated encryption. Its versioned inner manifest preserves
Markdown plus portable document/media attachments with a SHA-256 per file;
v0.7 still reads Markdown-only v1 archives. Source code, hidden editor/VCS
state, and Retex-derived state remain excluded. Export passphrases require at
least 12 characters and come from an interactive prompt or named environment
variable, never a process-list-visible argument.

## Updates

Check availability without changing the installation:

```bash
retex update --check --json
```

For one installation, the verified updater remains:

```bash
retex update
```

For multiple vaults, explicitly register the full fleet and opt individual
vaults into post-update initialization:

```bash
retex fleet register --vault ~/Vaults/CRM --auto-update --json
retex fleet status --json
retex fleet initialize --json       # idempotent live init + strict doctor
retex fleet install-updater --json
```

The optional scheduler runs `retex update --auto --fleet` every six hours.
Before replacing the binary, Retex copies only Markdown and vault config into
disposable clones, requires strict doctor success, compares exact `list`,
`search`, and `board` JSON with the installed version, exercises a complete
create/set/move/archive/undo round trip, and confirms that the installed
version can still read candidate-initialized clones. Only then is the binary
swapped atomically. Registered live vaults are initialized and strict-checked;
any failure restores the previous binary.

Every release download requires the exact published SHA-256. macOS also
requires the Retex Developer ID requirement, Gatekeeper notarization, a bounded
regular file, and an exact reported version. Linux uses static platform
archives; Windows uses the matching signed release asset when available.

The short release trigger is: check first, run the built-in clone-gated local
update, deploy one hosted canary, run the bundled verifier for that canary,
deploy the remaining hosted services, then run the verifier without a service
filter. Reinstalling the scheduler is idempotent:

```bash
retex update --check --json
retex update --fleet --json
retex fleet install-updater --json
```

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

Implemented:

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
- Notion ZIP, Obsidian, and generic Markdown-vault imports with attachment
  preservation, collision handling, and path/symlink limits
- Cross-platform encrypted export/import with per-file checksums and legacy
  archive compatibility
- Verified self-update, atomic rollback, disposable clone gates, opt-in fleet
  initialization, and native macOS/Linux/Windows schedulers
- Versioned machine-readable envelopes and regression coverage for parsing,
  mutations, CLI/MCP contracts, imports, crypto, updates, and hosted gateway
  security

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
