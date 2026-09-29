#!/usr/bin/env python3
"""Generate golden test vectors for px_alu from an independent Python model.

The model below is written from the RISC-V Unprivileged ISA text (RV32I integer
register-register operations), not from the RTL. The output file is committed so
regression runs do not need Python; regenerate it after changing this script:

    python scripts/gen_alu_vectors.py

Output format (tb/unit/vectors/alu_vectors.hex), one 112-bit hex word per line:
    [111:104] op code (px_pkg::alu_op_e)
    [103:72]  a
    [71:40]   b
    [39:8]    expected result
    [7:0]     expected flags {5'b0, eq, lt, ltu}
The first line holds the vector count in the low 32 bits.
"""

import random
from pathlib import Path

MASK = 0xFFFF_FFFF

# Must match px_pkg::alu_op_e
OPS = {
    "ADD": 0, "SUB": 1, "SLL": 2, "SLT": 3, "SLTU": 4,
    "XOR": 5, "SRL": 6, "SRA": 7, "OR": 8, "AND": 9,
}


def to_signed(x: int) -> int:
    return x - (1 << 32) if x & 0x8000_0000 else x


def alu(op: str, a: int, b: int) -> int:
    sh = b & 0x1F
    if op == "ADD":
        return (a + b) & MASK
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
    raise ValueError(op)


def operand(rng: random.Random) -> int:
    """Mix of uniform values and structured values that stress carries and signs."""
    kind = rng.randrange(6)
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
    return (rng.getrandbits(32) + rng.choice([-1, 0, 1])) & MASK


def main() -> None:
    rng = random.Random(0x5EED_2026)
    vectors = []
    for _ in range(10_000):
        op = rng.choice(list(OPS))
        a = operand(rng)
        b = operand(rng)
        if rng.random() < 0.25:
            b = a                          # exercise eq and zero results
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
    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {len(vectors)} vectors to {out}")


if __name__ == "__main__":
    main()
