#!/usr/bin/env python3
"""Measure actual Retex output, not a re-encoding of a hypothetical payload.

Uses a disposable synthetic vault and the installed uc default o200k counter.
Reports text and complete MCP response costs separately; no provider-billing or
universal savings claim. Exit nonzero on semantic mismatch or a measured token
regression against the equivalent compact JSON baseline.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def run(argv, text=None):
    return subprocess.run(argv, input=text, text=True, capture_output=True, check=True).stdout.strip()


def compact(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--retex", default=os.environ.get("RETEX", "retex"))
    ap.add_argument("--uc", default=os.environ.get("UC", "uc"))
    args = ap.parse_args()
    results = []

    def decode(text):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return json.loads(run([args.uc, "decode"], text))

    def count(text):
        return int(run([args.uc, "count"], text))

    def record(label, emitted, baseline):
        actual, original = count(emitted), count(baseline)
        results.append({"case": label, "emitted_tokens": actual, "compact_baseline_tokens": original,
                        "saved_tokens": original - actual, "emitted_bytes": len(emitted.encode()),
                        "baseline_bytes": len(baseline.encode())})

    with tempfile.TemporaryDirectory(prefix="retex-output-bench-") as directory:
        vault = Path(directory) / "vault"
        notes = vault / "Notes"
        notes.mkdir(parents=True)
        for i in range(30):
            (notes / f"note-{i:02}.md").write_text(
                f"---\ntitle: Customer {i}\ntype: memory\ntags: [release, customer]\n---\n"
                + ('Renewal context; café 日本 😀; quotes " slash / and newline.\n' * (40 if i == 0 else 1)),
                encoding="utf-8")
        for label, command in [("count", ["count"]), ("empty", ["search", "absent-synthetic-term"]),
                               ("list", ["list"]), ("recall", ["recall", "renewal", "--budget", "4000"]),
                               ("string-heavy", ["show", str(notes / "note-00.md")])]:
            for lean in [False, True]:
                common = [args.retex, *command, "--vault", str(vault), "--json", *(["--lean"] if lean else [])]
                emitted = run(common)
                raw = json.loads(run([*common, "--raw-json"]))
                assert decode(emitted) == raw, f"CLI semantic mismatch: {label}"
                record(f"cli-{label}-{'lean' if lean else 'wrapped'}", emitted, compact(raw))

        requests = "\n".join(compact(x) for x in [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_notes", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "read_note", "arguments": {"path": str(notes / "note-00.md")}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "recall_context", "arguments": {"query": "renewal", "budget": "4000"}}},
        ]) + "\n"
        def mcp(extra):
            lines = run([args.retex, "mcp", "--vault", str(vault), *extra], requests).splitlines()
            return {json.loads(line)["id"]: json.loads(line) for line in lines}
        encoded, raw = mcp([]), mcp(["--no-uc"])
        assert encoded[1]["result"]["serverInfo"]["version"] == run([args.retex, "version"])
        for ident in [2, 3, 4]:
            text = encoded[ident]["result"]["content"][0]["text"]
            baseline_text = raw[ident]["result"]["content"][0]["text"]
            assert decode(text) == json.loads(baseline_text), f"MCP semantic mismatch: {ident}"
            record(f"mcp-{ident}-text", text, baseline_text)
            record(f"mcp-{ident}-full-response", compact(encoded[ident]), compact(raw[ident]))

    report = {"tokenizer": "uc default o200k", "semantic_equality": True, "cases": results,
              "caveats": ["Synthetic fixtures only; not provider-billed conversation savings.",
                          "No decode round trip is needed for readable UC; exact parsing should request raw JSON.",
                          "MCP full-response rows include text escaping and protocol wrappers.",
                          "Recall budget bounds the record array bytes, not these complete response tokens."]}
    print(json.dumps(report, indent=2))
    if any(row["saved_tokens"] < 0 for row in results):
        raise SystemExit("Measured regression: inspect negative saved_tokens rows")


if __name__ == "__main__":
    main()
