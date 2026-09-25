# Retex 1.4.0 — agent memory

**Bottom line:** Retex can now be the shared memory for AI agents. A host
(UltraTerm ships it as *UltraTerm memory*) keeps typed memory records in a
Retex vault. Agents load a small budgeted pack at session start, recall more
on demand, and propose new memories through one validated command. Promotion
is an explicit operator step, and every change is undoable.

## New: `retex memory`

- `init`: creates a private vault (0700 directories, 0600 files). Idempotent.
- `context`: a deterministic pack of active memories, never over the byte
  budget (default 6,000, max 8,000). Records are never cut mid-way, and
  `--heading` names the pack.
- `recall`: ranked recall limited to memory records (active, plus proposed with
  `--include-proposed`).
- `propose --op add|upvote|edit|retire`: validated with stable reason codes and
  a secret scanner. An upvote adds support only when it brings new evidence.
- `promote` / `reject` / `retire` / `stale`: require `--operator-approved`.
  Promoting a successor retires the record it supersedes.
- `review`: proposals by support, with a promote-ready flag. `cite` records use.
  `doctor` validates records, key uniqueness and supersession chains.
- MCP: `memory_context`, `memory_recall` and `memory_review` are read-only.
  `memory_propose` is only available with `--allow-write`, and
  promotion is never exposed over MCP.

## Guarantees (tested)

- Byte-exact undo: propose → promote → undo → undo restores the original bytes.
- Concurrency: 8 processes × 20 proposals → 160 records, none lost, doctor clean.
- Pack budget holds for every budget from 500 to 8,000 with 200 random
  records. Proposed records are never injected.
- Record JSON accepts a numeric `confidence`.

See `docs/AGENT-MEMORY.md` for the record schema and protocol.
