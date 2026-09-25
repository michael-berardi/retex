# Agent memory (Retex `memory` command group)

Canonical agent memory for every harness, per
`ultraterm-dream/docs/design/agent-memory-and-dream.md` §3–§5. One store, one
protocol: memory lives in a dedicated private Retex vault of typed `memory`
records. Any harness able to run the CLI or speak MCP reads it the same way (a
budgeted session pack plus on-demand recall) and writes it the same way
(`propose` — validated, locked, journaled, undoable). No harness edits memory
files directly.

```
session start:  retex memory context  → ≤ 6,000 chars injected
during work:    retex memory recall "<q>"        retex memory cite <key>
writes:         retex memory propose --op add|upvote|edit|retire
turn end:       ultradream tick → propose (status: proposed)
operator:       retex memory review | promote | reject | retire | stale
safety:         retex memory doctor · retex undo <path>
```

Dreams propose, people promote. Nothing a dream writes reaches an agent's
context until an operator promotes it with `--operator-approved`.

## The vault

- Default path `~/.local/share/agent-memory`; override with
  `$AGENT_MEMORY_VAULT`; both may be replaced per command with `--vault P`.
- Created only by `retex memory init` (idempotent, private: directories
  `0700`). No other command creates it — every other command fails with
  `agent memory vault not initialized` on a missing vault. Existing Retex
  vaults (personal or client) are never written.
- Layout: `Memory/<scope-dir>/<slug>.md`, one record per key, files `0600`.
  `.retex/` holds the standard Retex undo journal and its flock.

## Record schema (`type: memory`)

| field | type | notes |
|---|---|---|
| `key` | `scope/slug`, `^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)+$`, ≤ 96 chars | identity; one live record per key |
| `kind` | `correction` \| `gotcha` \| `decision` \| `procedure` \| `preference` | ranking weight 1 / .8 / .6 / .5 / .4 |
| `scope` | `global` \| `project:<name>` | key scope dir is `global` or `project-<name>`; the CLI derives one from the other and rejects mismatches |
| `title` | ≤ 120 chars, single line | the imperative rule |
| body | ≤ 600 chars Markdown | why + how to apply; no transcripts, no secrets |
| `applies_when` | ≤ 160 chars, optional | trigger context used for recall |
| `evidence` | ≥ 1 locator, one per line | `^(pi\|claude\|git\|agents-md\|operator\|usap\|note):\S+$` |
| `support` | int ≥ 1 | independent evidence count; `upvote` increments |
| `confidence` | 0..1 | default `0.7`; dreamer/agent estimate, never shown as fact |
| `certainty` | `observed` \| `inferred` \| `reported` | default `inferred` |
| `source_harness` | one token, e.g. `claude-code`, `pi`, `dream`, `operator`, `agent` | who proposed; default `agent` |
| `status` | `proposed` \| `active` \| `stale` \| `retired` \| `rejected` | only `active` is injected |
| `valid_from` / `valid_until` | ISO date | set by promote / retire / supersede |
| `supersedes` / `superseded_by` | `[[key]]` wiki links | chain visible via `retex links` |
| `as_of`, `created`, `updated` | ISO | |
| `recalled`, `cited`, `last_used` | int, int, ISO | usage telemetry |
| `recurrences` | int | mistakes matching this key after activation |
| `retire_proposed` | text | set by `propose --op retire --reason R`; status unchanged |

