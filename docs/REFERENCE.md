# Retex reference

[Install and first use](../README.md) · [Agent memory](AGENT-MEMORY.md)

## CLI

```bash
retex query --vault ~/Documents/CRM --type invoice --tag priority --where owner=Sam --lean
retex query --vault ~/Documents/CRM --on-or-before review_after=2026-08-28 --lean
retex vocabulary --vault ~/Documents/CRM --limit 256 --lean
retex search "website rebuild" --vault ~/Documents/CRM --lean
retex search "release Retex" --vault ~/Documents/CRM --ranked --limit 20 --lean
retex recall "what changed in the Retex release" --vault ~/Documents/CRM --budget 12000 --lean
retex links ~/Documents/CRM/Notes/release.md --vault ~/Documents/CRM --lean
retex create --vault ./CRM --type invoice --title "Acme August" --folder Invoices --set amount=11500 --lean
retex set ./CRM/Invoices/acme-august.md due=2026-09-01 'client=Acme' --lean
retex set ./CRM/Invoices/acme-august.md status=Approved --if-hash <sha256-from-show> --lean
retex board --vault ./CRM --view pipeline --lean
```

Use `list` and `search` for their stable v0.5-compatible output contracts.
Use `query` for structured records with exact arbitrary types and metadata.
Use `vocabulary` for deterministic, read-only extraction of a bounded names-and-terms list. It scans local record text but returns only terms, occurrence/source counts, and the aggregate record count—never note bodies, excerpts, or paths. 
Use `recall` for natural agent questions: it removes common filler, ranks
partial matches, returns source paths plus evidence excerpts, and keeps the
encoded record array within `--budget` UTF-8 bytes. This is **not a token or
whole-response budget**: query/provenance fields, the CLI envelope (unless
`--lean`), and MCP transport wrappers add overhead. `usedBytes` measures that
record array only. `list`, `query`, `search`,
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

Commands: `list`, `query`, `vocabulary`, `search`, `recall`, `links`, `show`, `create`,
`set`, `move`, `archive`, `board`, `views`, `schema`, `count`, `undo`, `log`,
`doctor`, `memory`, `watch`, `mcp`, `export`, `import`, `fleet`, `update`, `version`. Run
`retex schema --vault ...` to discover built-in, configured, and existing
record types and properties.

### Machine-readable output

The `--json` and `--raw-json` modes retain their logical
response envelope (`schema_version` is bumped when that contract changes):

```json
{
  "ok": true,
  "schema_version": 1,
  "data": {}
}
```

`--lean` is an additive machine-output modifier for agents. It can be used by
itself and emits the command payload directly, without `ok`, `data`, or
`schema_version`. Both `--lean` and `--json` emit compact JSON with sorted
keys on all platforms. `--lean --raw-json` emits the same directly parseable
payload. `--raw-json` without `--lean` keeps the pretty-printed enveloped JSON
compatibility-gate mode.

CLI and MCP emit JSON. There is no packet codec or tokenizer dependency.
`--budget` limits the recall record array in UTF-8 bytes, not model tokens
or the complete response.

Invalid machine-readable invocations exit with code 64; file or storage
failures exit with code 74. Existing modes retain the failure envelope and
`schema_version`; lean failures emit a compact direct `{code,message}` object
to stderr and rely on the exit status instead of an `ok` field. `doctor
--strict` emits its normal report and exits nonzero when it finds an unreadable
note, invalid config, or corrupt journal.

Exit codes: `0` success, `2` failed strict health gate, `64` invalid usage,
`74` file or storage failure.

### Undo, views, and doctor

Initialize a vault once before its first mutation:

```bash
retex init --vault ~/Documents/CRM --lean
```

- **Undo** — every mutation records the file's previous content in
  `<vault>/.retex/history.jsonl` (capped at 50 entries per file, so total
  journal size scales with how many distinct files a vault touches).
  Mutations append one line, so their cost does not grow with the journal;
  the per-file cap is compacted on disk as the journal grows. POSIX
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
`--lean` (or the existing `--json`), each batch is one line:
`{"changed":["Notes/foo.md", ...]}`.
Internal `.retex/` state never appears in the stream.

### Agent memory

`retex memory` keeps typed memory records (corrections, gotchas, decisions,
procedures, preferences) in a private vault that several agents share:

