#!/usr/bin/env bash
# Path cones of px_core (D-028, D-032, D-033): generic logic depth of selected endpoints and
# the input ports that reach selected signals combinationally.
#
# Usage: scripts/core_cones.sh [output-directory]     (default sim/core_cones)
#
# 1. Depth: the synth.sh flow (read_slang, synth -flatten), then `ltp -noff` on the input
#    cone of each endpoint, stopping at flops: outputs (data address and request,
#    instruction address and request) and the D inputs of selected registers (EX result
#    into wb_result_q, ex_valid_q, id_valid_q). Generic depth, not timing.
# 2. Structure (audit B-01): on the flattened netlist before technology mapping (signal
#    names kept), the input ports in the combinational input cone of the instruction-port
#    outputs and of the take, EX trap, EX redirect and ID redirect signals.
# Run one Yosys job at a time (IMPLEMENTATION_GUIDE.md § 3.3).

set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
D="${1:-sim/core_cones}"
OSS="${OSS_CAD_SUITE:-/c/oss-cad-suite}"
export PATH="$OSS/bin:$OSS/lib:$PATH"
mkdir -p "$D"
F="$(sed -n 's/^px_core //p' scripts/synth_targets.txt)"
FF='$_DFFE_PN0N_,$_DFFE_PN0P_,$_DFFE_PN1N_,$_DFFE_PN1P_,$_DFF_PN0_,$_DFFE_PP_,$_DFF_P_,$_DFFE_PN_'

# 1. depth
{
  echo "read_slang $F --top px_core"
  echo "synth -flatten -top px_core"
  echo "tee -q -o $D/stat.txt stat"
  for t in data_addr_o data_req_o instr_addr_o instr_req_o; do
    echo "tee -q -o $D/depth.$t.txt ltp -noff w:$t %ci*:-$FF"
  done
  for t in wb_result_q ex_valid_q id_valid_q; do
    echo "tee -q -o $D/depth.$t.txt ltp -noff w:$t %ci1 %ci1:+$FF[D] %ci*:-$FF"
  done
  echo "tee -q -o $D/depth.ALL.txt ltp -noff"
} > "$D/depth.ys"
yosys -m slang -q -s "$D/depth.ys" > "$D/depth.log" 2>&1
echo "cells $(grep -E '^\s+[0-9]+ +cells$|Number of cells:' "$D/stat.txt" | tail -1 | grep -oE '[0-9]+' | head -1)"
for f in "$D"/depth.*.txt; do
  t="${f#$D/depth.}"; t="${t%.txt}"
  printf '  depth %-14s %s\n' "$t" "$(grep -o 'length=[0-9]*' "$f" | cut -d= -f2)"
done

# 2. structure: which input ports reach these signals without passing a flop
{
  echo "read_slang $F --top px_core"
  echo "hierarchy -top px_core"
  echo "proc"
  echo "flatten"
  echo "opt_clean"
  for t in instr_addr_o instr_req_o irq_take ex_trap ex_redirect id_redirect data_req_o; do
    echo "tee -q -o $D/cone.$t.txt select -list w:$t %ci*:-\$dff,\$adff,\$dffe,\$adffe,\$sdff,\$sdffe,\$aldff,\$dffsr i:* %i"
  done
} > "$D/cone.ys"
yosys -m slang -q -s "$D/cone.ys" > "$D/cone.log" 2>&1
for t in instr_addr_o instr_req_o irq_take ex_trap ex_redirect id_redirect data_req_o; do
  ports="$(grep -oE '[a-z_]+_i\b' "$D/cone.$t.txt" | grep -vE '^(clk_i|rst_ni)$' | sort -u | xargs)"
  printf '  inputs -> %-13s %s\n' "$t" "${ports:-none}"
done