Validation rejects with a stable reason code, never silently: `missing-field:<f>`,
`too-long:<f>`, `bad-key`, `bad-scope`, `bad-kind`, `bad-confidence`,
`bad-certainty`, `bad-evidence`, `bad-status`, `speculation` (maybe, probably,
i think, might be, possibly, seems like), `secret:<pattern>` (scanner ported
from `ultraterm-dream/src/sanitize.js`: private key blocks, JWTs, bearer
tokens, `sk-ant-`/`sk-…` keys (word-shaped lookalikes kept), `ghp_`-family,
`github_pat_`, `glpat-`, `sk_live_`/`rk_live`/`…_test_`, `xox…-`, `xapp-`,
`AKIA…`, `AIza…`, secret assignments such as `AWS_SECRET_ACCESS_KEY=…`, URL
userinfo, high-entropy blobs), `key-conflict` (message carries the existing
record's status), `not-found`, `hash-mismatch`, `not-authorized`, `bad-budget`,
`bad-op`.

## Read/write protocol

**Session pack.** `retex memory context [--scope global] [--project NAME]
[--budget N] [--harness H] [--heading NAME] [--json]` prints a deterministic Markdown pack of
ACTIVE records in `global` + `project:<NAME>` scope:

- header `## Agent memory (N of M active)`;
- `- **title** — body-first-sentence (key: K)` lines, ranked by
  `0.35·kind + 0.25·min(support,4)/4 + 0.2·usage + 0.2·recency`, where
  `usage = min(1, recalled/10 + cited/3) · 0.5^(daysSince(last_used)/60)` and
  `recency = 0.5^(daysSince(updated)/90)`; ties break by key;
- records are added whole until the budget would be exceeded; a record is
  never cut mid-way;
- footer `(N more active memories; run: retex memory recall "<topic>")` when
  records did not fit;
- budget default 6,000 bytes, hard ceiling 8,000 (`--budget 8001` errors);
  the emitted bytes — header and footer included — are always ≤ budget;
- after emitting, the command bumps `recalled` and refreshes `last_used`
  under a **non-blocking** try-lock on the vault journal lock: a busy lock
  skips the update and reports `countersUpdated: false` in `--json`.

**On demand.** `retex memory recall "<q>" [--budget 4000]
[--include-proposed] [--json]` runs Retex's ranked recall restricted to active
`Memory/` records (proposals included only with the flag, labelled
`[proposed]`), packed whole under the byte budget.

**Citation.** When an agent acts on a memory it names the key (`[mem:
scope/slug]`); `retex memory cite <key>` counts it (`cited += 1`,
`last_used = now`). `cite` is telemetry: try-lock, no undo entry.

**Writes.** `retex memory propose --op add|upvote|edit|retire [--key K]
[--json RECORD_JSON | --json-file F] [--evidence L]... [--reason R]
[--source-harness H] [--if-hash H]`:

- `add` creates a `proposed` record; the key must be free, otherwise
  `key-conflict` names the existing status;
- `upvote` appends new evidence (deduplicated) and `support += 1` on any live
  record (proposed/active/stale);
- `edit` proposes a successor at `K-v<N>` (`supersedes: [[K]]`); fields absent
  from the JSON are inherited from K;
- `retire` marks `retire_proposed: <reason>` on the record; status unchanged;
- output: `{ok, op, key, path, status, contentHash}`.

**Operator actions** (require `--operator-approved`, else `not-authorized`):
`promote <key>` (proposed→active, `valid_from = today`; a superseded record
becomes `retired` with `valid_until = today` and `superseded_by` extended),
`reject <key>` (→rejected), `retire <key> --reason R` (active→retired),
`stale <key>`. Never exposed over MCP.

**Review.** `retex memory review [--json]` lists proposals by support (desc),
then created, then key, with `promoteReady` = support ≥ 2 across ≥ 2 distinct
evidence sessions AND `kind: correction` AND an `operator:`-prefixed or
`#user`-containing locator.

**Doctor.** `retex memory doctor` validates every record, key uniqueness,
key↔path match, supersession chains, and file/directory modes; non-zero exit
on any issue.

## Safety

- Every mutation takes the vault-level journal lock (`flock` on
  `.retex/history.jsonl.lock`), writes atomically, honours `--if-hash`
  compare-and-set (checked under the lock against the primary record), and is
  recorded in the undo journal: `retex undo <path>` restores byte-exact
  content. `propose→promote→undo→undo` returns the file to the originally
  proposed bytes.
- Creation entries journal the created source itself, so the undo chain always
  ends at a coherent, byte-exact state: undoing the create re-writes the
  proposal (use `retire`/`reject` to take a proposal out of circulation).
- Counter updates (`context`, `cite`) are **telemetry**: they use a
  non-blocking try-lock and create **no** undo entries, so `retex undo` only
  ever reverts content mutations, never recall counters.

## MCP

`retex mcp` exposes read-only `memory_context`, `memory_recall`,
`memory_review`. With `--allow-write`, `memory_propose` is additionally
available (same validation, locking, journaling as the CLI). Promotion,
rejection, retirement, and staleness are operator actions and are never
exposed over MCP.

## Score and budget summary

- Pack budget: default 6,000 bytes, max 8,000. Recall budget: default 4,000.
- Score: `0.35·kind + 0.25·min(support,4)/4 + 0.2·usage + 0.2·recency`.
- Memory never recalled or cited decays out of the pack; it is not deleted.

**Heading.** A host names its memory in the pack heading with `--heading`
(for example `--heading "UltraTerm memory"` renders `## UltraTerm memory (N of M active)`).
The name must be one line of at most 60 characters with no Markdown control characters;
anything else falls back to `Agent memory`.
