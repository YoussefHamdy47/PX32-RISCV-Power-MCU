#!/usr/bin/env python3
"""Golden model and test vectors for px_decoder (Phase 1: RV32I, M, Zicsr, Zifencei).

The model is written independently of the RTL: each instruction is identified by a
(mask, match) pair, in the style of the official riscv-opcodes tables, and its control
fields come from a per-mnemonic attribute table. The RTL instead uses opcode/funct case
statements.

Two outputs:
  1. tb/unit/vectors/decoder_vectors.hex: one line per instruction word:
       [143:136] mnemonic id (0 = illegal; names listed in decoder_mnemonics.txt)
       [135:104] instruction word
       [100:0]   expected px_pkg::decode_t (bit layout mirrored in FIELDS below)
     The first line holds the number of mnemonic ids in [143:136] and the vector
     count in [135:104].
  2. A cross-check against GNU binutils: every word is disassembled with
     riscv-none-elf-objdump (-M no-aliases,numeric). The model's mnemonic and operands
     must agree with the disassembler, except for the documented differences in
     EXPECTED_DIFFERENCES. Any other disagreement makes the script exit with status 1.

Run:  python scripts/gen_decoder_vectors.py  [--no-objdump]
"""

import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tb" / "unit" / "vectors" / "decoder_vectors.hex"
NAMES = ROOT / "tb" / "unit" / "vectors" / "decoder_mnemonics.txt"
TOOLCHAIN_DIRS = [Path(r"C:\xpack\xpack-riscv-none-elf-gcc-15.2.0-1\bin")]

# ---------------------------------------------------------------------------
# ISA table: mnemonic -> (mask, match). Unprivileged ISA 20240411 and the
# machine-mode instructions MRET/WFI from the privileged ISA.
# ---------------------------------------------------------------------------
R = 0xFE00707F    # funct7 + funct3 + opcode
I = 0x0000707F    # funct3 + opcode
U = 0x0000007F    # opcode only
EXACT = 0xFFFFFFFF

ISA = {
    "lui": (U, 0x37), "auipc": (U, 0x17), "jal": (U, 0x6F), "jalr": (I, 0x67),
    "beq": (I, 0x0063), "bne": (I, 0x1063), "blt": (I, 0x4063),
    "bge": (I, 0x5063), "bltu": (I, 0x6063), "bgeu": (I, 0x7063),
    "lb": (I, 0x0003), "lh": (I, 0x1003), "lw": (I, 0x2003), "lbu": (I, 0x4003), "lhu": (I, 0x5003),
    "sb": (I, 0x0023), "sh": (I, 0x1023), "sw": (I, 0x2023),
    "addi": (I, 0x0013), "slti": (I, 0x2013), "sltiu": (I, 0x3013),
    "xori": (I, 0x4013), "ori": (I, 0x6013), "andi": (I, 0x7013),
    "slli": (R, 0x00001013), "srli": (R, 0x00005013), "srai": (R, 0x40005013),
    "add": (R, 0x00000033), "sub": (R, 0x40000033), "sll": (R, 0x00001033),
    "slt": (R, 0x00002033), "sltu": (R, 0x00003033), "xor": (R, 0x00004033),
    "srl": (R, 0x00005033), "sra": (R, 0x40005033), "or": (R, 0x00006033), "and": (R, 0x00007033),
    "mul": (R, 0x02000033), "mulh": (R, 0x02001033), "mulhsu": (R, 0x02002033), "mulhu": (R, 0x02003033),
    "div": (R, 0x02004033), "divu": (R, 0x02005033), "rem": (R, 0x02006033), "remu": (R, 0x02007033),
    "fence": (I, 0x000F), "fence.i": (I, 0x100F),
    "ecall": (EXACT, 0x00000073), "ebreak": (EXACT, 0x00100073),
    "mret": (EXACT, 0x30200073), "wfi": (EXACT, 0x10500073),
    "csrrw": (I, 0x1073), "csrrs": (I, 0x2073), "csrrc": (I, 0x3073),
    "csrrwi": (I, 0x5073), "csrrsi": (I, 0x6073), "csrrci": (I, 0x7073),
}
MNEMONICS = ["illegal"] + list(ISA)          # id = index

