#!/usr/bin/env bash
# Generic (technology-independent) Yosys synthesis of each block in scripts/synth_targets.txt.
#
# Per block it checks that the RTL synthesises, that no latches are inferred and that
# `check` finds no problems (undriven/multiply-driven nets, combinational loops). It
# reports the gate count and the longest combinational path in generic gates.
# Results: sim/synth/<top>.log and sim/synth/summary.json (shown on the dashboard).
#
# These are generic-gate numbers for comparing blocks and spotting regressions. They
# are NOT timing closure: 200 MHz can only be shown with a target library/FPGA and STA.
# Generic mapping builds ripple-carry adders, so "depth" overstates adder paths that a
# real library maps to fast adders.
#
# Also runs Verilator lint (-Wall) on each block; UNUSEDPARAM is disabled because
# px_pkg deliberately defines constants that a single block does not use.
#
# Exit status: 0 if every block passes, 1 otherwise.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OSS="${OSS_CAD_SUITE:-/c/oss-cad-suite}"
export PATH="$OSS/bin:$OSS/lib:$PATH"
command -v yosys > /dev/null || { echo "yosys not found (expected under $OSS)"; exit 1; }

mkdir -p sim/synth
fail=0
rows=()

while read -r top files; do
  [[ -z "$top" || "$top" == \#* ]] && continue
  log="sim/synth/${top}.log"
  # slang front end: Yosys's built-in parser rejects package imports inside module bodies.
  script="read_slang $files --top $top; synth -flatten -top $top; check -assert; stat; ltp -noff; \
select -assert-none t:\$dlatch t:\$_DLATCH_* t:\$_DLATCHSR_*"
  if yosys -m slang -l "$log" -p "$script" > /dev/null 2>&1; then
    status=PASS
  else
    status=FAIL
    fail=1
  fi
  if ! VERILATOR_ROOT="$OSS/share/verilator" verilator_bin --lint-only -Wall -Wno-UNUSEDPARAM \
       --top-module "$top" $files >> "$log" 2>&1; then
    status=FAIL
    fail=1
    echo "  $top: Verilator lint failed (see $log)"
  fi
  cells="$(grep -E '^\s+[0-9]+ +cells$|Number of cells:' "$log" | tail -1 | grep -oE '[0-9]+' | head -1)"
  depth="$(grep -oE 'Longest topological path in .* \(length=[0-9]+\)' "$log" | tail -1 | grep -oE 'length=[0-9]+' | cut -d= -f2)"
  latches="$(grep -cE '\$_?DLATCH' "$log" || true)"
  [ "$status" = PASS ] && latches=0
  printf '  %-20s %s  cells=%s  depth=%s\n' "$top" "$status" "${cells:-?}" "${depth:-?}"
  rows+=("{\"module\": \"$top\", \"status\": \"$status\", \"cells\": \"${cells:-?}\", \"latches\": \"$latches\", \"depth\": \"${depth:-?}\"}")
done < scripts/synth_targets.txt

{
  printf '{"timestamp": "%s", "note": "generic gates, not timing closure", "modules": [' "$(date '+%Y-%m-%d %H:%M:%S')"
  (IFS=,; printf '%s' "${rows[*]}")
  printf ']}\n'
} > sim/synth/summary.json

exit "$fail"
