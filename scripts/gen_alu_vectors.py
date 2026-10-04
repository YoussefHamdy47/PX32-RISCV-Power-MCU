#!/usr/bin/env python3
"""Generate golden test vectors for px_alu from an independent Python model.

The model below is written from the RISC-V Unprivileged ISA text (release 20240411): the
RV32I integer register-register operations and the Zba, Zbb, Zbs (bit manipulation 1.0.0)
and Zicond 1.0 operations, not from the RTL. Counts, rotates, byte operations and
single-bit operations are computed bit by bit. The output file is committed so regression
runs do not need Python; regenerate it after changing this script:

    python scripts/gen_alu_vectors.py

Output format (tb/unit/vectors/alu_vectors.hex), one 112-bit hex word per line:
    [111:104] op code (px_pkg::alu_op_e, 6 bits used)
    [103:72]  a
    [71:40]   b
    [39:8]    expected result
    [7:0]     expected flags {5'b0, eq, lt, ltu}
The first line holds the vector count in the low 32 bits.
"""

import random
from pathlib import Path

MASK = 0xFFFF_FFFF
NUM_VECTORS = 20_000

# Must match px_pkg::alu_op_e (DECISIONS.md D-028: ADD..SH3ADD are 0..3)
OPS = {
    "ADD": 0, "SH1ADD": 1, "SH2ADD": 2, "SH3ADD": 3,
    "SUB": 4, "SLL": 5, "SLT": 6, "SLTU": 7, "XOR": 8, "SRL": 9, "SRA": 10, "OR": 11, "AND": 12,
    "ANDN": 13, "ORN": 14, "XNOR": 15, "CLZ": 16, "CTZ": 17, "CPOP": 18,
    "MAX": 19, "MAXU": 20, "MIN": 21, "MINU": 22, "SEXTB": 23, "SEXTH": 24, "ZEXTH": 25,
    "ROL": 26, "ROR": 27, "ORCB": 28, "REV8": 29,
    "BCLR": 30, "BEXT": 31, "BINV": 32, "BSET": 33, "CZERO_EQZ": 34, "CZERO_NEZ": 35,
}


def to_signed(x: int) -> int:
    return x - (1 << 32) if x & 0x8000_0000 else x


def bitlist(x):
    return [(x >> i) & 1 for i in range(32)]


def from_bits(bs):
    return sum(b << i for i, b in enumerate(bs))


def sext(x, n):
    x &= (1 << n) - 1
    return (x - (1 << n)) & MASK if x >> (n - 1) else x