ALU = {"add": 0, "sub": 1, "sll": 2, "slt": 3, "sltu": 4, "xor": 5, "srl": 6, "sra": 7, "or": 8, "and": 9}
ALU_IMM = {"addi": "add", "slti": "slt", "sltiu": "sltu", "xori": "xor", "ori": "or", "andi": "and",
           "slli": "sll", "srli": "srl", "srai": "sra"}
OPA_RS1, OPA_PC, OPA_ZERO = 0, 1, 2
OPB_RS2, OPB_IMM, OPB_LINK = 0, 1, 2
WB_ALU, WB_MEM, WB_CSR, WB_MULDIV = 0, 1, 2, 3
MEM_SIZE = {"b": 0, "h": 1, "w": 2}
CSR_OP = {"rw": 0, "rs": 1, "rc": 2}

# px_pkg::decode_t, most significant field first.
FIELDS = [
    ("illegal", 1), ("rs1", 5), ("rs2", 5), ("rd", 5), ("rs1_used", 1), ("rs2_used", 1),
    ("rd_we", 1), ("imm", 32), ("alu_op", 5), ("op_a", 2), ("op_b", 2), ("wb_sel", 2),
    ("is_branch", 1), ("branch_f3", 3), ("is_jal", 1), ("is_jalr", 1), ("is_load", 1),
    ("is_store", 1), ("mem_size", 2), ("mem_unsigned", 1), ("muldiv_en", 1), ("muldiv_op", 3),
    ("csr_en", 1), ("csr_op", 2), ("csr_use_imm", 1), ("csr_read", 1), ("csr_write", 1),
    ("csr_addr", 12), ("is_ecall", 1), ("is_ebreak", 1), ("is_mret", 1), ("is_wfi", 1),
    ("is_fence", 1), ("is_fence_i", 1),
]
assert sum(w for _, w in FIELDS) == 101


def bits(x, hi, lo):
    return (x >> lo) & ((1 << (hi - lo + 1)) - 1)


def sext(x, n):
    return (x - (1 << n)) & 0xFFFFFFFF if x >> (n - 1) & 1 else x


def imm_i(w): return sext(bits(w, 31, 20), 12)
def imm_s(w): return sext((bits(w, 31, 25) << 5) | bits(w, 11, 7), 12)
def imm_b(w): return sext((bits(w, 31, 31) << 12) | (bits(w, 7, 7) << 11) | (bits(w, 30, 25) << 5) | (bits(w, 11, 8) << 1), 13)
def imm_u(w): return w & 0xFFFFF000
def imm_j(w): return sext((bits(w, 31, 31) << 20) | (bits(w, 19, 12) << 12) | (bits(w, 20, 20) << 11) | (bits(w, 30, 21) << 1), 21)


def identify(w):
    hits = [m for m, (mask, match) in ISA.items() if w & mask == match]
    assert len(hits) <= 1, (hex(w), hits)       # the table must not overlap
    return hits[0] if hits else "illegal"


