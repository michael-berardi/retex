#!/usr/bin/env python3
"""A/B parity + latency: Markdown scan (baseline) vs SQLite index (candidate).

Same binary, same inputs; only RETEX_INDEX differs. Parity compares the
enveloped --raw-json output byte for byte (the established compat gate)."""
import json, os, statistics, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.expanduser("~/dev/retex-sqlite-eval/.build/release/retex")
IDX = os.path.join(S, "idx")
CLONES = os.path.join(S, "clones")

QUERIES = [
    ["search", "Lucero"], ["search", "cloudflare deploy"], ["search", "café"], ["search", "ai"],
    ["search", "año"], ["search", "\"quoted\""], ["search", "TODO"], ["search", "zzqx-no-hit"],
    ["search", "Lucero Legal", "--ranked"], ["search", "stripe invoice", "--ranked"],
    ["search", "migraciones residencia", "--ranked"], ["search", "ñ x", "--ranked"],
    ["recall", "how do we deploy lucero to cloudflare"], ["recall", "stripe invoice for juiceboxx"],
    ["recall", "what is the DNU 366 residence rule"], ["recall", "ultraterm release rollback"],
    ["recall", "a b"], ["recall", "residência permanente"],
    ["recall", "deploy", "--type", "memory"],
    ["list"], ["query", "--type", "memory", "--limit", "100"], ["query", "--status", "Inbox"],
    ["query", "--tag", "lucero"], ["count"], ["board"], ["schema"],
]


def run(vault, args, indexed, fmt="--raw-json"):
    env = dict(os.environ, RETEX_INDEX_DIR=IDX)
    env.pop("RETEX_INDEX", None)
    if indexed:
        env["RETEX_INDEX"] = "sqlite"
    cmd = [BIN, args[0]] + args[1:] + ["--vault", vault, fmt]
    if args[0] == "recall":
        cmd += ["--budget", "12000"]
    if args[0] == "schema":
        cmd = [BIN, "schema", "--vault", vault, fmt]
    t = time.perf_counter()
    p = subprocess.run(cmd, env=env, capture_output=True)
    return time.perf_counter() - t, p.returncode, p.stdout, p.stderr


def main():
    vaults = sorted(os.listdir(CLONES))
    report = {"parity": [], "latency": []}
    mismatches = 0
    for name in vaults:
        vault = os.path.join(CLONES, name)
        run(vault, ["count"], True)  # cold build, timed separately
        for q in QUERIES:
            _, rc_a, out_a, err_a = run(vault, q, False)
            _, rc_b, out_b, err_b = run(vault, q, True)
            same = rc_a == rc_b and out_a == out_b
            if not same:
                mismatches += 1
                print(f"MISMATCH {name} {q} rc {rc_a}/{rc_b} len {len(out_a)}/{len(out_b)} err={err_b[:200]!r}")
            report["parity"].append({"vault": name, "q": q, "same": same})
        print(f"{name}: parity done", flush=True)
    print(f"parity: {len(report['parity']) - mismatches}/{len(report['parity'])} identical")
    json.dump(report, open(os.path.join(S, "parity.json"), "w"), indent=1)
    sys.exit(1 if mismatches else 0)


if __name__ == "__main__":
    main()
