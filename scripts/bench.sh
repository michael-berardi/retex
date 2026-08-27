#!/bin/zsh
# Retex performance harness. READ-ONLY against real vaults.
# Usage: scripts/bench.sh <retex-binary> [label]
set -euo pipefail
BIN="${1:?path to retex binary}"
LABEL="${2:-run}"
LDS="${RETEX_BENCH_VAULT:-/tmp/retex-bench-clone}"  # benchmark clones only, never live vaults

echo "== $LABEL =="

# Startup latency (10 samples, best-of)
START_BEST=999
for i in {1..10}; do
  T=$( { /usr/bin/time -p "$BIN" version >/dev/null; } 2>&1 | awk '/real/{print $2}' )
  START_BEST=$(python3 -c "print(min($START_BEST,$T))")
done
echo "startup_best_s: $START_BEST"

# Binary size
echo "binary_bytes: $(stat -f%z "$BIN")"

# Cold-ish list (first run after other commands)
T=$( { /usr/bin/time -p "$BIN" list --vault "$LDS" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "list_cold_s: $T"

# Warm list (repeat 3x, report each)
for i in {1..3}; do
  T=$( { /usr/bin/time -p "$BIN" list --vault "$LDS" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
  echo "list_warm_${i}_s: $T"
done

# Search
T=$( { /usr/bin/time -p "$BIN" search "Lucero" --vault "$LDS" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "search_s: $T"

# Agent recall (natural question, bounded evidence)
T=$( { /usr/bin/time -p "$BIN" recall "what is the Retex vault upgrade standard" --vault "$LDS" --limit 20 --budget 12000 --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "recall_s: $T"

# Doctor
T=$( { /usr/bin/time -p "$BIN" doctor --vault "$LDS" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "doctor_s: $T"

# Board
T=$( { /usr/bin/time -p "$BIN" board --vault "$LDS" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "board_s: $T"