def alu(op: str, a: int, b: int) -> int:
    sh = b & 0x1F
    bits = bitlist(a)
    if op == "ADD":
        return (a + b) & MASK
    if op in ("SH1ADD", "SH2ADD", "SH3ADD"):
        # Zba: X(rd) = X(rs2) + (X(rs1) << n); a = rs1, b = rs2
        return (b + (a << int(op[2]))) & MASK
    if op == "SUB":
        return (a - b) & MASK
    if op == "SLL":
        return (a << sh) & MASK
    if op == "SLT":
        return int(to_signed(a) < to_signed(b))
    if op == "SLTU":
        return int(a < b)
    if op == "XOR":
        return a ^ b
    if op == "SRL":
        return a >> sh
    if op == "SRA":
        return (to_signed(a) >> sh) & MASK  # Python >> on negative ints is arithmetic
    if op == "OR":
        return a | b
    if op == "AND":
        return a & b
    if op == "ANDN":
        return a & (~b & MASK)
    if op == "ORN":
        return a | (~b & MASK)
    if op == "XNOR":
        return ~(a ^ b) & MASK
    if op == "CLZ":                       # leading zeros, counted from bit 31 down
        n = 0
        for i in range(31, -1, -1):
            if bits[i]:
                break
            n += 1
        return n
    if op == "CTZ":                       # trailing zeros, counted from bit 0 up
        n = 0
        for i in range(32):
            if bits[i]:
                break
            n += 1
        return n
    if op == "CPOP":
        return sum(bits)
    if op == "MAX":
        return a if to_signed(a) >= to_signed(b) else b
    if op == "MAXU":
        return a if a >= b else b
    if op == "MIN":
        return a if to_signed(a) < to_signed(b) else b
    if op == "MINU":
        return a if a < b else b
    if op == "SEXTB":
        return sext(a, 8)
    if op == "SEXTH":
        return sext(a, 16)
    if op == "ZEXTH":
        return a & 0xFFFF
    if op == "ROL":                       # bit i moves to bit (i + sh) mod 32
        out = [0] * 32
        for i in range(32):
            out[(i + sh) % 32] = bits[i]
        return from_bits(out)
    if op == "ROR":                       # bit i moves to bit (i - sh) mod 32
        out = [0] * 32
        for i in range(32):
            out[(i - sh) % 32] = bits[i]
        return from_bits(out)
    if op == "ORCB":                      # each byte: all ones if any bit is set
        out = 0
        for k in range(4):
            if any(bits[8 * k:8 * k + 8]):
                out |= 0xFF << (8 * k)
        return out
    if op == "REV8":                      # byte k moves to byte 3 - k
        out = 0
        for k in range(4):
            out |= ((a >> (8 * k)) & 0xFF) << (8 * (3 - k))
        return out
    if op == "BCLR":
        return from_bits([0 if i == sh else bits[i] for i in range(32)])
    if op == "BEXT":
        return bits[sh]
    if op == "BINV":
        return from_bits([1 - bits[i] if i == sh else bits[i] for i in range(32)])
    if op == "BSET":
        return from_bits([1 if i == sh else bits[i] for i in range(32)])
    if op == "CZERO_EQZ":                 # Zicond: rd = (rs2 == 0) ? 0 : rs1
        return 0 if b == 0 else a
    if op == "CZERO_NEZ":                 # Zicond: rd = (rs2 != 0) ? 0 : rs1
        return 0 if b != 0 else a
    raise ValueError(op)


def operand(rng: random.Random) -> int:
    """Mix of uniform values and structured values that stress carries, signs and counts."""
    kind = rng.randrange(8)
    if kind == 0:
        return rng.getrandbits(32)
    if kind == 1:
        return (1 << rng.randrange(32)) & MASK                      # single bit
    if kind == 2:
        return (~(1 << rng.randrange(32))) & MASK                   # single zero
    if kind == 3:
        return ((1 << rng.randrange(33)) - 1) & MASK                # low mask
    if kind == 4:
        return rng.choice([0, 1, MASK, 0x7FFF_FFFF, 0x8000_0000])   # extremes
    if kind == 5:
        return (MASK << rng.randrange(33)) & MASK                   # high mask
    if kind == 6:                                                   # sparse bytes
        return sum((rng.getrandbits(8) if rng.random() < 0.5 else 0) << (8 * k) for k in range(4))
    return (rng.getrandbits(32) + rng.choice([-1, 0, 1])) & MASK


def main() -> None:
    rng = random.Random(0x5EED_2026)
    vectors = []
    for _ in range(NUM_VECTORS):
        op = rng.choice(list(OPS))
        a = operand(rng)
        b = operand(rng)
        k = rng.random()
        if k < 0.2:
            b = a                          # exercise eq and zero results
        elif k < 0.25:
            b = 0                          # Zicond condition zero, shift/index 0
        elif k < 0.35:
            b = (rng.getrandbits(27) << 5) | rng.randrange(32)   # shift/index with junk above
        res = alu(op, a, b)
        eq = int(a == b)
        lt = int(to_signed(a) < to_signed(b))
        ltu = int(a < b)
        flags = (eq << 2) | (lt << 1) | ltu
        word = (OPS[op] << 104) | (a << 72) | (b << 40) | (res << 8) | flags
        vectors.append(word)

    out = Path(__file__).resolve().parent.parent / "tb" / "unit" / "vectors" / "alu_vectors.hex"
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{len(vectors):028x}"] + [f"{v:028x}" for v in vectors]
    out.write_text("\n".join(lines) + "\n", newline="\n")
    print(f"wrote {len(vectors)} vectors to {out}")


if __name__ == "__main__":
    main()
