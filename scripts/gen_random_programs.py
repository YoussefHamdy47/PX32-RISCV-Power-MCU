#!/usr/bin/env python3
"""Generate seeded random RV32IC test programs for tb_core (sw/tests/random/rand_<seed>.S).

The programs have no self-checks: tb_core compares every retirement with the reference
model (scripts/px_iss.py). They mix
  - register and immediate ALU operations, LUI/AUIPC, edge-value constants
  - loads and stores of every width to a 4 KB buffer, directly and through pointers
    computed by the previous instruction (address forwarding), SP-relative accesses
  - forward branches, JAL and JALR over "shadows" of 1-4 instructions that may hold
    stores, device accesses and trapping instructions (wrong-path side effects)
  - short counted loops (backward branches)
  - reads and writes of the side-effect device, FENCE, FENCE.I and WFI
  - M instructions (step 1.7): all eight, on random and corner operands (0, 1, -1,
    INT_MIN, INT_MAX, small divisors, divide by zero, INT_MIN / -1), with immediate
    dependent uses (ALU, branch, store data, next MUL/DIV), chains and back-to-back
    divides, also on wrong paths
  - trapping instructions: misaligned and faulting loads/stores, ECALL, EBREAK,
    C.EBREAK, illegal 32- and 16-bit words,
    CSR writes to read-only CSRs (a nonzero rs1 field or zimm; CSRRW(I) even with
    rd = x0, including csrrw x0, cycle, x0) and accesses to unimplemented CSRs. The crt0
    handler resumes after the trapping instruction.
  - legal Zicsr accesses in all six forms: reads of every implemented CSR, writes of
    mtval/mcause/mepc/mstatus/mie/mip/misa/mstatush/hpm/PMP (WARL), minstret(h) and
    mcycle(h) writes, mtvec and mscratch written and restored by the next instruction
    (the handler needs them), mcycle reads whose timing-dependent value is consumed by
    x - x (forwarded, result known), suppressed forms on read-only CSRs
  - MRET to a forward label through a just-written mepc, with a wrong-path shadow
The assembler compresses every eligible instruction, so 16-/32-bit alignment varies.

Long programs for the step 1.9 comparison with Spike (--long, DECISIONS.md D-026): seeds 9-12,
2,300 items each (at least 10,000 retirements), written to sw/tests/random_long/rlong_<seed>.S
and run by tb_core_random_long (against the reference model) and by
scripts/compliance/run_trace_compare.py (against Spike). They use the same generator with
the "spike" profile, which leaves out only what Spike cannot model or what D-026 classifies
as a fixed Spike difference from PX32's D-022 choices:
  - the side-effect device (Spike has no such device; its addresses are left unmapped)
  - writes of misa (C2), mie (C3) and the PMP CSRs (C7), reads of marchid (C1) and of the PMP
    CSRs (C7), accesses to mcountinhibit (C5) and tselect (C6)
  - mtvec values with MODE bit 0 set (C4: Spike keeps Vectored mode) and mcause values outside
    the WLRL legal set (C8): the written value is loaded with li first
Everything else, including traps, mcycle (masked by the comparison, M1) and minstret, is kept.
The default profile (seeds 1-8) is unchanged: its programs are bit-identical to before.

Usage: python scripts/gen_random_programs.py [count] [first_seed]
       python scripts/gen_random_programs.py --long
"""

import random
import sys
from pathlib import Path

POOL = [1, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        27, 28, 29, 30, 31]
RVC_REGS = list(range(8, 16))
# reserved: x2 sp = buffer start, x24 loop counter, x25 device base, x26 buffer middle;
# x3/x4 are left to the harness
EDGE = [0, 1, -1, 2, 0x7FFFFFFF, -0x80000000, 0x80, 0xFF, 0x7FF, -0x800, 0xFFFF, 0x8000]
ILLEGAL32 = [0x80000033, 0xFFFFFFFF, 0x04000033, 0x10200073, 0x0000707F, 0xC0001073]
MULDIV = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
MD_CORNER = [0, 1, -1, 2, -2, -0x80000000, 0x7FFFFFFF, 7, -7, 0xFFFF, 0x10000]
# CSRs a random program may write freely (every write is legal and harmless to the harness)
CSR_FREE = ["mtval", "mcause", "mepc", "mstatus", "mie", "mip", "misa", "0x310", "0xB03",
            "0xB9F", "0x323", "0x3A0", "0x3EF", "minstret", "minstreth", "mcycle", "mcycleh"]
