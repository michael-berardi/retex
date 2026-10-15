# SQLite storage evaluation (2026-10-14)

Question: should Retex store vaults in SQLite instead of Markdown, either as
the main store or as a second, derived layer?

**Decision: keep Markdown as the only standard.** SQLite as the main store is
rejected; SQLite as a derived query index works and is exact, but it missed
the speed gate, so it stays on this branch as an opt-in prototype
(`RETEX_INDEX=sqlite`) and is not merged.

## Gate (written before testing)

A derived index becomes the default only if all of these pass:

| # | Criterion | Result |
|---|---|---|
| G1 | Byte-identical `--raw-json` output vs Markdown scan on clones of every fleet vault | **Pass**, 182/182 (7 vaults × 26 commands) |
| G2 | Warm median ≥ 3× faster for search, recall and query on the 11,857-note vault | **Fail**, best 2.4×, broad recall 0.9×, `query` 0.7× |
| G3 | External create, edit, same-size same-second edit, backdated edit, rename, delete visible on the next command | **Pass** |
| G4 | Cold build ≤ 10 s and index ≤ 3× Markdown bytes | **Pass**, 7.4 s and 148 MB for 51.6 MB of Markdown (2.9×) |
| G5 | Nothing written inside the vault; deleting the index never changes results | **Pass**, index lives in `~/Library/Caches/retex/index` |
| G6 | Full test suite passes with the index on | **Pass**, 198/198 |
| G7 | Concurrent agents (12 readers + a writer) never error | **Pass after a fix**; first version failed 1/24 with a `UNIQUE` race |

SQLite as the main store would also have to match Markdown on editing,
review, diffs, sync and recovery. It does not (see below).

## Prototype

`Sources/RetexCore/NoteIndex.swift` (system SQLite through `Sources/CSQLite`):

- One table of parsed notes keyed by path, with stat fingerprints (size,
  mtime ns, ctime ns, inode, symlink mtime) and a 2-second racy-clean window
  like git's.
- An FTS5 trigram index (`detail=none`, contentless with delete support) over
  Foundation-folded filename and source. Queries fold terms the same way and
  use the index only to narrow candidates; the existing exact matcher still
  decides every hit, which is why output stays byte-identical.
- Pre-folded ranking fields, so `recall` and ranked `search` skip per-query
  Unicode folding.
- Every command first walks the vault and stats each file, re-parses only
  what changed, and writes under `BEGIN IMMEDIATE` keyed by path, so parallel
  agents converge.
- If the index cannot open, the command reports why on stderr and scans the
  Markdown files.

## Measurements

Same binary, same inputs, only `RETEX_INDEX` differs. Medians of 7 runs,
Apple Silicon, warm page cache, clone of the Liberty Design Vault (11,857
notes, 51.6 MB Markdown).

| Command | Markdown | SQLite index | Speed-up |
|---|---:|---:|---:|
| `search Lucero` | 478 ms | 376 ms | 1.27× |
| `search "cloudflare deploy"` | 716 ms | 395 ms | 1.81× |
| `search "stripe invoice" --ranked` | 715 ms | 295 ms | 2.42× |
| `search ai` (too short for trigrams) | 645 ms | 664 ms | 0.97× |
| `recall` broad (8,743 of 11,857 notes match) | 1,322 ms | 1,447 ms | 0.91× |
| `recall "stripe invoice for juiceboxx"` | 1,126 ms | 514 ms | 2.19× |
| `recall deploy --type memory` | 540 ms | 275 ms | 1.97× |
| `query --type memory` | 370 ms | 534 ms | 0.69× |
| `count` | 465 ms | 462 ms | 1.01× |
| `list` | 624 ms | 591 ms | 1.05× |

UltraTerm agent memory vault (463 notes): every command is 15–42 ms on
Markdown; the index saves 5–12 ms.

**Where the time goes.** The freshness check (walk the tree, stat 11,857
files, load fingerprints) costs about 300 ms per CLI call, the same walk the
Markdown scan already pays. With the check skipped (measurement-only
`RETEX_INDEX_ASSUME_FRESH=1`, the ceiling a file-watcher-backed process could
reach), search drops to 65–100 ms (7–10×) and `count` to 225 ms. Broad
recall stays at 1.3 s either way: it is bound by ranking thousands of
matches, not by storage.

Writes are not a bottleneck in either design: `retex set` with the undo
journal takes 9.7 ms per call including process start; an in-process SQLite
update takes 0.09 ms.

## SQLite as the main store

Rejected. What it would cost:

- **Human editing.** The Liberty Design Vault is an Obsidian vault; Mike and
  agents edit files directly. A database needs Retex (or SQL) for every edit.
- **Review and history.** The same vault is a git repo with 9,107 commits;
  21 commits touched 337 Markdown files in the last 30 days. A binary
  `.sqlite` file has no meaningful diff, blame, or merge, and Retex's
  byte-exact undo journal would have to be rebuilt as row versioning.
- **Every other reader.** Agents and scripts open vault files with ordinary
  tools (`cat`, `grep`, editors, git). All of them would need a Retex or
  SQLite client.
- **Sync and corruption.** One database file under iCloud, Dropbox or git
  sync is a well-known corruption risk (WAL files, partial copies). A bad
  Markdown file loses one note; a bad database page can lose the vault.
- **Portability.** Plain files open on any OS with no tools. The static Linux
  release would also have to bundle SQLite.

What it would gain: the 7–10× read ceiling above without a freshness walk,
and transactional multi-note writes. Neither is a current pain point: the
agent memory vault answers in under 50 ms, and Retex already gives atomic
single-note writes with compare-and-set and undo.

## SQLite as a derived index

Works and is exact, but:

- Search and recall gain at most 1.3–2.4× on the largest vault, and
  listings and filters do not get faster, because the stat walk dominates.
- It adds a 7.4 s first build and a 148 MB cache for a 52 MB vault, a system
  SQLite dependency for Linux builds, and cache-coherency code that already
  produced one concurrency bug during this evaluation.
- The vaults agents query most are small; the index saves milliseconds.

## Better levers (not SQLite)

1. **Long-lived processes keep an in-memory index fed by the file watcher.**
   `retex mcp` and any future daemon can hold parsed notes in memory and
   skip the walk while FSEvents reports no change. That reaches the same
   7–10× ceiling with no new dependency or on-disk format.
2. **Broad recall ranks fewer notes.** The slowest real query matches 74% of
   the vault; scoring only notes that contain more than one term, or capping
   single-term matches before scoring, targets the actual bottleneck.

## Reproduce

```bash
swift build -c release
export RETEX_INDEX=sqlite RETEX_INDEX_DIR=/tmp/retex-index   # opt in
RETEX_INDEX_TRACE=1 .build/release/retex count --vault <clone> --lean
```

The parity and latency harness is in `scripts/sqlite-eval/` (`ab.py`,
`lat.py`). Put APFS clones (`cp -cRp`) of the vaults in a `clones/` folder
beside the scripts; run it against clones only, never live vaults.