def decode(w):
    """Expected decode_t fields for word w, as a dict."""
    m = identify(w)
    rd, rs1, rs2, f3 = bits(w, 11, 7), bits(w, 19, 15), bits(w, 24, 20), bits(w, 14, 12)
    d = {name: 0 for name, _ in FIELDS}
    d.update(rs1=rs1, rs2=rs2, rd=rd)
    if m == "illegal":
        d["illegal"] = 1
        return m, d

    if m == "lui":
        d.update(rd_we=1, op_a=OPA_ZERO, op_b=OPB_IMM, imm=imm_u(w))
    elif m == "auipc":
        d.update(rd_we=1, op_a=OPA_PC, op_b=OPB_IMM, imm=imm_u(w))
    elif m == "jal":
        d.update(rd_we=1, is_jal=1, op_a=OPA_PC, op_b=OPB_LINK, imm=imm_j(w))
    elif m == "jalr":
        d.update(rd_we=1, is_jalr=1, rs1_used=1, op_a=OPA_PC, op_b=OPB_LINK, imm=imm_i(w))
    elif m in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
        d.update(is_branch=1, branch_f3=f3, rs1_used=1, rs2_used=1, imm=imm_b(w))
    elif m in ("lb", "lh", "lw", "lbu", "lhu"):
        d.update(is_load=1, rd_we=1, rs1_used=1, op_b=OPB_IMM, wb_sel=WB_MEM, imm=imm_i(w),
                 mem_size=MEM_SIZE[m[1]], mem_unsigned=int(m.endswith("u")))
    elif m in ("sb", "sh", "sw"):
        d.update(is_store=1, rs1_used=1, rs2_used=1, op_b=OPB_IMM, imm=imm_s(w), mem_size=MEM_SIZE[m[1]])
    elif m in ALU_IMM:
        d.update(rd_we=1, rs1_used=1, op_b=OPB_IMM, imm=imm_i(w), alu_op=ALU[ALU_IMM[m]])
    elif m in ALU:
        d.update(rd_we=1, rs1_used=1, rs2_used=1, alu_op=ALU[m])
    elif m in ("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"):
        d.update(rd_we=1, rs1_used=1, rs2_used=1, muldiv_en=1, muldiv_op=f3, wb_sel=WB_MULDIV)
    elif m == "fence":
        d["is_fence"] = 1
    elif m == "fence.i":
        d["is_fence_i"] = 1
    elif m in ("ecall", "ebreak", "mret", "wfi"):
        d["is_" + m] = 1
    elif m.startswith("csrr"):
        kind, use_imm = m[3:5], m.endswith("i")    # csrRW, csrRS, csrRC
        d.update(csr_en=1, csr_op=CSR_OP[kind], csr_use_imm=int(use_imm), csr_addr=bits(w, 31, 20),
                 csr_read=int(not (kind == "rw" and rd == 0)),
                 csr_write=int(not (kind != "rw" and rs1 == 0)),
                 rs1_used=int(not use_imm), rd_we=1, wb_sel=WB_CSR,
                 imm=rs1 if use_imm else 0)
    else:
        raise AssertionError(m)

    if rd == 0:
        d["rd_we"] = 0
    return m, d


def pack(d):
    v = 0
    for name, width in FIELDS:
        assert 0 <= d[name] < (1 << width), (name, d[name])
        v = (v << width) | d[name]
    return v


