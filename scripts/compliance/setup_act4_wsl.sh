#!/usr/bin/env bash
# Build the riscv-arch-test 4.1.0 (ACT4) ELFs for PX32 inside WSL2 Ubuntu 24.04 (step 1.8).
#
# Tools (owner-approved list, DECISIONS.md D-024; deviations recorded there):
#   system packages (installed by the owner with sudo; this script never uses sudo):
#     sudo apt-get update && sudo apt-get install -y make ruby ruby-bundler ruby-dev build-essential
#     git, python3 (3.12) and curl ship with the Ubuntu 24.04 WSL image
#   uv 0.11.33 (the suite's .mise.toml pin), Python 3.12 from Ubuntu (the framework requires
#     >= 3.10; the suite's .python-version asks for 3.14, which uv would download)
#   Ruby 3.2 from Ubuntu (the UDB Gemfile requires "~> 3.2"; .mise.toml pins 3.4.10 via mise,
#     not used); UDB gems as locked by framework/src/act/data/Gemfile.lock. Several locked gems
#     (nkf, json, bigdecimal, ...) compile native extensions and need the Ruby headers (ruby-dev)
#   Sail 0.13.1 Linux x86_64 release -> ~/px32-tools/sail: the version the 4.1.0 framework
#     requires (REQUIRED_SAIL_VERSION in framework/src/act/config.py; README and Dockerfile
#     at the tag agree). Any other version stops the build
#   riscv-arch-test 4.1.0 (6e8a45123f14cebfb3df151a0e7b849b4389b33b), cloned locally from the
#     Windows checkout C:\px32-tools\src\riscv-arch-test (LF line endings)
#   compiler: the Windows xPack riscv-none-elf-gcc 15.2.0-1 through scripts/compliance/
#     wsl_wingcc.sh (path-translating wrapper); the Linux build of the same version could not
#     be downloaded over the slow link in that session
#
# Usage (inside Ubuntu):
#   bash /mnt/c/<path to the repository>/scripts/compliance/setup_act4_wsl.sh
# then on Windows:
#   python scripts/compliance/run_act4.py --elf-dir C:/px32-tools/act4-elfs

set -euo pipefail
T="$HOME/px32-tools"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH_TEST_COMMIT=6e8a45123f14cebfb3df151a0e7b849b4389b33b
SAIL_VER=0.13.1
UV_VER=0.11.33
mkdir -p "$T" && cd "$T"

missing=""
for t in git make python3 curl gcc ruby bundle; do command -v "$t" >/dev/null || missing="$missing $t"; done
[ -f "$(ruby -e 'print RbConfig::CONFIG["rubyhdrdir"]' 2>/dev/null)/ruby.h" ] || missing="$missing ruby-dev(headers)"
if [ -n "$missing" ]; then
  echo "missing system packages:$missing"
  echo "run: sudo apt-get update && sudo apt-get install -y make ruby ruby-bundler ruby-dev build-essential"
  exit 2
fi

# Sail reference model
if [ "$("$T/sail/bin/sail_riscv_sim" --version 2>/dev/null)" != "$SAIL_VER" ]; then
  curl -fL -o "sail-$SAIL_VER.tgz" "https://github.com/riscv/sail-riscv/releases/download/$SAIL_VER/sail-riscv-Linux-x86_64.tar.gz"
  sha256sum "sail-$SAIL_VER.tgz" | tee "sail-$SAIL_VER.sha256"
  rm -rf sail && mkdir -p sail && tar -xzf "sail-$SAIL_VER.tgz" -C sail --strip-components=1
fi
test "$("$T/sail/bin/sail_riscv_sim" --version)" = "$SAIL_VER"

# uv
command -v "$HOME/.local/bin/uv" >/dev/null || curl -LsSf "https://astral.sh/uv/$UV_VER/install.sh" | sh

# compiler wrapper
W="$T/gccwrap"; mkdir -p "$W"
tr -d '\r' < "$REPO/scripts/compliance/wsl_wingcc.sh" > "$W/wsl_wingcc.sh"; chmod +x "$W/wsl_wingcc.sh"
for t in gcc as ld ar objcopy objdump nm; do ln -sf wsl_wingcc.sh "$W/riscv-none-elf-$t"; done

# suite
if [ ! -d "$T/riscv-arch-test/.git" ]; then
  git clone -q --no-checkout /mnt/c/px32-tools/src/riscv-arch-test riscv-arch-test
  git -C riscv-arch-test -c core.autocrlf=false checkout -q "$ARCH_TEST_COMMIT"
fi
test "$(git -C riscv-arch-test rev-parse HEAD)" = "$ARCH_TEST_COMMIT"

export PATH="$W:$T/sail/bin:$HOME/.local/bin:$PATH"
export UV_PYTHON=/usr/bin/python3.12 UV_PYTHON_DOWNLOADS=never
export BUNDLE_PATH="$T/gems"

cd riscv-arch-test
uv sync
(cd framework/src/act/data && bundle install)

# PX32 DUT configuration (generated on Windows by make_act4_config.py) and the build
rm -rf config/cores/px32 && mkdir -p config/cores/px32
cp -r "$REPO/sw/compliance/act4/px32" config/cores/px32/px32
find config/cores/px32 -type f -exec sed -i 's/\r$//' {} +
# Exclusions: the suite's defaults (Sdtrig*, debug triggers) plus InterruptsSm, which needs an
# interrupt source; PX32 has none before the Phase 2 CLIC (mie/mip read 0, D-022). Revisit in 2.2.
EXCLUDE=SdtrigSm,SdtrigS,SdtrigU,InterruptsSm
make CONFIG_FILES=config/cores/px32/px32/test_config.yaml \
     EXCLUDE_EXTENSIONS="$EXCLUDE" --jobs "$(nproc)"

# hand the ELFs to Windows, with a manifest that ties them to this configuration:
# run_act4.py refuses an ELF set whose manifest does not match the repository's
# sw/compliance/act4/px32 files (ELFs built from an older configuration are stale)
out=/mnt/c/px32-tools/act4-elfs
rm -rf "$out" && mkdir -p "$out"
find work -name '*.elf' -path '*elfs*' -exec cp {} "$out/" \;
{
  echo "suite $ARCH_TEST_COMMIT"
  echo "sail $("$T/sail/bin/sail_riscv_sim" --version)"
  echo "exclude $EXCLUDE"
  for f in $(cd config/cores/px32/px32 && ls | LC_ALL=C sort); do
    echo "config $f $(sha256sum < "config/cores/px32/px32/$f" | cut -d' ' -f1)"
  done
} > "$out/MANIFEST.txt"
echo "ELFs copied to $out: $(ls "$out"/*.elf | wc -l)"
