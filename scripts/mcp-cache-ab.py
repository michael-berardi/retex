#!/usr/bin/env python3
"""A/B check for the `retex mcp` snapshot cache.

Runs the same scenario against two servers on two APFS clones of one vault:
RETEX_MCP_CACHE=0 (reads every file per call) and the default cache. Every
response must match after the clone path is normalized. The scenario mixes
reads, outside edits made directly on disk while the server runs (in place,
same size, atomic replace, create, delete, rename, symlink target outside the
vault, new folder) and writes through the server's own tools.

Usage: mcp-cache-ab.py RETEX_BIN SOURCE_VAULT WORK_DIR
Never point SOURCE_VAULT at anything you cannot clone; the script only writes
inside WORK_DIR.
"""
import json, os, shutil, subprocess, sys, time

BIN, SOURCE, WORK = sys.argv[1], sys.argv[2], sys.argv[3]


class Server:
    def __init__(self, vault, cached):
        env = dict(os.environ, RETEX_MCP_CACHE="1" if cached else "0", AGENT_MEMORY_VAULT=vault)
        self.vault = vault
        self.proc = subprocess.Popen(
            [BIN, "mcp", "--vault", vault, "--allow-write"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
        )
        self.next_id = 0
        self.rpc("initialize", {})

    def rpc(self, method, params):
        self.next_id += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("server exited: " + self.proc.stderr.read().decode()[-500:])
        return json.loads(line)

    def call(self, name, **args):
        started = time.perf_counter()
        response = self.rpc("tools/call", {"name": name, "arguments": args})
        elapsed = time.perf_counter() - started
        text = json.dumps(response.get("result", response.get("error")), sort_keys=True)
        return text.replace(self.vault, "<V>"), elapsed

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=30)
        return self.proc.stderr.read().decode()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


def atomic_write(path, text):
    temp = path + ".tmp-ab"
    with open(temp, "w") as handle:
        handle.write(text)
    os.replace(temp, path)


