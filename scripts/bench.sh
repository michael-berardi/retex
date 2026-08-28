#!/bin/zsh
# Retex read-only performance harness. Always point it at a disposable vault clone.
# Usage: scripts/bench.sh <retex-binary> [label]
set -euo pipefail
BIN="${1:?path to retex binary}"
LABEL="${2:-run}"
VAULT="${RETEX_BENCH_VAULT:-/tmp/retex-bench-clone}"
SEARCH_QUERY="${RETEX_BENCH_SEARCH_QUERY:-release}"
RECALL_QUERY="${RETEX_BENCH_RECALL_QUERY:-what changed in the latest release}"

echo "== $LABEL =="
START_BEST=999
for _ in {1..10}; do
  T=$( { /usr/bin/time -p "$BIN" version >/dev/null; } 2>&1 | awk '/real/{print $2}' )
  START_BEST=$(python3 -c "print(min($START_BEST,$T))")
done
echo "startup_best_s: $START_BEST"
echo "binary_bytes: $(wc -c < "$BIN" | tr -d ' ')"

T=$( { /usr/bin/time -p "$BIN" list --vault "$VAULT" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "list_cold_s: $T"
for i in {1..3}; do
  T=$( { /usr/bin/time -p "$BIN" list --vault "$VAULT" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
  echo "list_warm_${i}_s: $T"
done
T=$( { /usr/bin/time -p "$BIN" search "$SEARCH_QUERY" --vault "$VAULT" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "search_s: $T"
T=$( { /usr/bin/time -p "$BIN" recall "$RECALL_QUERY" --vault "$VAULT" --limit 20 --budget 12000 --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "recall_s: $T"
T=$( { /usr/bin/time -p "$BIN" doctor --vault "$VAULT" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "doctor_s: $T"
T=$( { /usr/bin/time -p "$BIN" board --vault "$VAULT" --json >/dev/null; } 2>&1 | awk '/real/{print $2}' )
echo "board_s: $T"