# ---------------------------------------------------------------------------
# Stimulus
# ---------------------------------------------------------------------------
def words(rng):
    out = []

    def regs():
        return (rng.choice([0, 0, rng.randrange(32)]), rng.choice([0, rng.randrange(32)]),
                rng.randrange(32))

    # 1. Every opcode x funct3 x a set of funct7 values; all funct7 for OP and OP-IMM.
    for op in range(128):
        for f3 in range(8):
            f7s = range(128) if op in (0x13, 0x33) else [0x00, 0x20, 0x01, rng.randrange(128), rng.randrange(128)]
            for f7 in f7s:
                rd, rs1, rs2 = regs()
                out.append((f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op)
    # 2. SYSTEM funct3 = 000: every 12-bit immediate with rd = rs1 = 0, plus nonzero fields.
    for imm in range(4096):
        out.append((imm << 20) | 0x73)
    for base in (0x00000073, 0x00100073, 0x30200073, 0x10500073):
        for _ in range(40):
            out.append(base | (rng.randrange(1, 32) << rng.choice([7, 15])))
    out += [0x10200073, 0x00200073, 0x7B200073, 0x12000073, 0x12B50073, 0x22000073, 0x62000073]
    # 3. FENCE / FENCE.I variants: fm, pred/succ, reserved rs1/rd, FENCE.TSO, PAUSE hint.
    out += [0x0FF0000F, 0x8330000F, 0x0100000F, 0x0000000F, 0x0000100F]
    for _ in range(300):
        out.append((rng.getrandbits(17) << 15) | (rng.randrange(32) << 7) | rng.choice([0x0F, 0x100F]))
    # 4. CSR instructions with rd/rs1 = 0 corner cases and random addresses.
    for f3 in (1, 2, 3, 5, 6, 7):
        for rd in (0, 5):
            for rs1 in (0, 9):
                for csr in (0x300, 0x341, 0xB00, 0xC00, 0xF14, rng.randrange(4096)):
                    out.append((csr << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73)
    # 5. Random legal-looking words (opcode drawn from implemented ones) and fully random words.
    legal_ops = [0x37, 0x17, 0x6F, 0x67, 0x63, 0x03, 0x23, 0x13, 0x33, 0x0F, 0x73]
    for _ in range(20000):
        out.append((rng.getrandbits(25) << 7) | rng.choice(legal_ops))
    for _ in range(20000):
        out.append(rng.getrandbits(32))
    # 6. Every mnemonic with random values in all bits outside its mask.
    for m, (mask, match) in ISA.items():
        for _ in range(60):
            out.append((rng.getrandbits(32) & ~mask & 0xFFFFFFFF) | match)
    # 7. Extreme immediates.
    for m in ("addi", "lw", "sw", "beq", "jal", "lui", "jalr"):
        mask, match = ISA[m]
        for fill in (0x00000000, 0xFFFFFFFF, 0x80000000, 0x7FFFF000):
            out.append((fill & ~mask) | match)
    # Deduplicate, keep order.
    seen, uniq = set(), []
    for w in out:
        if w not in seen:
            seen.add(w)
            uniq.append(w)
    return uniq


# ---------------------------------------------------------------------------
# Cross-check against GNU binutils
# ---------------------------------------------------------------------------
# Differences that are expected and correct, with the reason.
EXPECTED_DIFFERENCES = {
    # objdump knows these privileged instructions; PX32 Phase 1 is M-mode only
    # (no S/U-mode return, no virtual memory, no debug mode), so they must trap.
    "sret": "S-mode not implemented", "uret": "N extension not implemented",
    "dret": "debug mode not implemented in Phase 1", "sfence.vma": "no virtual memory",
    "hfence.vvma": "no hypervisor", "hfence.gvma": "no hypervisor",
    "sinval.vma": "no virtual memory", "sfence.w.inval": "no virtual memory",
    "sfence.inval.ir": "no virtual memory", "wrs.nto": "Zawrs not implemented",
    "wrs.sto": "Zawrs not implemented", "hret": "obsolete hypervisor return, not implemented",
}


def find_tool(name):
    p = shutil.which(name)
    if p:
        return p
    for d in TOOLCHAIN_DIRS:
        cand = d / (name + ".exe")
        if cand.exists():
            return str(cand)
    return None


def objdump_all(ws):
    asm, objdump = find_tool("riscv-none-elf-as"), find_tool("riscv-none-elf-objdump")
    if not asm or not objdump:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        src, obj = Path(tmp) / "w.s", Path(tmp) / "w.o"
        # .insn rather than .word: the assembler marks .word as data, and objdump would
        # print it back as data instead of disassembling it.
        src.write_text(".text\n" + "".join(f".insn 4, 0x{w:08x}\n" for w in ws), newline="\n")
        subprocess.run([asm, "-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-o", str(obj), str(src)], check=True)
        text = subprocess.run([objdump, "-d", "-M", "no-aliases,numeric", str(obj)],
                              check=True, capture_output=True, text=True).stdout
    result = {}
    for line in text.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*(.*)$", line)
        if m:
            result[int(m.group(1), 16)] = (int(m.group(2), 16), m.group(3), m.group(4).strip())
    return result


def x(n):
    return f"x{n}"


def check_operands(m, w, pc, ops):
    """Compare operand text from objdump with the model. Returns an error string or None."""
    rd, rs1, rs2 = bits(w, 11, 7), bits(w, 19, 15), bits(w, 24, 20)
    s = lambda v: v - (1 << 32) if v >> 31 else v
    ops = ops.split("#")[0].split("<")[0].strip()
    parts = [p.strip() for p in ops.split(",")] if ops else []

    def num(t):
        return int(t, 0)

    if m in ALU or m in ("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"):
        exp = [x(rd), x(rs1), x(rs2)]
        return None if parts == exp else f"{parts} != {exp}"
    if m in ("slli", "srli", "srai"):
        ok = parts[:2] == [x(rd), x(rs1)] and num(parts[2]) == rs2
        return None if ok else f"{parts}"
    if m in ALU_IMM:
        ok = parts[:2] == [x(rd), x(rs1)] and num(parts[2]) == s(imm_i(w))
        return None if ok else f"{parts} imm {s(imm_i(w))}"
    if m in ("lui", "auipc"):
        ok = parts[0] == x(rd) and num(parts[1]) == imm_u(w) >> 12
        return None if ok else f"{parts}"
    if m in ("lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw"):
        mm = re.match(r"(-?\w+)\((x\d+)\)", parts[1])
        reg, imm = (x(rd), s(imm_i(w))) if m[0] == "l" else (x(rs2), s(imm_s(w)))
        ok = parts[0] == reg and mm and num(mm.group(1)) == imm and mm.group(2) == x(rs1)
        return None if ok else f"{parts}"
    if m in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
        ok = parts[:2] == [x(rs1), x(rs2)] and int(parts[2], 16) == (pc + imm_b(w)) & 0xFFFFFFFF
        return None if ok else f"{parts}"
    if m == "jal":
        ok = parts[0] == x(rd) and int(parts[1], 16) == (pc + imm_j(w)) & 0xFFFFFFFF
        return None if ok else f"{parts}"
    if m == "jalr":
        if len(parts) == 2:
            mm = re.match(r"(-?\w+)\((x\d+)\)", parts[1])
            ok = parts[0] == x(rd) and mm and num(mm.group(1)) == s(imm_i(w)) and mm.group(2) == x(rs1)
        else:
            ok = parts[:2] == [x(rd), x(rs1)] and num(parts[2]) == s(imm_i(w))
        return None if ok else f"{parts}"
    if m.startswith("csrr"):
        src = rs1 if m.endswith("i") else x(rs1)
        ok = parts[0] == x(rd) and (parts[2] == src or (m.endswith("i") and num(parts[2]) == rs1))
        if ok and re.fullmatch(r"0x[0-9a-f]+", parts[1]):
            ok = num(parts[1]) == bits(w, 31, 20)
        return None if ok else f"{parts}"
    return None   # fence, fence.i, ecall, ebreak, mret, wfi: no operands to compare


def cross_check(all_ws):
    # Only genuine 32-bit encodings can be disassembled as 32-bit instructions: low bits
    # other than 11 are 16-bit encodings, and 11111 marks 48-bit or longer ones. The
    # model rules both illegal from the length encoding alone.
    ws = [w for w in all_ws if (w & 0x3) == 0x3 and (w & 0x1F) != 0x1F]
    for w in all_ws:
        if (w & 0x3) == 0x3 and (w & 0x1F) != 0x1F:
            continue
        assert identify(w) == "illegal", hex(w)
    print(f"objdump cross-check: {len(all_ws) - len(ws)} non-32-bit encodings skipped "
          f"(all illegal in the model, as required)")
    dis = objdump_all(ws)
    if dis is None:
        print("objdump cross-check: SKIPPED (riscv-none-elf-as/objdump not found)")
        return True
    stats = {"agree": 0, "operands_checked": 0, "expected_diff": 0}
    expected_seen = {}
    errors = []
    for i, w in enumerate(ws):
        pc = 4 * i
        word, mn, ops = dis[pc]
        assert word == w
        model = identify(w)
        known = not (mn.startswith(".") or mn in ("unknown", "unimp"))
        if mn == "fence.tso":
            mn = "fence"
        if model == "illegal" and known and mn in EXPECTED_DIFFERENCES:
            stats["expected_diff"] += 1
            expected_seen[mn] = expected_seen.get(mn, 0) + 1
            continue
        if model == "fence.i" and not known:
            # Zifencei: imm, rs1 and rd are reserved and base implementations shall
            # ignore them; binutils refuses to print nonzero values.
            key = "fence.i (reserved imm/rs1/rd ignored)"
            stats["expected_diff"] += 1
            expected_seen[key] = expected_seen.get(key, 0) + 1
            continue
        if model == "illegal" and known and mn in ("slli", "srli", "srai") and bits(w, 25, 25):
            # binutils accepts RV64 shift amounts; on RV32 imm[5] = 1 is reserved.
            key = "RV64 shift amount (imm[5]=1)"
            stats["expected_diff"] += 1
            expected_seen[key] = expected_seen.get(key, 0) + 1
            continue
        if model == "csrrw" and mn == "unimp" and w == 0xC0001073:
            # UNIMP is csrrw x0, cycle, x0. The encoding is a legal CSRRW; it traps
            # because cycle is read-only, which the CSR unit (step 1.6) must check.
            key = "unimp (csrrw x0,cycle,x0: CSR unit traps)"
            stats["expected_diff"] += 1
            expected_seen[key] = expected_seen.get(key, 0) + 1
            continue
        if model == "fence" and not known:
            # Reserved fm/pred/succ settings: the ISA requires base implementations to
            # treat them as ordinary fences; binutils refuses to print them.
            stats["expected_diff"] += 1
            expected_seen["fence (reserved fm/pred/succ)"] = expected_seen.get("fence (reserved fm/pred/succ)", 0) + 1
            continue
        if (model == "illegal") != (not known) or (known and model != mn):
            errors.append(f"0x{w:08x}: model={model} objdump={mn} {ops}")
            continue
        if known:
            err = check_operands(model, w, pc, ops)
            stats["operands_checked"] += 1
            if err:
                errors.append(f"0x{w:08x} {model}: operand mismatch {err}")
                continue
        stats["agree"] += 1
    print(f"objdump cross-check: {stats['agree']} agree ({stats['operands_checked']} with operands compared), "
          f"{stats['expected_diff']} expected differences, {len(errors)} unexpected")
    for k, v in sorted(expected_seen.items()):
        print(f"  expected difference: {k:34s} x{v}  ({EXPECTED_DIFFERENCES.get(k, "reserved encoding handling required by the ISA, see comments")})")
    for e in errors[:30]:
        print("  MISMATCH " + e)
    return not errors


def main():
    rng = random.Random(0xDEC0DE)
    ws = words(rng)
    lines = [f"{len(MNEMONICS):02x}{len(ws):08x}{0:026x}"]
    counts = {}
    for w in ws:
        m, d = decode(w)
        counts[m] = counts.get(m, 0) + 1
        lines.append(f"{MNEMONICS.index(m):02x}{w:08x}{pack(d):026x}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", newline="\n")
    NAMES.write_text("".join(f"{i} {n}\n" for i, n in enumerate(MNEMONICS)), newline="\n")
    print(f"wrote {len(ws)} vectors ({len(MNEMONICS)} mnemonic ids) to {OUT.relative_to(ROOT)}")
    rare = [m for m in MNEMONICS if counts.get(m, 0) < 5 and ISA.get(m, (0,))[0] != EXACT]
    if rare:
        print("WARNING: mnemonics with fewer than 5 vectors:", rare)
    ok = True if "--no-objdump" in sys.argv else cross_check(ws)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