CSR_READ = CSR_FREE + ["mtvec", "mscratch", "mvendorid", "marchid", "mimpid", "mhartid",
                       "0xF15"]
CSR_RO = ["mvendorid", "marchid", "mimpid", "mhartid", "0xF15"]
CSR_UNIMPL = ["0xC00", "0xC01", "0xC02", "0x001", "0x003", "0x320", "0x306", "0x180",
              "0x7A0", "0x7B0", "0xB01", "0x30A", "0x7C0", "0x800", "0xFFF"]


# "spike" profile (--long): differences D-026 classifies, left out of the generated programs
SPIKE_NO_WRITE = {"misa", "mie", "0x3A0", "0x3EF"}          # C2, C3, C7
SPIKE_NO_READ = {"marchid", "0x3A0", "0x3EF"}               # C1, C7
SPIKE_NO_UNIMPL = {"0x320", "0x7A0"}                        # C5 mcountinhibit, C6 tselect


class Gen:
    def __init__(self, seed, profile="default"):
        self.r = random.Random(seed)
        self.lines = []
        self.label = 0
        self.spike = profile == "spike"

    def new_label(self):
        self.label += 1
        return f"L{self.label}"

    def reg(self):
        r = self.r
        return r.choice(RVC_REGS) if r.random() < 0.45 else r.choice(POOL)

    def rd(self):
        return 0 if self.r.random() < 0.04 else self.reg()

    def imm12(self):
        r = self.r
        return r.choice([0, 1, -1, 2047, -2048, 31, 16, -16]) if r.random() < 0.3 else r.randint(-2048, 2047)

    def const(self):
        r = self.r
        return r.choice(EDGE) if r.random() < 0.4 else r.randint(-2**31, 2**31 - 1)

    def emit(self, s):
        self.lines.append("  " + s)

    # -------------------------------------------------------------- simple items
    def alu(self):
        r = self.r
        k = r.random()
        if k < 0.35:
            op = r.choice(["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"])
            self.emit(f"{op} x{self.rd()}, x{self.reg()}, x{self.reg()}")
        elif k < 0.65:
            op = r.choice(["addi", "slti", "sltiu", "xori", "ori", "andi"])
            self.emit(f"{op} x{self.rd()}, x{self.reg()}, {self.imm12()}")
        elif k < 0.8:
            op = r.choice(["slli", "srli", "srai"])
            d = self.rd()
            s = d if r.random() < 0.5 and d else self.reg()
            self.emit(f"{op} x{d}, x{s}, {r.choice([0, 1, 31, r.randint(0, 31)])}")
        elif k < 0.88:
            self.emit(f"{r.choice(['lui', 'auipc'])} x{self.rd()}, {r.randint(0, 0xFFFFF)}")
        else:
            self.emit(f"li x{self.rd()}, {self.const()}")

    def mem_off(self, size):
        return self.r.randrange(-2048, 2048 - 4, size)

    def load(self):
        r = self.r
        op, size = r.choice([("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4), ("lw", 4)])
        if r.random() < 0.25:                          # through a pointer made just before
            p = self.reg()
            off = self.mem_off(size)
            self.emit(f"addi x{p}, x26, {off}")
            self.emit(f"{op} x{self.rd()}, 0(x{p})")
        elif r.random() < 0.2 and op == "lw":         # SP-relative (C.LWSP when eligible)
            self.emit(f"lw x{self.rd()}, {r.randrange(0, 256, 4)}(sp)")
        else:
            self.emit(f"{op} x{self.rd()}, {self.mem_off(size)}(x26)")

    def store(self):
        r = self.r
        op, size = r.choice([("sb", 1), ("sh", 2), ("sw", 4), ("sw", 4)])
        if r.random() < 0.25:
            p = self.reg()
            self.emit(f"addi x{p}, x26, {self.mem_off(size)}")
            self.emit(f"{op} x{self.reg()}, 0(x{p})")
        elif r.random() < 0.2 and op == "sw":
            self.emit(f"sw x{self.reg()}, {r.randrange(0, 256, 4)}(sp)")
        else:
            self.emit(f"{op} x{self.reg()}, {self.mem_off(size)}(x26)")

    def device(self):
        r = self.r
        if self.spike:                                # no side-effect device on Spike
            (self.load if r.random() < 0.5 else self.store)()
            return
        k = r.random()
        if k < 0.5:
            self.emit(f"lw x{self.rd()}, 0(x25)")
        elif k < 0.8:
            self.emit(f"sw x{self.reg()}, 4(x25)")
        else:
            self.emit(f"lw x{self.rd()}, 4(x25)")

    def trap_instr(self):
        """One instruction that traps (or two, when a pointer is needed)."""
        r = self.r
        k = r.random()
        if k < 0.2:
            op, size = r.choice([("lh", 2), ("lhu", 2), ("lw", 4), ("sh", 2), ("sw", 4)])
            off = self.mem_off(4) + r.choice([1, 2, 3] if size == 4 else [1, 3])
            self.emit(f"{op} x{self.reg() if op[0] == 's' else self.rd()}, {off}(x26)")
        elif k < 0.4:
            p = self.reg()
            self.emit(f"li x{p}, {r.choice([0x30000000, 0x00000000, 0x20010008, 0x40000000])}")
            if r.random() < 0.5:
                self.emit(f"lw x{self.rd()}, 0(x{p})")
            else:
                self.emit(f"sw x{self.reg()}, 0(x{p})")
        elif k < 0.5:
            self.emit("ecall")
        elif k < 0.6:
            self.emit(r.choice(["ebreak", "c.ebreak"]))
        elif k < 0.75:
            self.emit(f".word 0x{r.choice(ILLEGAL32):08x}")
        elif k < 0.85:
            self.emit(f".half 0x{r.choice([0x0000, 0x6101, 0x2002, 0x8002, 0x9C21]):04x}")
        else:
            self.csr_trap()

    # -------------------------------------------------------------- M items
    def muldiv(self):
        """One MUL/DIV, sometimes on corner operands, sometimes with a dependent use."""
        r = self.r
        op = r.choice(MULDIV)
        a, b = self.reg(), self.reg()
        if r.random() < 0.35:
            self.emit(f"li x{a}, {r.choice(MD_CORNER)}")
            if b != a:
                self.emit(f"li x{b}, {r.choice(MD_CORNER)}")
        d = self.rd()
        self.emit(f"{op} x{d}, x{a}, x{b}")
        k = r.random()
        if d == 0 or k < 0.4:
            return
        if k < 0.55:
            self.emit(f"addi x{self.rd()}, x{d}, {self.imm12()}")
        elif k < 0.65:
            self.emit(f"sw x{d}, {self.mem_off(4)}(x26)")
        elif k < 0.75:
            end = self.new_label()
            self.emit(f"{r.choice(['beq', 'bne', 'blt', 'bgeu'])} x{d}, x{self.reg()}, {end}")
            self.emit(f"xor x{self.rd()}, x{d}, x{self.reg()}")
            self.lines.append(f"{end}:")
        else:
            self.emit(f"{r.choice(MULDIV)} x{self.rd()}, x{d}, x{self.reg()}")

    # -------------------------------------------------------------- CSR items
    def csr_trap(self):
        """A CSR access that must trap: write to a read-only CSR or unimplemented CSR."""
        r = self.r
        k = r.random()
        if k < 0.5:
            c = r.choice(CSR_RO)
            f = r.choice(["rw", "rs", "rc", "rwi", "rsi", "rci"])
            if f in ("rw", "rwi"):
                d = 0 if r.random() < 0.5 else self.rd()
            else:
                d = self.rd()
            if f.endswith("i"):
                src = str(r.randint(1 if f != "rwi" else 0, 31))
            else:
                src = f"x{self.reg()}" if f != "rw" or r.random() < 0.7 else "x0"
            self.emit(f"csr{f} x{d}, {c}, {src}")
        else:
            c = r.choice([x for x in CSR_UNIMPL if x not in SPIKE_NO_UNIMPL] if self.spike else CSR_UNIMPL)
            self.emit(f"csrrs x{self.rd()}, {c}, x0" if r.random() < 0.5 else
                      f"csrrw x0, {c}, x{self.reg()}")

    def csr_item(self):
        """A legal CSR access (see the module docstring)."""
        r = self.r
        k = r.random()
        if k < 0.3:
            c = r.choice([x for x in CSR_READ if x not in SPIKE_NO_READ] if self.spike else CSR_READ)
            if c in ("mcycle", "mcycleh"):
                d = self.reg()
                self.emit(f"csrr x{d}, {c}")
                self.emit(f"sub x{d}, x{d}, x{d}")    # timing-dependent value consumed
            elif c in CSR_RO or r.random() < 0.3:
                f = r.choice(["rs", "rc"])
                if r.random() < 0.5:
                    self.emit(f"csr{f} x{self.rd()}, {c}, x0")
                else:
                    self.emit(f"csr{f}i x{self.rd()}, {c}, 0")
            else:
                self.emit(f"csrr x{self.rd()}, {c}")
        elif k < 0.75:
            c = r.choice([x for x in CSR_FREE if x not in SPIKE_NO_WRITE] if self.spike else CSR_FREE)
            f = r.choice(["rw", "rs", "rc", "rwi", "rsi", "rci"])
            d = self.rd()
            if c in ("mcycle", "mcycleh"):
                d = 0                                 # old value is timing dependent
            if f.endswith("i"):
                src = str(r.randint(0, 31))
            else:
                src = f"x{self.reg()}"
                if self.spike and c == "mcause":      # C8: a WLRL-legal value only
                    self.emit(f"li {src}, {r.choice([0, 0x80000000]) | r.randint(0, 31)}")
            self.emit(f"csr{f} x{d}, {c}, {src}")
        elif k < 0.9:
            c = r.choice(["mtvec", "mscratch"])       # write, then restore at once
            a = r.choice(POOL)
            v = self.reg()
            if self.spike and c == "mtvec":           # C4: MODE bit 0 clear (Direct)
                v = r.choice([x for x in POOL if x != a])
                self.emit(f"li x{v}, {self.const() & ~1}")
            self.emit(f"csrrw x{a}, {c}, x{v}")
            self.emit(f"csrrw x{self.rd()}, {c}, x{a}")
        else:
            # csrrs on mstatus with random bits, then read back
            self.emit(f"csrrs x{self.rd()}, mstatus, x{self.reg()}")
            self.emit(f"csrr x{self.rd()}, mstatus")

    def mret_item(self):
        """MRET to a forward label through a just-written mepc; the gap is wrong path."""
        r = self.r
        end = self.new_label()
        p = self.reg()
        if r.random() < 0.3:
            self.emit(f"csrrs x{self.rd()}, mstatus, x{self.reg()}")
        self.emit(f"la x{p}, {end}")
        self.emit(f"csrw mepc, x{p}")
        self.emit("mret")
        for _ in range(r.randint(1, 3)):
            self.shadow_item()
        self.lines.append(f"{end}:")

    def shadow_item(self):
        k = self.r.random()
        if k < 0.3:
            self.alu()
        elif k < 0.48:
            self.store()
        elif k < 0.6:
            self.load()
        elif k < 0.72:
            self.device()
        elif k < 0.8:
            self.csr_item()
        elif k < 0.88:
            self.muldiv()
        else:
            self.trap_instr()

    # -------------------------------------------------------------- control items
    def shadow(self, kind):
        r = self.r
        end = self.new_label()
        if kind == "branch":
            op = r.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            a = self.reg()
            b = 0 if r.random() < 0.3 else self.reg()
            self.emit(f"{op} x{a}, x{b}, {end}")
        elif kind == "jal":
            self.emit(f"jal x{self.rd()}, {end}")
        else:
            p = self.reg()
            self.emit(f"la x{p}, {end}")
            off = r.choice([0, 4, -4, 8])
            if off:
                self.emit(f"addi x{p}, x{p}, {-off}")
            self.emit(f"jalr x{self.rd()}, {off}(x{p})")
        for _ in range(r.randint(1, 4)):
            self.shadow_item()
        self.lines.append(f"{end}:")

    def loop(self):
        r = self.r
        top = self.new_label()
        self.emit(f"li x24, {r.randint(2, 5)}")
        self.lines.append(f"{top}:")
        for _ in range(r.randint(1, 5)):
            k = r.random()
            if k < 0.5:
                self.alu()
            elif k < 0.75:
                self.load()
            else:
                self.store()
        self.emit("addi x24, x24, -1")
        self.emit(f"bnez x24, {top}")

    def trap(self):
        self.trap_instr()

    def item(self):
        k = self.r.random()
        if k < 0.07:
            self.muldiv()
        elif k < 0.34:
            self.alu()
        elif k < 0.46:
            self.load()
        elif k < 0.56:
            self.store()
        elif k < 0.61:
            self.device()
        elif k < 0.7:
            self.shadow("branch")
        elif k < 0.74:
            self.shadow("jal")
        elif k < 0.78:
            self.shadow("jalr")
        elif k < 0.82:
            self.loop()
        elif k < 0.88:
            self.trap()
        elif k < 0.94:
            self.csr_item()
        elif k < 0.96:
            self.mret_item()
        else:
            self.emit(self.r.choice(["fence", "fence.i", "wfi", "fence rw, rw", "nop", "c.nop"]))

    def program(self, seed, items, name=None):
        head = [
            f"/* {name or f'rand_{seed:04d}'}: generated by scripts/gen_random_programs.py (seed {seed}"
            + (", profile spike, --long)." if self.spike else ")."),
            " * Checked only against the reference model (no self-checks); do not edit. */",
            '#include "px_test.h"',
            "",
            "  .data",
            "  .balign 4",
            "rbuf:",
        ]
        head += [f"  .word 0x{self.r.getrandbits(32):08x}" for _ in range(1024)]
        head += [
            "",
            "  .text",
            "  .globl test_main",
            "test_main:",
            "  .option rvc",
            "  la   sp, rbuf",
            "  la   x26, rbuf + 2048",
            "  li   x25, 0x20010000",
        ]
        self.lines = head
        for reg in POOL:
            self.emit(f"li x{reg}, {self.const()}")
        for _ in range(items):
            self.item()
        self.emit("PASS")
        self.lines.append("")
        self.lines.append("  TRAPS(-1)          /* no table: the reference model's trap list is authoritative */")
        return "\n".join(self.lines) + "\n"


LONG_SEEDS = range(9, 13)
LONG_ITEMS = 2300


def main():
    if sys.argv[1:] == ["--long"]:
        out = Path("sw/tests/random_long")
        out.mkdir(parents=True, exist_ok=True)
        for seed in LONG_SEEDS:
            text = Gen(seed, "spike").program(seed, LONG_ITEMS, f"rlong_{seed:04d}")
            (out / f"rlong_{seed:04d}.S").write_bytes(text.encode())
            print(f"wrote {out}/rlong_{seed:04d}.S")
        return
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    out = Path("sw/tests/random")
    out.mkdir(parents=True, exist_ok=True)
    for seed in range(first, first + count):
        text = Gen(seed).program(seed, 700)
        (out / f"rand_{seed:04d}.S").write_bytes(text.encode())
        print(f"wrote {out}/rand_{seed:04d}.S")


if __name__ == "__main__":
    main()
