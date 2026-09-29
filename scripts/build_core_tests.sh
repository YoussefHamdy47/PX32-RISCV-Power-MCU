#!/usr/bin/env bash
# Build every core test program (sw/tests/core/*.S) into ITCM/DTCM images for tb_core.
# Outputs go to tb/core/programs/ and are committed, so regression does not need the
# toolchain. Rebuild after changing a test or crt0/link.ld.

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
for src in sw/tests/core/*.S; do
  name="$(basename "$src" .S)"
  "$GCC" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
         -T sw/common/link.ld -I sw/common sw/common/crt0.S "$src" -o "sim/prog/$name.elf"
  "$BIN/riscv-none-elf-objdump" -d -M no-aliases,numeric "sim/prog/$name.elf" > "sim/prog/$name.dis"
  "$PY" scripts/elf2hex.py "sim/prog/$name.elf" "$OUT/$name"
  echo "$name" >> "$OUT/list.txt"
  echo "built $name"
done
