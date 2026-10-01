#!/usr/bin/env bash
# Run the Windows xPack riscv-none-elf toolchain (15.2.0-1, the project's pinned compiler) from
# WSL, translating Linux paths in the arguments to Windows paths (D-024).
#
# Install: symlink this script as riscv-none-elf-gcc / riscv-none-elf-objdump / ... in a
# directory on the WSL PATH; the link name selects the Windows tool. Translated:
#   - plain arguments that are absolute Linux paths (existing, or whose directory exists)
#   - -I/-T/-L/-o<path> prefixes, and -DNAME="<absolute path>" macro values
#   - output of -print-prog-name=<tool>: a Windows path, returned as the WSL path of a
#     symlink to this wrapper, so the caller can run that tool and get translation again
# Used because the Linux build of the same toolchain could not be downloaded over the slow
# link available in the step 1.8 session (about 25 KB/s).
set -euo pipefail
WIN_BIN="${PX32_WIN_GCC_BIN:-/mnt/c/xpack/xpack-riscv-none-elf-gcc-15.2.0-1/bin}"
self_dir="$(cd "$(dirname "$0")" && pwd)"
tool="$(basename "$0")"
exe="$WIN_BIN/$tool.exe"
[ -x "$exe" ] || { echo "wsl_wingcc: no $exe" >&2; exit 127; }

win() {  # absolute Linux path -> Windows path with forward slashes
  wslpath -m "$1"
}
is_path() {
  [[ "$1" == /* ]] && { [ -e "$1" ] || [ -d "$(dirname "$1")" ]; }
}

args=()
for a in "$@"; do
  if [[ "$a" == -print-prog-name=* ]]; then
    name="${a#-print-prog-name=}"
    case "$name" in
      as|ld|ar|objcopy|objdump|nm) echo "$self_dir/riscv-none-elf-$name"; exit 0 ;;
    esac
  fi
  if [[ "$a" =~ ^(-I|-T|-L|-o)(/.*)$ ]]; then
    args+=("${BASH_REMATCH[1]}$(win "${BASH_REMATCH[2]}")")
  elif [[ "$a" =~ ^(-D[A-Za-z_][A-Za-z0-9_]*=\")(/[^\"]*)(\")$ ]]; then
    args+=("${BASH_REMATCH[1]}$(win "${BASH_REMATCH[2]}")${BASH_REMATCH[3]}")
  elif is_path "$a"; then
    args+=("$(win "$a")")
  else
    args+=("$a")
  fi
done
exec "$exe" "${args[@]}"