```bash
retex memory init --vault ~/agent-memory
retex memory propose --op add --json-file record.json --vault ~/agent-memory --lean
retex memory review --vault ~/agent-memory --lean
retex memory promote global/deploy-with-npm --operator-approved --vault ~/agent-memory --lean
retex memory context --project my-app --budget 6000 --heading "Team memory" --vault ~/agent-memory
```

`context` prints a deterministic pack of *active* records that never exceeds the
budget (default 6,000 bytes, max 8,000); proposals are never included.
Agents may propose; promotion, rejection and retirement need
`--operator-approved`. Every change is journaled for `retex undo`. Schema,
reason codes and protocol: [Agent memory](AGENT-MEMORY.md).

## MCP server

Retex ships a built-in MCP (Model Context Protocol) server so any MCP
host can query a vault directly over stdio. MCP is read-only by default:

```bash
retex mcp --vault ./CRM
```

The server preserves `list_notes`, `search_notes`, `read_note`, `get_board`,
and `get_stats`, and adds structured `query_records`, budgeted
`recall_context`, `get_links`, and `get_schema`, plus read-only
`memory_context`, `memory_recall` and `memory_review` (`memory_propose` only
with `--allow-write`). `read_note` returns
`contentHash`; write tools accept optional `expected_hash`; and query/recall
accept semicolon-separated `on_or_before` and `on_or_after` date filters.
Mutation tools are rejected even when invoked directly, and note paths are
confined to the selected vault after resolving symlinks. A trusted local host
can explicitly opt into `create_note`, `set_property`, `move_card`, and
`archive_note` with `--allow-write`; the hosted helper never enables it.
Responses use newline-delimited JSON-RPC 2.0; diagnostics go to stderr only.

A running server keeps the vault's parsed notes in memory and re-reads only
the files that changed, so repeated calls on a large vault answer in
milliseconds instead of re-reading every file. On macOS it uses file events
and confirms them before each request, so a note written just before a call is
always visible; on other platforms, or if events are late or missing (reported
on stderr), it checks every file's size and timestamps instead. Set
`RETEX_MCP_CACHE=0` to read every file on each call, or `RETEX_CACHE_TRACE=1`
to log how each request was served.

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
docker build -t retex-project .retex
docker run -d --restart unless-stopped -p 8080:8080 --env-file retex.env retex-project
```

Any container host works the same way; keep the bearer token in the host's secret store,
never in the image.

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
uv run --with mcp==1.16.0 --with pydantic==2.11.7 python deploy/readonly-mcp/verify_fleet.py \
  --config ~/.config/retex/hosted-fleet.json --service canary
# Deploy the remaining services only after the canary passes.
uv run --with mcp==1.16.0 --with pydantic==2.11.7 python deploy/readonly-mcp/verify_fleet.py \
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
  --into ~/Vaults/Notion --format notion --lean
```

Retex strips Notion's opaque page IDs from names, rewrites local Markdown
links, preserves attachments, and converts CSV databases into readable
Markdown tables while retaining the source CSV.

Import an Obsidian or generic Markdown vault from an extracted directory:

```bash
retex import --from ~/Documents/Obsidian \
  --into ~/Vaults/Imported --format obsidian --lean
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

Restores require a new or empty destination and accept only the paths an
export can contain: no hidden components and only portable extensions.

The single `RETEXENC1` envelope uses PBKDF2-HMAC-SHA256 (600,000 iterations)
and AES-GCM authenticated encryption. Its versioned inner manifest preserves
Markdown plus portable document/media attachments with a SHA-256 per file;
Retex also reads Markdown-only v1 archives. Source code, hidden editor/VCS
state, and Retex-derived state remain excluded. Export passphrases require at
least 12 characters and come from an interactive prompt or named environment
variable, never a process-list-visible argument.

## Encrypted sync

Sync is optional and off until you run it. Your vault is archived and
encrypted on your machine with the same `RETEXENC1` envelope as export, so the
server stores one opaque blob per vault and never sees a passphrase or note.

```bash
export RETEX_SYNC_TOKEN=...   # bearer token for the server
read -s RETEX_PASS; export RETEX_PASS
retex sync push --vault ~/Vaults/CRM --server https://sync.example.com \
  --vault-id crm --passphrase-env RETEX_PASS      # server and id are saved
