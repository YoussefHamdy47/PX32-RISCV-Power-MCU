#!/usr/bin/env python3
"""Alignment check of interrupt handlers in a linked PX32 test program (DECISIONS.md D-029
items 3-4, D-035 item 23).

The 6-cycle vectored-entry budget holds for handlers whose first instruction is word
aligned; a 32-bit first instruction at a halfword offset costs one more cycle. The check
reads the ELF symbol table and the .vectab section (standard library only) and requires:
  - every symbol named isr_* at an address divisible by 4
  - every symbol named exempt_halfword_* at a halfword offset (address % 4 == 2): the
    deliberate negative test, so the exemption cannot hide an aligned handler
  - the .vectab section 64-byte aligned (mtvt holds bits 31:6)
  - every .vectab entry, with bit 0 ignored (the hardware clears it), divisible by 4,
    unless it is the address of an exempt_halfword_* symbol
Programs without .vectab and without such symbols pass trivially.

Usage: python scripts/check_align.py prog.elf [...]
Exit status 1 if any program violates a rule.
"""

import struct
import sys
from pathlib import Path


def sections(elf):
    e_shoff = struct.unpack_from("<I", elf, 32)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", elf, 46)
    hdrs = [struct.unpack_from("<IIIIIIIIII", elf, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    strtab = hdrs[e_shstrndx]

    def name(off, tab):
        start = tab[4] + off
        return elf[start:elf.index(b"\0", start)].decode()

    return [(name(h[0], strtab), h) for h in hdrs]


def check(path):
    elf = Path(path).read_bytes()
    if elf[:4] != b"\x7fELF" or elf[4] != 1 or elf[5] != 1:
        return [f"{path}: not a little-endian ELF32 file"]
    secs = sections(elf)
    errs = []
    syms = {}
    for _, h in secs:
        if h[1] != 2:                              # SHT_SYMTAB
            continue
        strh = secs[h[6]][1]                       # sh_link: its string table
        for k in range(h[5] // 16):
            st_name, st_value, _, st_info, _, st_shndx = struct.unpack_from("<IIIBBH", elf, h[4] + 16 * k)
            if st_shndx == 0 or (st_info & 0xF) == 4:      # undefined, or STT_FILE
                continue
            start = strh[4] + st_name
            syms[elf[start:elf.index(b"\0", start)].decode()] = st_value
    exempt = {v for n, v in syms.items() if n.startswith("exempt_halfword_")}
    for n, v in sorted(syms.items()):
        if n.startswith("isr_") and v % 4:
            errs.append(f"{path}: {n} at {v:08x} is not word aligned")
        if n.startswith("exempt_halfword_") and v % 4 != 2:
            errs.append(f"{path}: {n} at {v:08x} is not at a halfword offset (the negative test is void)")
    for n, h in secs:
        if n != ".vectab":
            continue
        addr, off, size = h[3], h[4], h[5]
        if addr % 64:
            errs.append(f"{path}: .vectab at {addr:08x} is not 64-byte aligned")
        for k in range(size // 4):
            w = struct.unpack_from("<I", elf, off + 4 * k)[0] & ~1
            if w % 4 and w not in exempt:
                errs.append(f"{path}: .vectab entry {k} ({addr + 4 * k:08x}) = {w:08x} is not word aligned")
    return errs


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    errs = []
    for p in sys.argv[1:]:
        errs += check(p)
    for e in errs:
        print(f"ERROR {e}")
    if errs:
        sys.exit(1)
    print(f"check_align: {len(sys.argv) - 1} programs OK")


if __name__ == "__main__":
    main()
