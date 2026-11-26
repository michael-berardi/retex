# Changelog

## 1.10.0 - 2026-11-26

- Installation: one-line `install.sh` for macOS and Linux downloads the
  matching release archive, checks it against the published SHA256SUMS,
  verifies the Developer ID signature on macOS, installs into
  `~/.local/share/retex/<version>`, and adds a `retex` symlink in
  `~/.local/bin`. It refuses to replace files it did not install. The symlink
  resolves to the real binary, so the existing `retex update` continues to
  swap that binary and keep `<binary>.previous` for rollback.
- Release assets: `scripts/release.sh` now ships `install.sh` in SHA256SUMS,
  and `scripts/build-release.sh` stages published binaries plus the installer
  into `dist/release` for verification. No Windows asset is published, so no
  `install.ps1` ships. `RETEX_HOME`, `RETEX_BIN_DIR`, `RETEX_VERSION` and
  `RETEX_RELEASE_BASE` support isolated tests and mirrors.
- Tests: an end-to-end installer test runs against a local release directory
  with a temporary HOME, including clobber refusal, checksum mismatch, and
  equality of the installer's and updater's pinned Developer ID Team ID. The
  expected version comes from the installed binary, not a hardcoded literal.
- Sync safety: an encrypted-archive pull installs into the vault through the
  same deepest-existing-ancestor, resolved-parent and symlink checks the
  writer path uses, so a symlinked vault subdirectory can no longer make an
  archive write outside the vault (`StoreError.pathOutsideVault`).
- Sync safety: a pull stages the archive under `<vault>/.retex/mirror-<uuid>/`
  instead of a sibling directory in the parent (which fails on read-only
  parents and mount points), replaces each file with a single `rename(2)` over
  the live file, and only deletes files the archive no longer carries after
  every install succeeded. An interruption leaves the vault as it was; a
  failed rollback keeps the stash and names it in
  `CryptoError.mirrorRollbackFailed` instead of discarding it.
- Sync: the stall guard is now the idle timeout (60 s) and the total exchange
  deadline scales with the body size (`max(180 s, bytes / 32 KiB/s)`), so a
  large vault on a slow link is no longer cut off at 180 s.
  `RETEX_SYNC_TIMEOUT_SECONDS` overrides the floor for slower links.
- Sync: a server `ETag` is stored as the revision only when it is a
  64-character SHA-256 (optionally `W/`-prefixed and quoted); any other tag
  falls back to the digest of the exchanged blob, so `retex sync status` no
  longer reports spurious remote changes.
- `retex memory recall` with a subdirectory now returns cached hits through a
  symlinked vault root: the scope filter accepts both the lexical and the
  realpath spelling instead of dropping every entry.
- Agent memory: the secret scanner treats any single-token assignment value of
  12+ characters as a secret (and password-named keys such as `password`,
  `passwd`, `passphrase` and `pwd` from 6), so `password: hunter2` and
  `api_key=letmeinwithwords` are redacted; the digit/symbol/mixed-case shape
  test now applies only to 6-11 character values.
- Front matter: a `#` inside a value is preserved — `title: Fix issue #42`,
  `color: #ff0000` and `tags: [a, #b]` round-trip unchanged. A `#` starts an
  inline comment only after whitespace and outside quotes and `[` lists.
- Ranking: an unbounded ranked search sorts its scored results once instead
  of inserting each hit linearly (quadratic in the number of matches); a
  capped search binary-searches the insertion point. Results are unchanged.
- `retex create`: the note is written to a hidden temp file and hard-linked
  into its name, so a concurrent scan never sees a partially written note.
- `retex create` without a `title`: the value falls back to the `#` heading,
  then to the file name.
- `retex version --json` prints the version as JSON.
- Front matter updates collapse every duplicate key, not just the first two.
- Vault config: the decoded-config memo also keys on inode and ctime, so a
  config replaced within one timestamp tick is reloaded.
