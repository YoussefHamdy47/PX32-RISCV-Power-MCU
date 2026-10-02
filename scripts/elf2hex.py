#!/usr/bin/env python3
"""Convert a PX32 test ELF into ITCM and DTCM images for $readmemh.

Reads the ELF32 program headers directly (standard library only) and places every
PT_LOAD segment into the 64 KB ITCM (0x1000_0000) or 64 KB DTCM (0x2000_0000) image.
Each output file is a sparse $readmemh image of the 16384 little-endian 32-bit words: only
nonzero words are written, one per line, each run preceded by @<word index> (hex). The
loader must clear the memory first (tb_core and scripts/px_iss.py do).

Usage: python scripts/elf2hex.py prog.elf out_prefix
       -> out_prefix.itcm.hex, out_prefix.dtcm.hex
"""

import struct
import sys
from pathlib import Path

REGIONS = {"itcm": 0x10000000, "dtcm": 0x20000000}
SIZE = 64 * 1024


def main():
    elf = Path(sys.argv[1]).read_bytes()
    prefix = sys.argv[2]
    if elf[:4] != b"\x7fELF" or elf[4] != 1 or elf[5] != 1:
        sys.exit("not a little-endian ELF32 file")
    e_phoff = struct.unpack_from("<I", elf, 28)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", elf, 42)
    images = {name: bytearray(SIZE) for name in REGIONS}
    for i in range(e_phnum):
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = \
            struct.unpack_from("<IIIIII", elf, e_phoff + i * e_phentsize)
        if p_type != 1 or p_memsz == 0:          # PT_LOAD only
            continue
        for name, base in REGIONS.items():
            if base <= p_paddr < base + SIZE:
                off = p_paddr - base
                if off + p_memsz > SIZE:
                    sys.exit(f"segment at 0x{p_paddr:08x} overflows {name}")
                images[name][off:off + p_filesz] = elf[p_offset:p_offset + p_filesz]
                break
        else:
            sys.exit(f"segment at 0x{p_paddr:08x} is outside ITCM/DTCM")
    for name, img in images.items():
        words = struct.unpack(f"<{SIZE // 4}I", img)
        out, nxt = [], -1
        for k, w in enumerate(words):
            if w == 0:
                continue
            if k != nxt:
                out.append(f"@{k:x}")
            out.append(f"{w:08x}")
            nxt = k + 1
        if not out:                              # all zero: one explicit word
            out = ["@0", "00000000"]
        Path(f"{prefix}.{name}.hex").write_bytes(("\n".join(out) + "\n").encode())


if __name__ == "__main__":
    main()
