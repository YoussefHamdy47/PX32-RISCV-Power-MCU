#!/usr/bin/env bash
# Build every core test program (sw/tests/core/*.S, then the generated random programs in
# sw/tests/random/*.S and the long ones in sw/tests/random_long/*.S) into ITCM/DTCM images for
# tb_core, and run the reference model
# (scripts/px_iss.py) on each image to produce the expected retirement trace and trap list.
# Outputs go to tb/core/programs/ and are committed, so regression does not need the
# toolchain. Rebuild after changing a test, crt0/link.ld or the reference model.

set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${RISCV_BIN:-/c/xpack/xpack-riscv-none-elf-gcc-15.2.0-1/bin}"
GCC="$BIN/riscv-none-elf-gcc"
PY="${LOCALAPPDATA:-}/Programs/Python/Python312/python.exe"
[ -x "$PY" ] || PY="$(command -v python3 || command -v python)"

OUT=tb/core/programs
mkdir -p "$OUT" sim/prog
: > "$OUT/list.txt"
: > "$OUT/list_random.txt"
: > "$OUT/list_random_long.txt"
: > "$OUT/list_irq.txt"
for src in sw/tests/core/*.S sw/tests/random/*.S sw/tests/random_long/*.S; do
  [ -f "$src" ] || continue
  name="$(basename "$src" .S)"
  # Interrupt programs (step 2.2b, D-033): crt0 resumes after interrupts, and the boundary
  # of each take depends on memory timing, so px_iss checks every run afterwards from the
  # bench's event log (px_iss.py --replay) instead of producing a reference now.
  irq=""
  grep -q "px-build: irq" "$src" && irq="-DPX_IRQ_RESUME"
  "$GCC" -march=rv32imc_zicsr_zifencei_zba_zbb_zbs_zicond -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
         $irq -T sw/common/link.ld -I sw/common sw/common/crt0.S "$src" -o "sim/prog/$name.elf"
  "$BIN/riscv-none-elf-objdump" -d -M no-aliases,numeric "sim/prog/$name.elf" > "sim/prog/$name.dis"
  "$PY" scripts/elf2hex.py "sim/prog/$name.elf" "$OUT/$name"
  if [ -n "$irq" ]; then
    # handler and vector-table alignment (D-029, D-035 item 23)
    "$PY" scripts/check_align.py "sim/prog/$name.elf"
    rm -f "$OUT/$name.trace.ref" "$OUT/$name.traps.ref"
    printf 'checked by scripts/px_iss.py --replay (interrupt program, D-033)\n' > "$OUT/$name.replay"
  else
    rm -f "$OUT/$name.replay"
    "$PY" scripts/px_iss.py "$OUT/$name"
  fi
  case "$src" in
    sw/tests/random/*) echo "$name" >> "$OUT/list_random.txt" ;;
    sw/tests/random_long/*) echo "$name" >> "$OUT/list_random_long.txt" ;;
    sw/tests/core/*_clic_*) echo "$name" >> "$OUT/list_irq.txt" ;;   # tb_core_irq (D-035)
    *)                 echo "$name" >> "$OUT/list.txt" ;;
  esac
  echo "built $name"
done
