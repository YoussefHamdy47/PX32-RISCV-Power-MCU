#!/usr/bin/env python3
"""Convert a compliance-test ELF into one $readmemh image of the tb_compliance memory.

The memory is 1 MB at 0x1000_0000 (262,144 little-endian 32-bit words, one per line).
Every PT_LOAD segment must lie inside it; anything else is an error (fail closed).
Also prints the address of a symbol when asked, from the ELF symbol table.

Usage: python scripts/compliance/elf2mem.py prog.elf out.hex [symbol ...]
       prints "<symbol> <hex address>" per requested symbol; exits 1 if one is missing
"""

import struct
import sys
from pathlib import Path

BASE, SIZE = 0x10000000, 1024 * 1024


def symbols(elf):
    e_shoff = struct.unpack_from("<I", elf, 32)[0]
    e_shentsize, e_shnum = struct.unpack_from("<HH", elf, 46)
    secs = [struct.unpack_from("<IIIIIIIIII", elf, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    out = {}
    for s in secs:
        if s[1] != 2:                                   # SHT_SYMTAB
            continue
        strtab = secs[s[6]]
        for k in range(s[5] // 16):
            st_name, st_value = struct.unpack_from("<II", elf, s[4] + 16 * k)
            n = elf[strtab[4] + st_name:elf.index(b"\0", strtab[4] + st_name)].decode()
            if n:
                out[n] = st_value
    return out


def main():
    elf = Path(sys.argv[1]).read_bytes()
    if elf[:4] != b"\x7fELF" or elf[4] != 1 or elf[5] != 1:
        sys.exit("not a little-endian ELF32 file")
    e_phoff = struct.unpack_from("<I", elf, 28)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", elf, 42)
    image = bytearray(SIZE)
    loaded = 0
    for i in range(e_phnum):
        p_type, p_offset, _, p_paddr, p_filesz, p_memsz = \
            struct.unpack_from("<IIIIII", elf, e_phoff + i * e_phentsize)
        if p_type != 1 or p_memsz == 0:
            continue
        if not (BASE <= p_paddr and p_paddr + p_memsz <= BASE + SIZE):
            sys.exit(f"segment 0x{p_paddr:08x}+{p_memsz} outside the compliance memory")
        image[p_paddr - BASE:p_paddr - BASE + p_filesz] = elf[p_offset:p_offset + p_filesz]
        loaded += 1
    if loaded == 0:
        sys.exit("no loadable segment")
    words = ["%08x" % int.from_bytes(image[k:k + 4], "little") for k in range(0, SIZE, 4)]
    Path(sys.argv[2]).write_bytes(("\n".join(words) + "\n").encode())
    syms = symbols(elf)
    missing = False
    for name in sys.argv[3:]:
        if name in syms:
            print(f"{name} {syms[name]:08x}")
        else:
            print(f"{name} MISSING")
            missing = True
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