def main():
    if os.path.exists(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    vaults = {}
    for mode in ("plain", "cached"):
        # Equal-length names: recall reports byte counts that include paths.
        vaults[mode] = os.path.join(WORK, {"plain": "vault-a", "cached": "vault-b"}[mode])
        subprocess.run(["cp", "-cRp", SOURCE, vaults[mode]], check=True)
        os.makedirs(os.path.join(WORK, f"outside-{mode}"))
    servers = {"plain": Server(vaults["plain"], False), "cached": Server(vaults["cached"], True)}
    some_note = None
    for root, dirs, files in os.walk(vaults["plain"]):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in sorted(files):
            if name.endswith(".md"):
                some_note = os.path.relpath(os.path.join(root, name), vaults["plain"])
                break
        if some_note:
            break

    reads = [
        ("list_notes", {"limit": "50"}),
        ("search_notes", {"query": "deploy"}),
        ("search_notes", {"query": "café"}),
        ("search_notes", {"query": "release rollback", "ranked": "true"}),
        ("query_records", {"type": "memory", "limit": "100"}),
        ("recall_context", {"query": "how do we deploy to cloudflare", "budget": "6000"}),
        ("recall_context", {"query": "stripe invoice", "budget": "6000"}),
        ("get_links", {"path": some_note}),
        ("get_stats", {}), ("get_board", {}), ("get_schema", {}),
        ("memory_recall", {"query": "deploy", "budget": "4000"}),
    ]

    mismatches, steps, timings = 0, 0, {"plain": [], "cached": []}

    def compare(label, name, args):
        nonlocal mismatches, steps
        results = {}
        for mode, server in servers.items():
            resolved = {k: (v.replace("<V>", server.vault) if isinstance(v, str) else v) for k, v in args.items()}
            results[mode], elapsed = server.call(name, **resolved)
            timings[mode].append((label, name, elapsed))
        steps += 1
        if results["plain"] != results["cached"]:
            mismatches += 1
            print(f"MISMATCH [{label}] {name} {args}\n  plain : {results['plain'][:300]}\n  cached: {results['cached'][:300]}")

    def both(action):
        for mode in ("plain", "cached"):
            action(vaults[mode], os.path.join(WORK, f"outside-{mode}"))

    for name, args in reads:
        compare("cold", name, args)
    for name, args in reads:
        compare("warm", name, args)

    token = "zqcacheprobe"
    note = lambda v: os.path.join(v, some_note)
    original = open(note(vaults["plain"])).read()

    both(lambda v, o: open(note(v), "a").write(f"\n{token}1\n"))
    compare("edit in place", "search_notes", {"query": token + "1"})
    both(lambda v, o: write(note(v), open(note(v)).read().replace(token + "1", token + "2")))
    compare("same-size edit", "search_notes", {"query": token + "2"})
    compare("same-size edit (old term)", "search_notes", {"query": token + "1"})
    both(lambda v, o: atomic_write(note(v), original + f"\n{token}3\n"))
    compare("atomic replace", "search_notes", {"query": token + "3"})
    both(lambda v, o: write(os.path.join(v, "ab-new.md"), f"---\ntype: memory\n---\n# AB new\n{token}4\n"))
    compare("create", "search_notes", {"query": token + "4"})
    compare("create (query)", "query_records", {"type": "memory", "limit": "500"})
    both(lambda v, o: os.rename(os.path.join(v, "ab-new.md"), os.path.join(v, "ab-renamed.md")))
    compare("rename", "search_notes", {"query": token + "4"})
    both(lambda v, o: os.remove(os.path.join(v, "ab-renamed.md")))
    compare("delete", "search_notes", {"query": token + "4"})
    both(lambda v, o: write(os.path.join(o, "target.md"), f"# Linked\n{token}5\n"))
    both(lambda v, o: os.symlink(os.path.join(o, "target.md"), os.path.join(v, "linked.md")))
    compare("symlink create", "search_notes", {"query": token + "5"})
    time.sleep(0.05)
    both(lambda v, o: write(os.path.join(o, "target.md"), f"# Linked\n{token}6 edited outside\n"))
    compare("symlink target edit", "search_notes", {"query": token + "6"})
    both(lambda v, o: write(os.path.join(v, "ab-folder", "inner.md"), f"# Inner\n{token}7\n"))
    compare("new folder", "search_notes", {"query": token + "7"})
    both(lambda v, o: os.rename(os.path.join(v, "ab-folder"), os.path.join(v, "ab-folder-2")))
    compare("folder rename", "list_notes", {"limit": "100000"})
    both(lambda v, o: write(os.path.join(v, ".hidden", "skip.md"), f"# Hidden\n{token}8\n"))
    compare("hidden folder", "search_notes", {"query": token + "8"})

    compare("mcp create", "create_note", {"title": "AB via MCP", "type": "memory", "body": token + "9"})
    compare("mcp create (search)", "search_notes", {"query": token + "9"})
    for name, args in reads:
        compare("after edits", name, args)
    compare("final full list", "list_notes", {"limit": "100000"})

    for mode, server in servers.items():
        stderr = server.close()
        if stderr.strip():
            print(f"{mode} stderr: {stderr.strip()[:400]}")

    print(f"\n{steps - mismatches}/{steps} responses identical")
    if os.environ.get("AB_DETAIL"):
        for (label, name, a), (_, _, b) in zip(timings["plain"], timings["cached"]):
            if label == "warm":
                print(f"  warm {name:16s} plain {a * 1000:6.0f} ms  cached {b * 1000:6.0f} ms")
    for phase in ("cold", "warm"):
        for mode in ("plain", "cached"):
            total = sum(t for label, _, t in timings[mode] if label == phase)
            print(f"{phase:5s} {mode:6s} {total * 1000:8.0f} ms for {len(reads)} read calls")
    shutil.rmtree(WORK)
    sys.exit(1 if mismatches else 0)


if __name__ == "__main__":
    main()
