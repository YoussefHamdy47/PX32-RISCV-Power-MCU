#!/usr/bin/env bash
# Run the Spike reference (DECISIONS.md D-026 configuration) on a list of ELFs, inside WSL.
# Called by scripts/compliance/run_trace_compare.py; the Spike configuration lives only here.
#
# Job file: one job per line:
#   <elf> <map> <halt address, 8 hex digits> <max log lines> <output .log.gz>
#   map compliance: one 1 MB RWX region at 0x1000_0000 (tb_compliance)
#   map core:       ITCM 64 KB at 0x1000_0000 and DTCM 64 KB at 0x2000_0000 (tb_compliance
#                   +core_map, the tb_core map without its side-effect device)
# Spike options (D-026):
#   --isa=rv32imc_zicsr_zifencei --priv=m      PX32 Phase 1 ISA, machine mode only
#   --pmpregions=0 --triggers=0                 no PMP entries, no trigger module
#   --disable-dtb --pc=0x10000000               no boot ROM, no device tree, no CLINT/PLIC/UART:
#                                               execution starts at the PX32 reset address with
#                                               every register zero, like px_core
#   --wfi-as-nop                                WFI retires as a NOP (PX32 behaviour)
#   -l --log-commits                            the trace: disassembly, commits, exceptions
# The log is piped through a filter that ends the run after the commit that stores a nonzero
# word to the halt address (Spike's HTIF only stops programs with tohost/fromhost symbols;
# the ACT4 ELFs and the random programs have none), or after <max log lines> (the log then
# has no halt store and the comparison fails). Spike's --instructions option is not used: it
# counts scheduler steps, a trap ends a step early, and with a limit below 5,000 Spike stops
# at the first trap.
# Usage: bash run_spike_wsl.sh <job file> [parallel jobs]

set -euo pipefail
SPIKE="$HOME/px32-tools/spike/bin/spike"
STAMP="$HOME/px32-tools/spike/PX32_BUILD.txt"
COMMIT=609dbe0b9994154833039209fa37151e7c05e9d4
JOBS="$1"
PAR="${2:-8}"

grep -qx "commit $COMMIT" "$STAMP" || { echo "spike is not the pinned build ($STAMP)"; exit 1; }
grep -qx "sha256 $(sha256sum "$SPIKE" | cut -d' ' -f1)" "$STAMP" || { echo "spike binary differs from $STAMP"; exit 1; }

run_one() {
  local elf="$1" map="$2" halt="$3" maxl="$4" out="$5" mem err h
  case "$map" in
    compliance) mem=0x10000000:0x100000 ;;
    core)       mem=0x10000000:0x10000,0x20000000:0x10000 ;;
    *)          echo "unknown map $map" > "${out%.log.gz}.stderr"; return 0 ;;
  esac
  err="${out%.log.gz}.stderr"
  h='[0-9a-f]'
  # Spike ends on SIGPIPE once the filter has exited; its stderr goes to <out>.stderr
  { "$SPIKE" --isa=rv32imc_zicsr_zifencei --priv=m --pmpregions=0 --triggers=0 --disable-dtb \
      --pc=0x10000000 -m"$mem" --wfi-as-nop -l --log-commits --log=/dev/stdout "$elf" \
      2> "$err" || true; } \
    | awk -v pat="mem 0x$halt 0x$h$h$h$h$h$h$h$h\$" -v maxl="$maxl" \
        '{ print } ($0 ~ pat && $NF != "0x00000000") || NR >= maxl { exit }' \
    | gzip -c > "$out"
}
export -f run_one
export SPIKE
xargs -P "$PAR" -L 1 bash -c 'run_one "$@"' _ < "$JOBS"
