#!/usr/bin/env bash
# Formal equivalence of px_core in the working tree with px_core at a reference commit
# (D-033 item 11: "no behaviour change with the interrupt request idle").
#
# Usage: scripts/core_equiv.sh [reference-commit]     (default: main)
#
# Gold: the px_core source files of scripts/synth_targets.txt at the reference commit,
# extracted with git show into sim/core_equiv/gold/. Gate: the working-tree files; when
# px_core has the interrupt request port, the gate top is tb/formal/px_core_idle.sv, which
# ties irq_req_i to 0 and exposes the reference port list. Both are read with the slang
# front end (no RISCV_FORMAL defines: the product core), flattened, their asynchronous
# resets turned into synchronous ones identically (async2sync), and compared by Yosys's
# equivalence flow: equiv_make pairs equally named signals, equiv_simple proves each pair
# from its input cone (sequential depth below), equiv_induct proves the remaining pairs
# by induction over all of them, and equiv_status lists any pair left unproven (the run
# fails on every unproven pair that is not in ALLOWED).
# The result is unbounded: every output and every paired register is equal in every
# cycle from any common state reachable from reset.
# Allowed unproven pair (ALLOWED below): ex_redirect. Step 2.2b dropped the grant term from
# it (audit B-01); the two versions differ only in states where the EX decode register
# holds a memory access that is also a branch, JALR, FENCE.I or MRET, which induction
# cannot exclude by itself. tb/formal/px_core_b01.sby proves (k-induction, unbounded) that
# no reachable state has an instruction held by the grant term with a trap or redirect
# condition, so the pair is equal in every reachable state; this script runs that proof
# and accepts the pair only if it passes.
# Log: sim/core_equiv/equiv.log. Exit status 0 = equivalent.

set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REF="${1:-main}"
OSS="${OSS_CAD_SUITE:-/c/oss-cad-suite}"
export PATH="$OSS/bin:$OSS/lib:$PATH"
W=sim/core_equiv
rm -rf "$W"
mkdir -p "$W/gold"

gold_files=""
for f in $(git show "$REF:scripts/synth_targets.txt" | sed -n 's/^px_core //p'); do
  git show "$REF:$f" > "$W/gold/$(basename "$f")"
  gold_files="$gold_files $W/gold/$(basename "$f")"
done
gate_files="$(sed -n 's/^px_core //p' scripts/synth_targets.txt)"
gate_top=px_core
if grep -q "irq_req_i" rtl/core/px_core.sv; then
  gate_files="$gate_files tb/formal/px_core_idle.sv"
  gate_top=px_core_idle
fi

cat > "$W/equiv.ys" <<EOF
read_slang $gold_files --top px_core
hierarchy -top px_core
proc
flatten
opt_clean
rename px_core gold
design -stash gold
read_slang $gate_files --top $gate_top
hierarchy -top $gate_top
proc
flatten
opt_clean
rename $gate_top gate
design -stash gate
design -copy-from gold -as gold gold
design -copy-from gate -as gate gate
async2sync
equiv_make gold gate equiv
hierarchy -top equiv
equiv_simple -seq 5
equiv_induct -seq 5
equiv_status
EOF

ALLOWED="ex_redirect"
echo "reference $(git rev-parse --short "$REF"), gate top $gate_top"
yosys -m slang -l "$W/equiv.log" -s "$W/equiv.ys" > /dev/null 2>&1 || { echo "FAIL core equivalence: Yosys error (see $W/equiv.log)"; exit 1; }
summary="$(grep -E "Of those cells [0-9]+ are proven and [0-9]+ are unproven" "$W/equiv.log" | tail -1)"
[ -n "$summary" ] || { echo "FAIL core equivalence: no equiv_status summary (see $W/equiv.log)"; exit 1; }
echo "$summary"
n_unproven="$(echo "$summary" | awk '{print $(NF-2)}')"
# "Unproven $equiv <cell>: <escape>name_gold <escape>name_gate": keep name
unproven="$(grep -E '^ *Unproven ' "$W/equiv.log" | awk '{print $(NF-1)}' | sed -e 's/^.//' -e 's/_gold$//' | sort -u | xargs)"
n_listed="$(grep -cE '^ *Unproven ' "$W/equiv.log" || true)"
if [ "$n_listed" != "$n_unproven" ]; then
  echo "FAIL core equivalence: $n_unproven unproven pairs reported, $n_listed parsed (see $W/equiv.log)"
  exit 1
fi
echo "unproven pairs: ${unproven:-none}"
for u in $unproven; do
  case " $ALLOWED " in
    *" $u "*) ;;
    *) echo "FAIL core equivalence: unproven pair $u (see $W/equiv.log)"; exit 1 ;;
  esac
done
if [ -n "$unproven" ]; then
  if sby -f --prefix sim/formal/px_core_b01 tb/formal/px_core_b01.sby prove > "$W/b01.log" 2>&1; then
    echo "  allowed pair(s) $unproven: px_core_b01 prove PASS (unbounded)"
  else
    echo "FAIL core equivalence: px_core_b01 prove did not pass (see $W/b01.log)"
    exit 1
  fi
fi
echo "PASS core equivalence"
