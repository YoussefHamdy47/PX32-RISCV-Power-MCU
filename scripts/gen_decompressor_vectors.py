#!/usr/bin/env python3
"""Golden model and exhaustive test vectors for px_decompressor (RV32C, C extension 2.0).

Written independently of the RTL: immediates are decoded with the scatter tables from
the specification ("instruction bit -> immediate bit"), the expansion is expressed as an
assembler-level instruction (mnemonic and operands), and a separate generic encoder
produces the 32-bit word. The RTL instead gathers bits directly into the target fields.

Outputs
  tb/unit/vectors/decompressor_vectors.hex, one line per input:
      [79:72] id (see decompressor_ids.txt)   [71:40] input window
      [39:8]  expected instr_o                 [1] is_compressed   [0] illegal
    The first line holds the number of ids in [79:72] and the vector count in [71:40].
    Every 16-bit value appears once (with random upper bits, which must be ignored),
    followed by 32-bit pass-through words.

Cross-check against GNU binutils: every compressed word and its expansion are
disassembled at the same address, and the compressed form (for example
"c.addi x8,1") must mean the same instruction as the expansion ("addi x8,x8,1"),
operands included. Documented differences are listed in EXPECTED; anything else fails.

Run: python scripts/gen_decompressor_vectors.py [--no-objdump]
"""

import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tb" / "unit" / "vectors" / "decompressor_vectors.hex"
IDS_OUT = ROOT / "tb" / "unit" / "vectors" / "decompressor_ids.txt"
TOOLCHAIN_DIRS = [Path(r"C:\xpack\xpack-riscv-none-elf-gcc-15.2.0-1\bin")]

IDS = ["pass32", "c.addi4spn", "c.lw", "c.sw", "c.addi", "c.jal", "c.li", "c.addi16sp", "c.lui",
       "c.srli", "c.srai", "c.andi", "c.sub", "c.xor", "c.or", "c.and", "c.j", "c.beqz", "c.bnez",
       "c.slli", "c.lwsp", "c.jr", "c.mv", "c.ebreak", "c.jalr", "c.add", "c.swsp",
       "illegal:reserved", "illegal:float", "illegal:rv64-or-custom"]


def bit(w, i):
    return (w >> i) & 1