- Auto-update scheduler: the systemd unit escapes `%` as `%%` and drops values
  containing control characters, and `RETEX_UPDATE_REPO` must be `owner/repo`.
- Agent memory promotion: a failed supersession restores the record and drops
  its journal entry under one journal lock.

## 1.9.1 - 2026-11-25

- Release packaging: release archives include all linked reference docs
  (`docs/REFERENCE.md`, `docs/AGENT-MEMORY.md`, `docs/REALTIME-SYNC.md`), and
  the hosted Dockerfile (`deploy/readonly-mcp/Dockerfile`) and bundled skill
  metadata (`skills/retex/SKILL.md`) align to `v1.9.1`.
- Documentation: shortened the front-page README, restored project links and
  signed-download verification steps, documented vault safety and output
  contracts in `docs/REFERENCE.md`, and fixed a typo in the encrypted sync
  section.
- Tests: extracted local record-identifier constants in
  `Tests/RetexCoreTests/AgentMemoryTests.swift` so controlled secret-scanner
  runs pass cleanly without false positives on inline `key: "global/..."`
  fixtures.

## 1.9.0 - 2026-11-11

- Agent memory: reads never write record files. Usage from `cite` and
  `memory recall` hits now goes to one sidecar per vault,
  `.retex/memory-usage.json`, written at most once per call and only when a
  record gets its first use of the day; record Markdown is left alone.
  Earlier releases rewrote every emitted record on every `memory context`
  call. With a pack built on every agent turn in every pane, that came to
  ~1,900 file events a minute on a 617-record vault and kept macOS
  `fseventsd` at 100% CPU for days. Existing `cited` / `recall_hits` /
  `last_used` frontmatter is the baseline; the sidecar adds to it, and
  nothing is rewritten on upgrade.
- `retex watch` (macOS) reports only Markdown notes outside hidden
  directories, matching the Linux/Windows poller, so atomic-save temp files
  (`note.md.sb-…`) and Retex's own `.retex/` state never reach the callback.
  Its debounce now flushes at most `max(1 s, 4 × debounce)` after the first
  pending change, so a steady stream of writes can no longer hold back every
  callback.
- Release packaging: the Linux download is `retex-linux-<arch>.tar.xz`, about
  15.7 MB for aarch64 (the `.tar.gz` was 25.3 MB). The `.tar.gz` is still
  published because the in-app updater of 1.8.x looks for that name. The
  static binary itself is unchanged in size; its bulk is bundled Foundation
  and ICU data.
- Agent memory: the session pack is readable rules first and a readable index
  after them. The five highest-support records are emitted in full, the
  best-ranked rules follow in full for the majority of the budget
  (`--full-share P`, default 60, and never fewer than 12 while the budget holds
  them), and the rest of the bytes become one line per rule under
  `Index (recall a line's words to load it):`. A line is the rule's own whole
  title — no body, no bold, no key duplicating the title — and
  `retex memory recall "<the line>"` returns that record first (measured on a
  350-record vault: 350/350 first hits). `--index-width N` (default 200, i.e.
  whole titles) caps a line; a longer title is cut at a word boundary after at
  least 10 words, ends in `…`, and then carries the scope-less key slug. At
  6,000 bytes a real vault shows 12 full rules plus ~20 index lines instead of
  21 abstracts; `--full-share 100` restores the full-entries-only pack. JSON
  keeps every existing field and adds `fullCount`, `indexCount`, `fullShare`,
  `indexTitleWidth` and a per-record `mode`.
- Agent memory: the index tail rotates deterministically per day over the
  non-pinned records — the pool in key order, a window that starts at
  `(day · step) mod count` with `step` the pack's index capacity — so
  consecutive days take consecutive windows and every non-pinned record gets
  its turn once per cycle (~17 days at 6,000 bytes on a 350-record vault) while
  the top-support rules stay pinned. `memory context --day YYYY-MM-DD` renders a
  chosen day; one day's pack is byte-identical for a given vault state, so
  prompt caches stay warm.
