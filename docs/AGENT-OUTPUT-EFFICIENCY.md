# Agent output efficiency — 1.2.2

The CLI and MCP server share one deterministic compact-JSON baseline and
readable-UC selection path. Engine failure/unavailability returns compact JSON,
not pretty JSON. A selected UC packet must also reduce UTF-8 bytes. The linked
engine compares readable candidates using its default o200k tokenizer.

Reproduce on synthetic data only:

```sh
swift test
swift build
python3 scripts/bench-agent-output.py --retex .build/debug/retex
```

The benchmark counts the **actual emitted strings** with `uc count`, checks
semantic equality against raw JSON, and reports MCP text and complete escaped
JSON-RPC responses separately. It fails on a measured token regression. It
requires the existing `uc` CLI; it installs nothing and uses a disposable vault.

One macOS arm64 run (o200k; path tokenization can vary by temporary directory):

| Actual output | Compact JSON tokens | Emitted tokens |
|---|---:|---:|
| CLI count, wrapped / lean | 48 / 37 | 48 / 37 |
| CLI empty search, wrapped / lean | 13 / 1 | 13 / 1 |
| CLI list, wrapped / lean | 4214 / 4203 | 1677 / 1635 |
| CLI recall, wrapped / lean | 1278 / 1267 | 602 / 588 |
| CLI string-heavy show, wrapped / lean | 858 / 846 | 819 / 806 |
| MCP list text / complete response | 1627 / 1717 | 1627 / 1717 |
| MCP read text / complete response | 726 / 838 | 726 / 838 |
| MCP recall text / complete response | 1267 / 1386 | 597 / 670 |

All 16 comparisons preserved semantics and were no larger in measured tokens.
Eight passed through without a token reduction. That is intentional, not a
claim that every invocation saves tokens. `--lean` additionally omits the CLI
success envelope; exact parsers should choose `--lean --raw-json` rather than
paying for a decode tool round trip.

## Limits

- These are synthetic fixtures, not universal provider-billed conversation
  savings. Other tokenizers can rank representations differently.
- Readable UC does not require a decode call for ordinary reading. If a
  consumer nevertheless decodes, include that request and full original text
  in its cost accounting.
- Recall's `budgetBytes` and `usedBytes` cover its encoded record array, not
  the surrounding query/provenance, CLI envelope, or MCP transport wrapper.
- Existing raw-JSON envelopes and note contents are unchanged. No explanatory
  text is appended to payload string values.
