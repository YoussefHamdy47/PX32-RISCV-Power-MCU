#!/usr/bin/env bash
# Formal equivalence of px_core in the working tree with px_core at a reference commit
# (D-033 item 11: "no behaviour change with the interrupt request idle").
#
# Usage: scripts/core_equiv.sh [reference-commit]     (default: main)
#
# Step 2.2d (D-035 item 8): with CORE_EQUIV_CUT_CSR=1 the CSR file is cut out of both cores:
# the outputs of the u_csr instance become free input ports with the same names in both
# (csr_rdata, csr_wdata, csr_noinc, csr_mtvec, csr_mepc, csr_mie, id_csr_illegal), the nets
# driving its inputs become compared outputs (id_csr_addr, dec, ex_csr_addr, ex_csr_op,
# csr_operand, ex_dec_q, csr_commit, wb_count, mret_commit; the trap port already is), the
# instance is deleted, and the gate's CSR outputs the reference does not have are tied to
# their CLINT-mode values (clic_mode_o, mil_o, mintthresh_o, minhv, the claim and the side
# writes 0; the vector table address unused). tb/formal/px_csr_clint_equiv.sby proves those
# values and the shared outputs equal for programs that stay in CLINT mode (assumption A),
# so the two results together cover the core. The CLIC inputs are tied idle in both; the
# reference's interrupt request port is tied idle as well. trap_cause_o is 6 bits in the gate:
# its bits 4:0 are paired with the reference's and bit 5 is proven 0 (SAT).
#
# Gold: the px_core source files of scripts/synth_targets.txt at the reference commit,
# extracted with git show into sim/core_equiv/gold/. Gate: the working-tree files; ports
# the reference does not have (the interrupt request and acknowledge, trap_irq_o) are
# removed from the flattened gate and its request inputs tied to 0, so every internal
# signal keeps its name and can be paired with the reference. Both are read with the slang
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
# CORE_EQUIV_GATE_DIR: take the gate's RTL files from that directory instead (by file
# name; used to show that a planted difference is reported)
if [ -n "${CORE_EQUIV_GATE_DIR:-}" ]; then
  g=""
  for f in $gate_files; do g="$g $CORE_EQUIV_GATE_DIR/$(basename "$f")"; done
  gate_files="$g"
fi
# Interrupt ports (D-033): request inputs tied idle, acknowledge outputs not compared
idle=""
if grep -q "irq_req_i" rtl/core/px_core.sv; then
  idle="delete -port w:irq_req_i w:irq_id_i w:irq_ack_o w:irq_ack_id_o w:trap_irq_o
cd px_core
connect -set irq_req_i 1'b0
connect -set irq_id_i 6'b000000
cd ..
opt_clean"
fi
gold_idle=""
cut_gold=""
cut_gate=""
if [ "${CORE_EQUIV_CUT_CSR:-0}" = 1 ]; then
  CSR_OUTS="w:csr_rdata w:csr_wdata w:csr_noinc w:csr_mtvec w:csr_mepc w:csr_mie w:id_csr_illegal"
  # the nets driving the CSR file's inputs become compared outputs (the trap port is one
  # already): the miter proves the CSR file equal for equal inputs, this proves the inputs
  CSR_INS="w:id_csr_addr w:dec w:ex_csr_addr w:ex_csr_op w:csr_operand w:ex_dec_q w:csr_commit w:wb_count w:mret_commit"
  cut_gold="cd px_core
expose $CSR_INS
expose -input $CSR_OUTS
delete c:u_csr
cd .."
  cut_gate="cd px_core
expose $CSR_INS
expose -input $CSR_OUTS
delete c:u_csr
cd ..
delete -port w:irq_valid_i w:irq_level_i w:irq_shv_i w:irq_claim_o w:irq_claim_id_o w:mil_o w:mintthresh_o w:clic_mode_o w:rvfi_csrx_we_o w:rvfi_csrx_wdata_o
cd px_core
connect -set csr_side_we 4'b0000
connect -set csr_side_wdata 128'd0
connect -set csr_minhv 1'b0
connect -set csr_tbl_addr 32'd0
connect -set clic_mode_o 1'b0
connect -set mil_o 8'd0
connect -set mintthresh_o 8'd0
connect -set irq_claim_o 1'b0
connect -set irq_claim_id_o 6'd0
connect -set irq_valid_i 1'b0
connect -set irq_level_i 8'd0
connect -set irq_shv_i 1'b0
rename trap_cause_o trap_cause_x
add -output trap_cause_o 5
connect -set trap_cause_o trap_cause_x[4:0]
cd .."
  # the reference has the request port too (2.2b): tie it idle there as well
  gold_idle="$idle"
fi

cat > "$W/equiv.ys" <<EOF
read_slang $gold_files --top px_core
hierarchy -top px_core
proc
$cut_gold
flatten
opt_clean
$gold_idle
rename px_core gold
design -stash gold
read_slang $gate_files --top px_core
hierarchy -top px_core
proc
$cut_gate
flatten
opt_clean
$idle
${cut_gate:+design -save gate_pre
async2sync
opt -full
sat -seq 1 -prove trap_cause_x[5] 0 -verify
design -load gate_pre
delete -port w:trap_cause_x
opt_clean}
rename px_core gate
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
echo "reference $(git rev-parse --short "$REF")${idle:+, interrupt request tied idle}"
yosys -m slang -l "$W/equiv.log" -s "$W/equiv.ys" > /dev/null 2>&1 || { echo "FAIL core equivalence: Yosys error (see $W/equiv.log)"; exit 1; }
summary="$(grep -E "Of those cells [0-9]+ are proven and [0-9]+ are unproven" "$W/equiv.log" | tail -1)"
[ -n "$summary" ] || { echo "FAIL core equivalence: no equiv_status summary (see $W/equiv.log)"; exit 1; }
echo "$summary"
n_unproven="$(echo "$summary" | awk '{print $(NF-2)}')"
# "Unproven $equiv <cell>: <escape>name_gold [bit] <escape>name_gate [bit]": keep name
unproven="$(grep -E '^ *Unproven ' "$W/equiv.log" | awk '{print $4}' | sed -e 's/^.//' -e 's/_gold$//' | sort -u | xargs)"
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