- Agent memory: emission is no longer usage. `memory context` writes nothing
  (no counter, no `last_used`), and the score's usage term comes from real use
  only — `cite`, or a `memory recall` hit the agent asked for (new optional
  `recall_hits` field) — with at most one increment per record per day.
  `recalled` is legacy emission telemetry and is no longer read by the score,
  so records that were simply emitted often can no longer pin the pack.
- Agent memory: optional `verified_by` (what established the rule) and
  `confirmation: confirmed | unconfirmed` record fields, accepted by
  `memory propose`, shown by the new `memory show` and by `memory recall`, and
  reported by `memory doctor` as advisory warnings. `confirmed` requires
  `verified_by`.
- Agent memory: `memory doctor --json` adds `warnings` (advisory only; `ok` and
  the exit code still depend on `issues` alone), and `memory recall` adds
  `countersUpdated`, `verifiedBy` and `confirmation`.

## 1.8.3 - 2026-11-07

- `init` creates a missing vault and its parent directories, and reports a
  clear error when the vault path is a file. Other commands still require an
  existing vault.
- Release builds: the Linux cross-build picks a macOS SDK that the Swift toolchain can compile every package manifest with. A newer SDK (MacOSX 27.2 with Swift 6.3.3) crashed the manifest compile; `RETEX_LINUX_MANIFEST_SDK` overrides the choice.

## 1.8.2 - 2026-11-06

- Release binaries are published again. 1.8.0 and 1.8.1 shipped without the
  macOS and Linux archives because the release build's test step hung: the
  CLI tests asked `swift build --show-bin-path` for the binary from inside
  `swift test`, which holds the build lock. The tests now find the binary
  beside their own test bundle (override with `RETEX_TEST_BIN_DIR`).
- README install commands and badges point at the real repository again.

## 1.8.1 - 2026-11-06

- Hosted helper: the vault refresher no longer downloads and copies the whole
  vault repository for every new commit. It reads the served subdirectory's
  git tree first (blobless, no checkout) and skips the refresh when that tree
  is unchanged; a changed subdirectory is fetched with a sparse checkout.
  One deployment measured about 110 GB written in 5 days from refreshes
  triggered by commits outside its subdirectory.
- The hosted Dockerfile defaults to the current release again (`v1.8.1`);
  it still pointed at `v1.7.0`.

## 1.8.0 - 2026-11-01

- Neutrality: the self-updater no longer ships a built-in GitHub owner;
  set `RETEX_UPDATE_REPO` to the owner/repo it should track.
- Neutrality: README release links and badges use a neutral placeholder owner.
- Neutrality: a new `NeutralityTests` suite scans shipped source, docs, skills,
  scripts, and README for model ids, provider preferences, and personal names.

## 1.7.0 - 2026-10-22

- Encrypted vault sync (`retex sync push|pull|status`) with a reference server.

## 1.6.1 - 2026-10-16

- Hosted helper: the gateway exposes exactly the read tools the fleet verifier
  expects and refuses the agent-memory tools that `retex mcp` added in 1.4.0.
  `pydantic` is pinned to 2.11.7; newer releases break `mcp` 1.16.0 at import.

## 1.6.0

- `retex mcp` keeps parsed notes in memory and re-reads only files that
  changed. On macOS, file events are confirmed by a barrier before every
  request, so a write that finished before the request is always visible;
  late or missing events fall back to checking every file.
  `RETEX_MCP_CACHE=0` turns the cache off; `RETEX_CACHE_TRACE=1` logs how
  each request was served.
- Recall and search fold accented text once per note instead of running a
  Unicode search per term, with identical results.
- Recall ranks only the notes that can still reach the top results, with
  identical scores and order.
- Recall drops more conversational filler ("we", "you", "should", "have",
  ...). Short filler words matched most of a vault as substrings.
- Fixed: a search for "ff" or "fi" now finds the ligatures "ﬀ" and "ﬁ" in notes
  without other accented Latin letters.

## 1.5.0

- Removed the optional UltraCompact integration.
