# Retex 1.6.0 — faster recall and a caching MCP server

**Bottom line:** agents get the same answers, much sooner. A running
`retex mcp` server answers repeated calls on an 11,857-note vault in 7–103 ms
instead of 350–814 ms, and CLI recall is 2.4–3.2× faster. Markdown is still the
only storage.

## MCP: in-memory snapshot

- The server parses the vault once and re-reads only changed files.
- On macOS it watches the vault with file events. Before each request it
  creates a barrier file in a private cache directory and waits for that
  event; events arrive in order, so every write that finished before the
  request has been applied. This takes about 10 ms.
- A barrier later than 40 ms makes that request check every file instead.
  Three late barriers in a row, or a periodic check that finds a change no
  event reported, switch the server to checking every file on each request,
  with a message on stderr.
- Symlinked notes are re-checked on every request; edits to a target outside
  the vault produce no event inside it.
- Linux, Windows and vaults on another volume check every file's size and
  timestamps per request and re-parse only what changed.
- `RETEX_MCP_CACHE=0` turns the cache off. `RETEX_CACHE_TRACE=1` prints how
  each request was served.

## Recall and search

- Accented text is folded once per note, then searched as bytes. This
  replaced a Unicode search per term per note, which dominated recall on
  vaults with Spanish or other accented text. Letters whose folding expands
  ("ß", ligatures) keep the Unicode search.
- Recall scores note bodies last, and only for notes that can still reach
  the requested top results.
- Recall drops more filler words ("we", "you", "should", "have", ...). Kept
  filler matched most of a vault as substrings and buried the real terms;
  recall results change for questions that contain them.
- Fixed: "ff" and "fi" now find the ligatures "ﬀ" and "ﬁ" in notes without
  other accented Latin letters.

## Measurements

11,857-note vault, Apple Silicon, warm cache, medians.

| | 1.5.0 | 1.6.0 |
|---|---:|---:|
| CLI `recall` (3 questions) | 1.22–1.65 s | 0.44–0.53 s |
| CLI `search` | 0.45–0.60 s | 0.33–0.36 s |
| MCP `query_records` | 661 ms | 21 ms |
| MCP `search_notes` | 369–394 ms | 17–48 ms |
| MCP `recall_context` | 361–414 ms | 39–42 ms |
| MCP `get_links` | 814 ms | 103 ms |
| MCP `memory_recall` | 349 ms | 7 ms |

## Compatibility (tested)

- `list`, `count`, `board`, `query` and exact and ranked `search` output is
  byte-identical to 1.5.0 on three test vaults (39/39).
- The cached MCP server returns the same response as an uncached one in
  52/52 steps per vault, including edits made outside Retex while it runs:
  in place, same size within the same second, atomic replace, create, rename,
  delete, symlink target edits, new and renamed folders, and hidden folders.
- The folded matcher agrees with Foundation's case- and diacritic-insensitive
  search on accented, Greek, ligature and "ß" text; recall pruning matches
  full scoring for every limit tested.
- 204 tests pass.
