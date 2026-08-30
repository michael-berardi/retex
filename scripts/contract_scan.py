#!/usr/bin/env python3
"""Read-only coverage scan for the agent memory record contract.

Measures how many agent-consumed records (memory/report/audit types) carry the
optional contract properties (as_of, certainty, source, unknowns), and how many
are exact-migration candidates: a date-like field exists but as_of does not, so
backfilling as_of copies an existing value and invents nothing. The certainty
and unknowns properties are never auto-fillable; they require author judgment.

Never writes to the vault. Pipeline: retex query --json | uc decode.

Usage: contract_scan.py <vault> [<vault>...]

Environment:
  RETEX_BIN   path to the retex binary (default: retex from PATH)
  UC_BIN      path to the uc codec binary (default: uc from PATH)

Suggested operation: run weekly per vault, track full_contract coverage over
time, and alert when new records appear without as_of or certainty. The owner
of each vault runs and reviews the report; the scan itself takes no action.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

RETEX = os.environ.get("RETEX_BIN") or shutil.which("retex")
UC = os.environ.get("UC_BIN") or shutil.which("uc")
TYPES = ["memory", "report", "audit"]
CONTRACT = ["as_of", "certainty", "source", "unknowns"]
DATE_LIKE = ["as_of", "date", "created", "accessed", "review_after"]


def query(vault: str, rtype: str) -> list[dict]:
    proc = subprocess.run(
        [RETEX, "query", "--vault", vault, "--type", rtype, "--limit", "10000", "--json"],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    payload = proc.stdout
    if UC and not payload.lstrip().startswith("{"):
        dec = subprocess.run([UC, "decode"], input=payload, capture_output=True, text=True, check=False)
        if dec.returncode == 0 and dec.stdout.strip():
            payload = dec.stdout
    try:
        return json.loads(payload)["data"]
    except (json.JSONDecodeError, KeyError):
        return []


def scan(vault: str) -> dict:
    report = {"vault": vault, "types": {}}
    for rtype in TYPES:
        records = query(vault, rtype)
        n = len(records)
        if n == 0:
            continue
        cov = {p: sum(1 for r in records if r.get("metadata", {}).get(p)) for p in CONTRACT}
        dated = sum(1 for r in records if any(r.get("metadata", {}).get(d) for d in DATE_LIKE))
        exact_candidates = sum(
            1
            for r in records
            if not r.get("metadata", {}).get("as_of")
            and any(r.get("metadata", {}).get(d) for d in DATE_LIKE if d != "as_of")
        )
        full = sum(1 for r in records if all(r.get("metadata", {}).get(p) for p in CONTRACT))
        report["types"][rtype] = {
            "records": n,
            "coverage": {p: f"{cov[p]}/{n}" for p in CONTRACT},
            "any_date_field": f"{dated}/{n}",
            "full_contract": f"{full}/{n}",
            "exact_as_of_backfill_candidates": exact_candidates,
            "never_auto_fillable": "certainty, unknowns (require author judgment)",
        }
    return report


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    if not RETEX:
        print("contract_scan: retex binary not found; set RETEX_BIN", file=sys.stderr)
        return 66
    if not UC:
        print("contract_scan: uc binary not found; set UC_BIN for large result sets", file=sys.stderr)
    for vault in sys.argv[1:]:
        print(json.dumps(scan(os.path.expanduser(vault)), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
