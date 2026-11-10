# Changelog

## 1.9.0 - 2026-11-09

- Agent memory: the session pack is an index, not a wall of abstracts. The five
  highest-support records are still emitted in full, then full entries use
  `--full-share P` percent of the budget (default 25) and the rest of the bytes
  become one-line index entries (title + key, no body) under
  `Index (recall by key):`. At 6,000 bytes a real vault shows ~53 rules instead
  of 21; `--full-share 100` restores the full-entries-only pack. JSON keeps
  every existing field and adds `fullCount`, `indexCount`, `fullShare`,
  `indexTitleWidth` and a per-record `mode`.
- Agent memory: the index tail rotates deterministically per day over the
  non-pinned records, so records that were never shown get their turn while the
  top-support rules stay pinned. `memory context --day YYYY-MM-DD` renders a
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
