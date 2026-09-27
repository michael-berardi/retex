#!/usr/bin/env python3
"""Measure actual Retex compact JSON output on a disposable synthetic vault.

Reports emitted byte counts and semantic equality to the raw-JSON CLI output.
No external codec or tokenizer is required.
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
    args = ap.parse_args()
    results = []

    def record(label, emitted):
        results.append({"case": label, "emitted_bytes": len(emitted.encode())})

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
                assert json.loads(emitted) == raw, f"CLI semantic mismatch: {label}"
                record(f"cli-{label}-{'lean' if lean else 'wrapped'}", emitted)

        requests = "\n".join(compact(x) for x in [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "list_notes", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "read_note", "arguments": {"path": str(notes / "note-00.md")}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "recall_context", "arguments": {"query": "renewal", "budget": "4000"}}},
        ]) + "\n"
        responses = {json.loads(line)["id"]: json.loads(line)
                     for line in run([args.retex, "mcp", "--vault", str(vault)], requests).splitlines()}
        assert responses[1]["result"]["serverInfo"]["version"] == run([args.retex, "version"])
        for ident in [2, 3, 4]:
            text = responses[ident]["result"]["content"][0]["text"]
            assert isinstance(json.loads(text), dict), f"MCP JSON mismatch: {ident}"
            record(f"mcp-{ident}-text", text)
            record(f"mcp-{ident}-full-response", compact(responses[ident]))

    print(json.dumps({"semantic_equality": True, "cases": results,
                      "caveats": ["Synthetic fixtures only; not provider-billed conversation savings.",
                                  "Recall budget bounds the record array bytes, not complete response bytes."]}, indent=2))


if __name__ == "__main__":
    main()