retex sync pull --vault ~/Vaults/CRM --passphrase-env RETEX_PASS   # other machine
retex sync status --vault ~/Vaults/CRM --lean
```

- Writes are optimistic: a push made from an out-of-date copy is refused with
  a conflict instead of overwriting the other machine. Pull, then push.
- A pull decrypts and validates the whole archive before touching the vault,
  mirrors remote deletions, and refuses to overwrite unsynced local changes
  unless you pass `--force`. A wrong passphrase leaves the vault unchanged.
- The server must be `https` (plain `http` only for localhost). The token is
  read from `RETEX_SYNC_TOKEN` or the variable named by `--token-env`, never
  from an argument. State lives in `<vault>/.retex/sync.json`.
- Same scope as export: Markdown and portable attachments; hidden and
  Retex-derived state stay local. Last pull wins per vault, with no merging.

A reference server (Python standard library, no dependencies) is in
`deploy/sync-server/server.py`:

```bash
RETEX_SYNC_TOKEN=<24+ random characters> RETEX_SYNC_DIR=/var/lib/retex-sync \
  python3 deploy/sync-server/server.py     # serve behind TLS
```

It implements `GET`, `HEAD` and `PUT /v1/vaults/<id>` with `ETag` and
`If-Match` / `If-None-Match` preconditions, so any storage service that honors
those can stand in.

## Updates

Self-update requires `RETEX_UPDATE_REPO` set to the GitHub `owner/repo`
you trust. See the [installation page](../README.md#updates) for the public
release channel. Without this variable, `update` exits with usage error 64.
Scheduled jobs also need this variable in their own environment; installing
the scheduler does not copy it from your shell.

Check availability without changing the installation:

```bash
retex update --check --lean
```

For one installation, the verified updater remains:

```bash
retex update
```

For multiple vaults, explicitly register the full fleet and opt individual
vaults into post-update initialization:

```bash
retex fleet register --vault ~/Vaults/CRM --auto-update --lean
retex fleet status --lean
retex fleet initialize --lean       # idempotent live init + strict doctor
retex fleet install-updater --lean
```

The optional scheduler runs `retex update --auto --fleet` every six hours.
Before replacing the binary, Retex copies only Markdown and vault config into
disposable clones, requires strict doctor success, compares exact `list`,
`search`, and `board` output in the existing `--raw-json` compatibility mode
with the installed version, exercises a complete
create/set/move/archive/undo round trip, and confirms that the installed
version can still read candidate-initialized clones. Only then is the binary
swapped atomically. Registered live vaults are initialized and strict-checked;
any failure restores the previous binary.

Every release download requires the exact published SHA-256. Before replacement,
the candidate must also be a bounded regular file and report the expected
version. Official macOS assets are Developer ID–signed and submitted to Apple
notarization before publication; the updater verifies checksums and behavior,
not signing identity. Linux uses static platform archives; Windows uses the
matching signed release asset when available.

The short release trigger is: check first, run the built-in clone-gated local
update, deploy one hosted canary, run the bundled verifier for that canary,
deploy the remaining hosted services, then run the verifier without a service
filter. Reinstalling the scheduler is idempotent:

```bash
retex update --check --lean
retex update --fleet --lean
retex fleet install-updater --lean
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
Do not delete `.retex/` to clear a cache: it contains user configuration,
undo history, and sync state. Those cannot be reconstructed from Markdown.
Back up the whole vault when you need to preserve them. Encrypted exports
exclude `.retex/` and are not a backup of that state.
Use `retex schema` to inspect the record contract.

## Data API (Markdown contract)

Retex reads ordinary Markdown files. YAML front matter may describe any record
type. Built-ins (`note`, `contact`, `deal`, `task`, `agent-run`) retain their
convenient defaults; values such as `invoice`, `memory`, `runbook`, or a
project-specific type are preserved exactly. Properties are the unindented
`key: value` lines; nested mappings and list items stay with their parent key
and never become top-level properties. Block scalars (`|`, `>`) read as their
text. `tags` accepts a flow list (`[a, b]`), a block list, or a scalar
(`tags: urgent` or `tags: a, b`). Quoted values are unescaped, and values Retex
writes are quoted and escaped so standard YAML parsers read the same string.
Note bodies remain intact, including wiki links and Markdown checklists.

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

