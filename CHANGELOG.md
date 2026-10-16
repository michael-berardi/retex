# Changelog

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