def field(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def scatter(w, table):
    """table: list of (inst_hi, inst_lo, imm_hi, imm_lo) exactly as written in the spec."""
    v = 0
    for ih, il, mh, ml in table:
        assert ih - il == mh - ml
        v |= field(w, ih, il) << ml
    return v


def sx(v, n):
    return v - (1 << n) if v >> (n - 1) & 1 else v


def creg(x):
    return 8 + x


# Spec immediate tables (RVC 2.0, RV32).
T_ADDI4SPN = [(12, 11, 5, 4), (10, 7, 9, 6), (6, 6, 2, 2), (5, 5, 3, 3)]
T_LW = [(12, 10, 5, 3), (6, 6, 2, 2), (5, 5, 6, 6)]
T_CI = [(12, 12, 5, 5), (6, 2, 4, 0)]
T_ADDI16SP = [(12, 12, 9, 9), (6, 6, 4, 4), (5, 5, 6, 6), (4, 3, 8, 7), (2, 2, 5, 5)]
T_LUI = [(12, 12, 17, 17), (6, 2, 16, 12)]
T_CJ = [(12, 12, 11, 11), (11, 11, 4, 4), (10, 9, 9, 8), (8, 8, 10, 10), (7, 7, 6, 6),
        (6, 6, 7, 7), (5, 3, 3, 1), (2, 2, 5, 5)]
T_CB = [(12, 12, 8, 8), (11, 10, 4, 3), (6, 5, 7, 6), (4, 3, 2, 1), (2, 2, 5, 5)]
T_LWSP = [(12, 12, 5, 5), (6, 4, 4, 2), (3, 2, 7, 6)]
T_SWSP = [(12, 9, 5, 2), (8, 7, 7, 6)]


def expand(c):
    """Return (id, (mnemonic, operands) or None). Operands use plain ints."""
    q, f3 = field(c, 1, 0), field(c, 15, 13)
    rd, rs2 = field(c, 11, 7), field(c, 6, 2)
    rdp, rs1p = creg(field(c, 4, 2)), creg(field(c, 9, 7))
    if q == 0:
        if f3 == 0:
            imm = scatter(c, T_ADDI4SPN)
            return ("c.addi4spn", ("addi", rdp, 2, imm)) if imm else ("illegal:reserved", None)
        if f3 == 2:
            return "c.lw", ("lw", rdp, rs1p, scatter(c, T_LW))
        if f3 == 6:
            return "c.sw", ("sw", rdp, rs1p, scatter(c, T_LW))
        if f3 == 4:
            return "illegal:reserved", None
        return "illegal:float", None                     # C.FLD, C.FLW, C.FSD, C.FSW
    if q == 1:
        ci = sx(scatter(c, T_CI), 6)
        if f3 == 0:
            return "c.addi", ("addi", rd, rd, ci)          # rd = 0 forms are NOP / HINT
        if f3 == 1:
            return "c.jal", ("jal", 1, sx(scatter(c, T_CJ), 12))
        if f3 == 2:
            return "c.li", ("addi", rd, 0, ci)
        if f3 == 3:
            if rd == 2:
                imm = sx(scatter(c, T_ADDI16SP), 10)
                return ("c.addi16sp", ("addi", 2, 2, imm)) if imm else ("illegal:reserved", None)
            imm = sx(scatter(c, T_LUI), 18)
            return ("c.lui", ("lui", rd, (imm >> 12) & 0xFFFFF)) if imm else ("illegal:reserved", None)
        if f3 == 4:
            sub = field(c, 11, 10)
            shamt = scatter(c, T_CI)
            if sub in (0, 1):
                if bit(c, 12):
                    return "illegal:rv64-or-custom", None
                return ("c.srli", ("srli", rs1p, rs1p, shamt)) if sub == 0 else ("c.srai", ("srai", rs1p, rs1p, shamt))
            if sub == 2:
                return "c.andi", ("andi", rs1p, rs1p, ci)
            if bit(c, 12):
                return "illegal:rv64-or-custom", None     # C.SUBW, C.ADDW, reserved
            op = ["sub", "xor", "or", "and"][field(c, 6, 5)]
            return "c." + op, (op, rs1p, rs1p, rdp)
        if f3 == 5:
            return "c.j", ("jal", 0, sx(scatter(c, T_CJ), 12))
        return ("c.beqz" if f3 == 6 else "c.bnez"), ("beq" if f3 == 6 else "bne", rs1p, 0, sx(scatter(c, T_CB), 9))
    # q == 2
    if f3 == 0:
        if bit(c, 12):
            return "illegal:rv64-or-custom", None
        return "c.slli", ("slli", rd, rd, scatter(c, T_CI))
    if f3 == 2:
        return ("c.lwsp", ("lw", rd, 2, scatter(c, T_LWSP))) if rd else ("illegal:reserved", None)
    if f3 == 4:
        if not bit(c, 12):
            if rs2 == 0:
                return ("c.jr", ("jalr", 0, rd, 0)) if rd else ("illegal:reserved", None)
            return "c.mv", ("add", rd, 0, rs2)
        if rs2 == 0 and rd == 0:
            return "c.ebreak", ("ebreak",)
        if rs2 == 0:
            return "c.jalr", ("jalr", 1, rd, 0)
        return "c.add", ("add", rd, rd, rs2)
    if f3 == 6:
        return "c.swsp", ("sw", rs2, 2, scatter(c, T_SWSP))
    return "illegal:float", None                         # C.FLDSP, C.FLWSP, C.FSDSP, C.FSWSP


# Generic 32-bit encoder, from the base instruction formats.
OPS = {
    "addi": ("I", 0x13, 0), "andi": ("I", 0x13, 7), "slli": ("SH", 0x13, 1, 0x00),
    "srli": ("SH", 0x13, 5, 0x00), "srai": ("SH", 0x13, 5, 0x20), "lw": ("I", 0x03, 2),
    "jalr": ("I", 0x67, 0), "sw": ("S", 0x23, 2), "beq": ("B", 0x63, 0), "bne": ("B", 0x63, 1),
    "jal": ("J", 0x6F), "lui": ("U", 0x37), "add": ("R", 0x33, 0, 0x00), "sub": ("R", 0x33, 0, 0x20),
    "xor": ("R", 0x33, 4, 0x00), "or": ("R", 0x33, 6, 0x00), "and": ("R", 0x33, 7, 0x00),
}


def encode(ins):
    m = ins[0]
    if m == "ebreak":
        return 0x00100073
    fmt = OPS[m]
    kind, opc = fmt[0], fmt[1]
    if kind == "I":
        rd, rs1, imm = ins[1:]
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (fmt[2] << 12) | (rd << 7) | opc
    if kind == "SH":
        rd, rs1, sh = ins[1:]
        return (fmt[3] << 25) | (sh << 20) | (rs1 << 15) | (fmt[2] << 12) | (rd << 7) | opc
    if kind == "R":
        rd, rs1, rs2 = ins[1:]
        return (fmt[3] << 25) | (rs2 << 20) | (rs1 << 15) | (fmt[2] << 12) | (rd << 7) | opc
    if kind == "S":
        rs2, rs1, imm = ins[1:]
        return ((imm >> 5 & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (fmt[2] << 12) | ((imm & 0x1F) << 7) | opc
    if kind == "B":
        rs1, rs2, off = ins[1:]
        o = off & 0x1FFF
        return ((o >> 12 & 1) << 31) | ((o >> 5 & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
               (fmt[2] << 12) | ((o >> 1 & 0xF) << 8) | ((o >> 11 & 1) << 7) | opc
    if kind == "J":
        rd, off = ins[1:]
        o = off & 0x1FFFFF
        return ((o >> 20 & 1) << 31) | ((o >> 1 & 0x3FF) << 21) | ((o >> 11 & 1) << 20) | \
               ((o >> 12 & 0xFF) << 12) | (rd << 7) | opc
    if kind == "U":
        rd, imm20 = ins[1:]
        return (imm20 << 12) | (rd << 7) | opc
    raise AssertionError(m)


def model(window):
    """(id, expected instr_o, is_compressed, illegal) for a 32-bit fetch window."""
    if window & 3 == 3:
        return "pass32", window, 0, 0
    c = window & 0xFFFF
    ident, ins = expand(c)
    if ins is None:
        return ident, c, 1, 1
    return ident, encode(ins), 1, 0


# ---------------------------------------------------------------------------
# Cross-check against GNU binutils
# ---------------------------------------------------------------------------
EXPECTED = {
    "c.unimp": "0x0000 is the defined-illegal compressed encoding",
    "c.addi16sp": "nzimm = 0 is reserved; binutils prints it",
    "c.srli": "shamt[5] = 1 is reserved/custom on RV32; binutils prints the RV64 form",
    "c.srai": "shamt[5] = 1 is reserved/custom on RV32; binutils prints the RV64 form",
    "c.slli": "shamt[5] = 1 is reserved/custom on RV32; binutils prints the RV64 form",
}
# Compressed mnemonic -> function(operand list) giving the equivalent base instruction text.
TRANSFORM = {
    "c.addi": lambda o: ("addi", [o[0], o[0], o[1]]),
    "c.li": lambda o: ("addi", [o[0], "x0", o[1]]),
    "c.lui": lambda o: ("lui", o),
    "c.addi16sp": lambda o: ("addi", [o[0], o[0], o[1]]),
    "c.addi4spn": lambda o: ("addi", o),
    "c.srli": lambda o: ("srli", [o[0], o[0], o[1]]),
    "c.srai": lambda o: ("srai", [o[0], o[0], o[1]]),
    "c.slli": lambda o: ("slli", [o[0], o[0], o[1]]),
    "c.srli64": lambda o: ("srli", [o[0], o[0], "0"]),
    "c.srai64": lambda o: ("srai", [o[0], o[0], "0"]),
    "c.slli64": lambda o: ("slli", [o[0], o[0], "0"]),
    "c.andi": lambda o: ("andi", [o[0], o[0], o[1]]),
    "c.sub": lambda o: ("sub", [o[0], o[0], o[1]]),
    "c.xor": lambda o: ("xor", [o[0], o[0], o[1]]),
    "c.or": lambda o: ("or", [o[0], o[0], o[1]]),
    "c.and": lambda o: ("and", [o[0], o[0], o[1]]),
    "c.mv": lambda o: ("add", [o[0], "x0", o[1]]),
    "c.add": lambda o: ("add", [o[0], o[0], o[1]]),
    "c.j": lambda o: ("jal", ["x0", o[0]]),
    "c.jal": lambda o: ("jal", ["x1", o[0]]),
    "c.beqz": lambda o: ("beq", [o[0], "x0", o[1]]),
    "c.bnez": lambda o: ("bne", [o[0], "x0", o[1]]),
    "c.jr": lambda o: ("jalr", ["x0", "0(" + o[0] + ")"]),
    "c.jalr": lambda o: ("jalr", ["x1", "0(" + o[0] + ")"]),
    "c.lw": lambda o: ("lw", o), "c.sw": lambda o: ("sw", o),
    "c.lwsp": lambda o: ("lw", o), "c.swsp": lambda o: ("sw", o),
    "c.ebreak": lambda o: ("ebreak", []),
}


def find_tool(name):
    p = shutil.which(name)
    if p:
        return p
    for d in TOOLCHAIN_DIRS:
        if (d / (name + ".exe")).exists():
            return str(d / (name + ".exe"))
    return None


def disassemble(lines, march):
    asm, objdump = find_tool("riscv-none-elf-as"), find_tool("riscv-none-elf-objdump")
    with tempfile.TemporaryDirectory() as tmp:
        src, obj = Path(tmp) / "c.s", Path(tmp) / "c.o"
        src.write_text(".text\n" + "".join(lines))
        subprocess.run([asm, f"-march={march}", "-mabi=ilp32", "-o", str(obj), str(src)], check=True)
        text = subprocess.run([objdump, "-d", "-M", "no-aliases,numeric", str(obj)],
                              check=True, capture_output=True, text=True).stdout
    res = {}
    for line in text.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]{4,8})\s+(\S+)\s*(.*)$", line)
        if m:
            res[int(m.group(1), 16)] = (m.group(3), m.group(4).split("<")[0].split("#")[0].strip())
    return res


def norm(ops):
    """Normalise operand tokens: numbers to int, 'imm(reg)' to (int, reg)."""
    out = []
    for tok in ops:
        tok = tok.strip()
        mm = re.fullmatch(r"(-?(?:0x)?[0-9a-f]+)\((x\d+)\)", tok)
        if mm:
            out.append((int(mm.group(1), 0), mm.group(2)))
        elif re.fullmatch(r"-?(?:0x)?[0-9a-f]+", tok) and not tok.startswith("x"):
            out.append(int(tok, 0) if tok.startswith(("0x", "-0x")) or not re.search("[a-f]", tok) else int(tok, 16))
        else:
            out.append(tok)
    return out


def cross_check(cwords):
    if not find_tool("riscv-none-elf-objdump"):
        print("objdump cross-check: SKIPPED (toolchain not found)")
        return True
    # Each 16-bit word is followed by c.nop so that word i sits at address 4*i in both files.
    comp = disassemble([f".insn 2, 0x{c:04x}\n.insn 2, 0x0001\n" for c in cwords], "rv32imc_zicsr_zifencei")
    legal = [(i, c) for i, c in enumerate(cwords) if model(c)[3] == 0]
    expd = disassemble([f".org {4 * i}\n.insn 4, 0x{model(c)[1]:08x}\n" for i, c in legal], "rv32im_zicsr_zifencei")
    agree, expected_seen, errors = 0, {}, []
    for i, c in enumerate(cwords):
        mn, ops = comp[4 * i]
        ident, _, _, ill = model(c)
        known = not mn.startswith(".")
        if ill:
            if not known:
                agree += 1
            elif mn in EXPECTED:
                expected_seen[mn] = expected_seen.get(mn, 0) + 1
            else:
                errors.append(f"0x{c:04x}: model {ident}, binutils {mn} {ops}")
            continue
        if not known:
            errors.append(f"0x{c:04x}: model {ident}, binutils cannot decode it")
            continue
        base_mn, base_ops = TRANSFORM[mn]([o for o in ops.split(",") if o] if ops else [])
        emn, eops = expd[4 * i]
        if base_mn != emn or norm(base_ops) != norm(eops.split(",") if eops else []):
            errors.append(f"0x{c:04x}: {mn} {ops} -> expected {base_mn} {','.join(base_ops)}, "
                          f"model expansion disassembles as {emn} {eops}")
            continue
        agree += 1
    print(f"objdump cross-check: {agree} of {len(cwords)} compressed words agree "
          f"(legal ones compared operand by operand), "
          f"{sum(expected_seen.values())} expected differences, {len(errors)} unexpected")
    for k, v in sorted(expected_seen.items()):
        print(f"  expected difference: {k:12s} x{v}  ({EXPECTED[k]})")
    for e in errors[:30]:
        print("  MISMATCH " + e)
    return not errors


def main():
    rng = random.Random(0xC0C0A)
    cwords = [c for c in range(0x10000) if c & 3 != 3]
    windows = [(rng.getrandbits(16) << 16) | c for c in cwords]
    for _ in range(3000):
        windows.append(rng.getrandbits(32) | 3)
    lines = [f"{len(IDS):02x}{len(windows):08x}{0:08x}{0:02x}"]
    counts = {}
    for w in windows:
        ident, out, comp, ill = model(w)
        counts[ident] = counts.get(ident, 0) + 1
        lines.append(f"{IDS.index(ident):02x}{w:08x}{out:08x}{(comp << 1) | ill:02x}")
    OUT.write_text("\n".join(lines) + "\n")
    IDS_OUT.write_text("".join(f"{i} {n} {counts.get(n, 0)}\n" for i, n in enumerate(IDS)))
    print(f"wrote {len(windows)} vectors ({len(cwords)} compressed, exhaustive) to {OUT.relative_to(ROOT)}")
    missing = [n for n in IDS if not counts.get(n)]
    if missing:
        print("ERROR: ids never produced:", missing)
        sys.exit(1)
    ok = True if "--no-objdump" in sys.argv else cross_check(cwords)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
