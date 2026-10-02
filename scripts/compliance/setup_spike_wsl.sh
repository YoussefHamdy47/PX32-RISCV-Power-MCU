#!/usr/bin/env bash
# Build the Spike reference simulator (riscv-isa-sim) for the step 1.9 trace comparison
# inside WSL2 Ubuntu 24.04 (DECISIONS.md D-025, D-026).
#
# Pinned source: riscv-software-src/riscv-isa-sim 609dbe0b9994154833039209fa37151e7c05e9d4,
#   cloned at ~/px32-tools/riscv-isa-sim (the script checks the commit and refuses local edits)
# Install prefix: ~/px32-tools/spike (bin/spike)
# Configure: --prefix=<install> --without-boost --without-boost-asio --without-boost-regex
#   (Boost only serves Spike's optional socket command server, not used here)
# System packages (already on the WSL image or installed by the owner; this script never uses
#   sudo): g++, make, device-tree-compiler. If one is missing the script stops and prints:
#     sudo apt-get update && sudo apt-get install -y build-essential device-tree-compiler
#
# Idempotent: an install whose recorded commit and configure line match is kept as it is.
# Writes ~/px32-tools/spike/PX32_BUILD.txt (commit, configure line, compiler, binary SHA-256).
#
# Usage (inside Ubuntu): bash /mnt/c/<path to the repository>/scripts/compliance/setup_spike_wsl.sh

set -euo pipefail
T="$HOME/px32-tools"
SRC="$T/riscv-isa-sim"
PREFIX="$T/spike"
COMMIT=609dbe0b9994154833039209fa37151e7c05e9d4
CONF="--prefix=$PREFIX --without-boost --without-boost-asio --without-boost-regex"

missing=""
for t in git g++ make dtc; do command -v "$t" >/dev/null || missing="$missing $t"; done
if [ -n "$missing" ]; then
  echo "missing system packages:$missing"
  echo "run: sudo apt-get update && sudo apt-get install -y build-essential device-tree-compiler"
  exit 2
fi

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/riscv-software-src/riscv-isa-sim.git "$SRC"
fi
cd "$SRC"
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  git fetch origin "$COMMIT" 2>/dev/null || true
  git checkout --detach "$COMMIT"
fi
test "$(git rev-parse HEAD)" = "$COMMIT"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "local modifications in $SRC; refusing to build a modified reference"
  exit 1
fi

STAMP="$PREFIX/PX32_BUILD.txt"
if [ -x "$PREFIX/bin/spike" ] && [ -f "$STAMP" ] \
   && grep -qx "commit $COMMIT" "$STAMP" && grep -qxF "configure $CONF" "$STAMP" \
   && grep -qx "sha256 $(sha256sum "$PREFIX/bin/spike" | cut -d' ' -f1)" "$STAMP"; then
  echo "spike already built at $COMMIT"
  cat "$STAMP"
  exit 0
fi

rm -rf "$T/spike-build"
mkdir -p "$T/spike-build"
cd "$T/spike-build"
# shellcheck disable=SC2086
"$SRC/configure" $CONF > configure.log 2>&1
make -j"$(nproc)" > make.log 2>&1
make install > install.log 2>&1

{
  echo "commit $COMMIT"
  echo "configure $CONF"
  echo "compiler $(g++ --version | head -1)"
  echo "dtc $(dtc --version)"
  echo "sha256 $(sha256sum "$PREFIX/bin/spike" | cut -d' ' -f1)"
} > "$STAMP"
cat "$STAMP"
"$PREFIX/bin/spike" --help 2>&1 | head -3 || true
