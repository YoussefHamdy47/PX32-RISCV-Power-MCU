#!/usr/bin/env bash
# Compile and run one unit testbench.
# Usage: scripts/run_unit.sh <tb_name> [source_list.f] [plusargs...]
# Source paths are relative to the repo root; default list: tb/unit/<tb_name>.f.
# D-019: success requires a clean simulator exit, PASS, and no failure diagnostics.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$PATH:/c/iverilog/bin"

TB="${1:?usage: run_unit.sh <tb_name> [source_list.f] [plusargs...]}"
shift
FLIST="tb/unit/${TB}.f"
if [[ "${1:-}" == *.f ]]; then
  FLIST="$1"
  shift
fi
[ -f "$FLIST" ] || { echo "no source list: $FLIST"; exit 1; }

mkdir -p sim/logs
LOG="sim/logs/${TB}.log"

if ! iverilog -g2012 -Wall -o "sim/${TB}.vvp" -s "$TB" -c "$FLIST" > "$LOG" 2>&1; then
  cat "$LOG"
  echo "COMPILE FAIL $TB"
  exit 1
fi

if ! timeout "${PX_TEST_TIMEOUT_SECONDS:-60}s" vvp -n "sim/${TB}.vvp" "$@" >> "$LOG" 2>&1; then
  cat "$LOG"
  echo "FAIL $TB: simulator failed or exceeded timeout"
  exit 1
fi
grep -v '^VCD info' "$LOG"

if grep -q '^PASS' "$LOG" && ! grep -Eq '^(FAIL|ERROR|FATAL|TIMEOUT)([ :]|$)' "$LOG"; then
  exit 0
fi
exit 1
