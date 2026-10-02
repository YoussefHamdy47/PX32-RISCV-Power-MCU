#!/usr/bin/env python3
"""px_iss: instruction-set reference model for the tb_core programs (Phase 1 subset).

Written from the RISC-V unprivileged/privileged manuals (release 20240411), not from
the RTL: RV32I, M, C (compressed instructions are executed directly, not expanded),
Zicsr, Zifencei, machine mode with MRET and precise trap entry. M follows the manual's
definitions with Python integers: MULH/MULHSU/MULHU take the upper word of the exact
signed/unsigned 64-bit product; DIV/REM round towards zero with the remainder taking the
dividend's sign; division by zero gives quotient -1 (all ones) and remainder = dividend;
-2^31 / -1 gives quotient -2^31 and remainder 0.

CSRs (the PX32 choices of DECISIONS.md D-022, modelled here from the manual's field
definitions): mstatus (MIE, MPIE writable; MPP reads M; everything else 0), misa
(RV32 I+C, writes ignored), mie/mip/mstatush (read-only 0), mtvec (Direct mode only,
BASE writable), mscratch, mepc (bit 0 zero), mcause (interrupt bit and code [4:0]),
mtval, mcycle(h)/minstret(h), mhpmcounter3-31(h) and mhpmevent3-31 (read-only 0),
mvendorid/marchid/mimpid/mhartid/mconfigptr (read-only 0), pmpcfg0-15/pmpaddr0-63
(read-only 0: no PMP entries before step 2.6). Any other address, and any
write attempt to a read-only address (bits 11:10 = 11), is an illegal instruction. A
write is attempted by CSRRW/CSRRWI always and by CSRRS/CSRRC(I) when the rs1 field (or
zimm) is nonzero, whatever the register holds.

Counters: minstret counts retired instructions. Trapping instructions (including ECALL
and EBREAK) do not retire. A CSR instruction reads the count before itself; when it
writes minstret or minstreth, the write replaces its own increment (Zicsr: "the write is
done instead of the increment"). mcycle depends on memory timing, which this model does
not have, so every mcycle/mcycleh value is unknown: the model tracks unknown values
through registers and memory (taint), writes them with a zero care mask and stops with
an error if one reaches a branch, a jump target, an address or a CSR other than mcycle
(the program would then not be deterministic). A few operations give a known result
from unknown operands (x - x, x ^ x, x & 0, x | -1).

It runs the same ITCM/DTCM images that tb_core loads and writes the reference files
tb_core compares every run against:
  <prefix>.trace.ref   one line per retired instruction, up to and including the
                       store to tohost: pc insn rd rd_wdata mem_addr rmask wmask mem_data
                       care csr_we csr_addr csr_wdata csr_care (hex; mem_data is the
                       loaded word for loads, the store data aligned to its byte lanes for
                       stores; only masked lanes count; care has a 1 for every bit of
                       rd_wdata/mem_data the model knows; csr_wdata is the value of the
                       written CSR after the write, csr_care its known bits)
  <prefix>.traps.ref   first line: trap count; then cause pc tval per trap

Platform model (must match tb/core/tb_core.sv)
  ITCM 64 KB at 0x1000_0000 (fetch, load, store); DTCM 64 KB at 0x2000_0000 (load,
  store); side-effect device at 0x2001_0000: word 0 returns the number of earlier
  reads of word 0 (every read increments it), word 1 counts writes (a write
  increments it, a read returns the count); every other address is an access fault.
  mtvec resets to 0x1000_0040 (the tb_core MTVEC_RESET parameter).

Trap entry: mepc = pc of the trapping instruction, mcause = exception code, mtval as
below, MPIE = MIE, MIE = 0, pc = mtvec BASE. MRET: pc = mepc, MIE = MPIE, MPIE = 1.
mtval: the faulting address for access faults and misaligned accesses; for a fetch
fault on the second half of a 32-bit instruction, the address of that half (pc + 2),
as the privileged manual requires for variable-length instructions; pc for EBREAK;
the instruction bits (16-bit ones zero-extended) for illegal instructions; 0 for ECALL.

Usage: python scripts/px_iss.py <prefix> [max_steps]
       reads <prefix>.itcm.hex and <prefix>.dtcm.hex
"""

import sys
from pathlib import Path

ITCM, DTCM, DEV = 0x10000000, 0x20000000, 0x20010000
SIZE, DEV_SIZE = 0x10000, 0x1000
TOHOST, TRAPVEC, BOOT = 0x2000FFF0, 0x10000040, 0x10000000
M32 = 0xFFFFFFFF


class Nondeterministic(Exception):
    """An unknown (timing-dependent) value reached control flow, an address or a CSR."""


# Implemented CSR addresses (privileged manual table, PX32 subset of D-022)
CSR_RW_ADDRS = {0x300, 0x301, 0x304, 0x305, 0x310, 0x340, 0x341, 0x342, 0x343, 0x344,
                0xB00, 0xB02, 0xB80, 0xB82}
CSR_RW_ADDRS |= set(range(0xB03, 0xB20)) | set(range(0xB83, 0xBA0)) | set(range(0x323, 0x340))
CSR_RW_ADDRS |= set(range(0x3A0, 0x3F0))         # pmpcfg0-15, pmpaddr0-63: zero PMP entries
CSR_RO_ADDRS = {0xF11, 0xF12, 0xF13, 0xF14, 0xF15}
MISA = (1 << 30) | (1 << 12) | (1 << 8) | (1 << 2)   # MXL = 32, I, M, C


class Trap(Exception):
    def __init__(self, cause, tval):
        super().__init__(cause, tval)
        self.cause, self.tval = cause, tval & M32


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def bit(v, hi, lo=None):
    lo = hi if lo is None else lo
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


class Machine:
    def __init__(self, itcm, dtcm):
        self.itcm, self.dtcm = itcm, dtcm
        self.x = [0] * 32               # None = unknown (derived from mcycle)
        self.pc = BOOT
        self.dev_reads = 0
        self.dev_writes = 0
        self.unknown = set()            # byte addresses holding unknown data
        # CSR state
        self.mie = self.mpie = 0
        self.mtvec = TRAPVEC
        self.mscratch = self.mepc = self.mcause = self.mtval = 0
        self.instret = 0                # 64-bit minstret

    # ------------------------------------------------------------------ CSRs
    def csr_read(self, a):
        if a == 0x300:
            return (3 << 11) | (self.mpie << 7) | (self.mie << 3)
        if a == 0x301:
            return MISA
        if a == 0x305:
            return self.mtvec
        if a == 0x340:
            return self.mscratch
        if a == 0x341:
            return self.mepc
        if a == 0x342:
            return self.mcause
        if a == 0x343:
            return self.mtval
        if a in (0xB00, 0xB80):
            return None                 # mcycle: timing dependent
        if a == 0xB02:
            return self.instret & M32
        if a == 0xB82:
            return (self.instret >> 32) & M32
        return 0                        # read-only zero registers

    def csr_write(self, a, v):
        if a in (0xB00, 0xB80):
            return                      # mcycle stays unknown
        if v is None:
            raise Nondeterministic(f"unknown value written to CSR {a:03x}")
        if a == 0x300:
            self.mie, self.mpie = (v >> 3) & 1, (v >> 7) & 1
        elif a == 0x305:
            self.mtvec = v & ~3 & M32   # Direct mode only
        elif a == 0x340:
            self.mscratch = v
        elif a == 0x341:
            self.mepc = v & ~1 & M32
        elif a == 0x342:
            self.mcause = v & 0x8000001F
        elif a == 0x343:
            self.mtval = v
        elif a == 0xB02:
            self.instret = (self.instret & ~M32) | v
        elif a == 0xB82:
            self.instret = (self.instret & M32) | (v << 32)
        # misa, mie, mip, mstatush, hpm counters and events: writes ignored

    def take_trap(self, pc, cause, tval):
        self.mepc = pc & ~1
        self.mcause = cause
        self.mtval = tval & M32
        self.mpie, self.mie = self.mie, 0
        self.pc = self.mtvec & ~3

    # ------------------------------------------------------------------ memory
    def region(self, addr):
        if ITCM <= addr < ITCM + SIZE:
            return self.itcm, addr - ITCM
        if DTCM <= addr < DTCM + SIZE:
            return self.dtcm, addr - DTCM
        return None, 0

    def fetch16(self, addr):
        if not (ITCM <= addr < ITCM + SIZE):
            raise Trap(1, addr)
        o = addr - ITCM
        return self.itcm[o] | (self.itcm[o + 1] << 8)

    def load_word(self, addr):             # addr word aligned; returns (word, fault)
        mem, o = self.region(addr)
        if mem is not None:
            return int.from_bytes(mem[o:o + 4], "little"), False
        if addr == DEV:
            v = self.dev_reads
            self.dev_reads += 1
            return v & M32, False
        if addr == DEV + 4:
            return self.dev_writes & M32, False
        return 0, True

    def store_word(self, addr, data, mask, known=True):
        mem, o = self.region(addr)
        if mem is not None:
            for b in range(4):
                if mask >> b & 1:
                    mem[o + b] = (data >> (8 * b)) & 0xFF
                    if known:
                        self.unknown.discard(addr + b)
                    else:
                        self.unknown.add(addr + b)
            return False
        if addr == DEV:
            return False                  # accepted, no state
        if addr == DEV + 4:
            self.dev_writes += 1
            return False
        return True

    # ------------------------------------------------------------------ decode
    def fetch(self):
        pc = self.pc
        lo = self.fetch16(pc)
        if lo & 3 != 3:
            return lo, 2
        try:
            hi = self.fetch16(pc + 2)
        except Trap as t:                   # the second half faults: tval is its address
            raise Trap(1, t.tval)
        return lo | (hi << 16), 4

    @staticmethod
    def decode32(i):
        """Return (op, rd, rs1, rs2, imm) or None for an illegal/unimplemented word."""
        opc, rd, f3 = bit(i, 6, 0), bit(i, 11, 7), bit(i, 14, 12)
        rs1, rs2, f7 = bit(i, 19, 15), bit(i, 24, 20), bit(i, 31, 25)
        imm_i = sext(i >> 20, 12)
        imm_s = sext((bit(i, 31, 25) << 5) | bit(i, 11, 7), 12)
        imm_b = sext((bit(i, 31) << 12) | (bit(i, 7) << 11) | (bit(i, 30, 25) << 5) |
                     (bit(i, 11, 8) << 1), 13)
        imm_u = i & 0xFFFFF000
        imm_j = sext((bit(i, 31) << 20) | (bit(i, 19, 12) << 12) | (bit(i, 20) << 11) |
                     (bit(i, 30, 21) << 1), 21)
        if opc == 0x37:
            return ("lui", rd, 0, 0, imm_u)
        if opc == 0x17:
            return ("auipc", rd, 0, 0, imm_u)
        if opc == 0x6F:
            return ("jal", rd, 0, 0, imm_j)
        if opc == 0x67 and f3 == 0:
            return ("jalr", rd, rs1, 0, imm_i)
        if opc == 0x63 and f3 in (0, 1, 4, 5, 6, 7):
            return (("beq", "bne", "", "", "blt", "bge", "bltu", "bgeu")[f3], 0, rs1, rs2, imm_b)
        if opc == 0x03 and f3 in (0, 1, 2, 4, 5):
            return (("lb", "lh", "lw", "", "lbu", "lhu")[f3], rd, rs1, 0, imm_i)
        if opc == 0x23 and f3 in (0, 1, 2):
            return (("sb", "sh", "sw")[f3], 0, rs1, rs2, imm_s)
        if opc == 0x13:
            if f3 == 1:
                return ("sll", rd, rs1, -1, rs2) if f7 == 0 else None
            if f3 == 5:
                if f7 == 0:
                    return ("srl", rd, rs1, -1, rs2)
                if f7 == 0x20:
                    return ("sra", rd, rs1, -1, rs2)
                return None
            return (("add", "", "slt", "sltu", "xor", "", "or", "and")[f3], rd, rs1, -1, imm_i)
        if opc == 0x33:
            if f7 == 0:
                return (("add", "sll", "slt", "sltu", "xor", "srl", "or", "and")[f3], rd, rs1, rs2, 0)
            if f7 == 0x20 and f3 in (0, 5):
                return (("sub" if f3 == 0 else "sra"), rd, rs1, rs2, 0)
            if f7 == 1:
                return (("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu")[f3],
                        rd, rs1, rs2, 0)
            return None
        if opc == 0x0F and f3 in (0, 1):
            return ("nop", 0, 0, 0, 0)       # FENCE (all field values) and FENCE.I
        if opc == 0x73:
            if i == 0x00000073:
                return ("ecall", 0, 0, 0, 0)
            if i == 0x00100073:
                return ("ebreak", 0, 0, 0, 0)
            if i == 0x10500073:
                return ("nop", 0, 0, 0, 0)   # WFI
            if i == 0x30200073:
                return ("mret", 0, 0, 0, 0)
            if f3 in (1, 2, 3, 5, 6, 7):
                # (op, rd, rs1 field / zimm, funct3, csr address)
                return ("csr", rd, rs1, f3, bit(i, 31, 20))
            return None                     # SRET, URET, other SYSTEM encodings
        return None

    @staticmethod
    def decode16(c):
        q, f3 = c & 3, bit(c, 15, 13)
        r_p, s_p = 8 + bit(c, 9, 7), 8 + bit(c, 4, 2)
        rd, rs2 = bit(c, 11, 7), bit(c, 6, 2)
        ci = sext((bit(c, 12) << 5) | bit(c, 6, 2), 6)
        sh = (bit(c, 12) << 5) | bit(c, 6, 2)
        cj = sext((bit(c, 12) << 11) | (bit(c, 11) << 4) | (bit(c, 10, 9) << 8) |
                  (bit(c, 8) << 10) | (bit(c, 7) << 6) | (bit(c, 6) << 7) |
                  (bit(c, 5, 3) << 1) | (bit(c, 2) << 5), 12)
        cb = sext((bit(c, 12) << 8) | (bit(c, 11, 10) << 3) | (bit(c, 6, 5) << 6) |
                  (bit(c, 4, 3) << 1) | (bit(c, 2) << 5), 9)
        if q == 0:
            uw = (bit(c, 12, 10) << 3) | (bit(c, 6) << 2) | (bit(c, 5) << 6)
            if f3 == 0:
                nz = (bit(c, 12, 11) << 4) | (bit(c, 10, 7) << 6) | (bit(c, 6) << 2) | (bit(c, 5) << 3)
                return ("add", s_p, 2, -1, nz) if nz else None
            if f3 == 2:
                return ("lw", s_p, r_p, 0, uw)
            if f3 == 6:
                return ("sw", 0, r_p, s_p, uw)
            return None
        if q == 1:
            if f3 == 0:
                return ("add", rd, rd, -1, ci)
            if f3 == 1:
                return ("jal", 1, 0, 0, cj)
            if f3 == 2:
                return ("add", rd, 0, -1, ci)
            if f3 == 3:
                if rd == 2:
                    nz = sext((bit(c, 12) << 9) | (bit(c, 6) << 4) | (bit(c, 5) << 6) |
                              (bit(c, 4, 3) << 7) | (bit(c, 2) << 5), 10)
                    return ("add", 2, 2, -1, nz) if nz else None
                return ("lui", rd, 0, 0, (ci << 12) & M32) if ci else None
            if f3 == 4:
                f2 = bit(c, 11, 10)
                if f2 in (0, 1):
                    return None if bit(c, 12) else (("srl", "sra")[f2], r_p, r_p, -1, sh)
                if f2 == 2:
                    return ("and", r_p, r_p, -1, ci)
                if bit(c, 12):
                    return None
                return (("sub", "xor", "or", "and")[bit(c, 6, 5)], r_p, r_p, s_p, 0)
            if f3 == 5:
                return ("jal", 0, 0, 0, cj)
            return (("beq" if f3 == 6 else "bne"), 0, r_p, 0, cb)
        # quadrant 2
        if f3 == 0:
            return None if bit(c, 12) else ("sll", rd, rd, -1, sh)
        if f3 == 2:
            u = (bit(c, 12) << 5) | (bit(c, 6, 4) << 2) | (bit(c, 3, 2) << 6)
            return ("lw", rd, 2, 0, u) if rd else None
        if f3 == 4:
            if not bit(c, 12):
                if rs2 == 0:
                    return ("jalr", 0, rd, 0, 0) if rd else None
                return ("add", rd, 0, rs2, 0)
            if rs2 == 0 and rd == 0:
                return ("ebreak", 0, 0, 0, 0)
            if rs2 == 0:
                return ("jalr", 1, rd, 0, 0)
            return ("add", rd, rd, rs2, 0)
        if f3 == 6:
            u = (bit(c, 12, 9) << 2) | (bit(c, 8, 7) << 6)
            return ("sw", 0, 2, rs2, u)
        return None

    # ------------------------------------------------------------------ execute
    def step(self):
        """Execute one instruction. Returns ('retire', record) or ('trap', (cause, pc, tval))."""
        pc = self.pc
        try:
            insn, length = self.fetch()
            d = self.decode32(insn) if length == 4 else self.decode16(insn)
            if d is None:
                raise Trap(2, insn)
            rec = self.execute(pc, insn, length, d)
            return "retire", rec
        except Trap as t:
            self.take_trap(pc, t.cause, t.tval)
            return "trap", (t.cause, pc, t.tval)

    def need(self, v, what):
        if v is None:
            raise Nondeterministic(f"unknown value used as {what} at pc {self.pc:08x}")
        return v

    def execute(self, pc, insn, length, d):
        op, rd, rs1, rs2, imm = d
        a = self.x[rs1]
        if op == "csr":
            b = None
        else:
            b = imm & M32 if rs2 == -1 else self.x[rs2]
        nxt = (pc + length) & M32
        wval = None
        writes = False
        maddr, rmask, wmask, mdata, mcare = 0, 0, 0, 0, M32
        count = True
        self.csr_written = None
        if op == "lui":
            wval, writes = imm, True
        elif op == "auipc":
            wval, writes = pc + imm, True
        elif op == "jal":
            wval, writes, nxt = nxt, True, (pc + imm) & M32
        elif op == "jalr":
            wval, writes, nxt = nxt, True, (self.need(a, "jump base") + imm) & M32 & ~1
        elif op in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            a, b = self.need(a, "branch operand"), self.need(self.x[rs2], "branch operand")
            sa, sb = sext(a, 32), sext(b, 32)
            take = {"beq": a == b, "bne": a != b, "blt": sa < sb, "bge": sa >= sb,
                    "bltu": a < b, "bgeu": a >= b}[op]
            if take:
                nxt = (pc + imm) & M32
        elif op in ("lb", "lh", "lw", "lbu", "lhu"):
            addr = (self.need(a, "load address") + imm) & M32
            size = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}[op]
            if addr % size:
                raise Trap(4, addr)
            word, fault = self.load_word(addr & ~3)
            if fault:
                raise Trap(5, addr)
            v = (word >> (8 * (addr & 3))) & ((1 << (8 * size)) - 1)
            wval = v if op in ("lbu", "lhu", "lw") else sext(v, 8 * size)
            writes = True
            if any(addr + k in self.unknown for k in range(size)):
                wval = None
            maddr, rmask, mdata = addr, ((1 << size) - 1) << (addr & 3), word
            for k in range(4):
                if (addr & ~3) + k in self.unknown:
                    mcare &= ~(0xFF << (8 * k))
        elif op in ("sb", "sh", "sw"):
            addr = (self.need(a, "store address") + imm) & M32
            size = {"sb": 1, "sh": 2, "sw": 4}[op]
            if addr % size:
                raise Trap(6, addr)
            mask = ((1 << size) - 1) << (addr & 3)
            known = b is not None
            data = ((b if known else 0) << (8 * (addr & 3))) & M32
            if self.store_word(addr & ~3, data, mask, known):
                raise Trap(7, addr)
            maddr, wmask, mdata = addr, mask, data
            if not known:
                mcare = 0
        elif op in ("add", "sub", "sll", "srl", "sra", "slt", "sltu", "xor", "or", "and",
                    "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"):
            writes = True
            wval = self.alu(op, a, b, rs1, rs2)
        elif op == "csr":
            wval, count = self.csr_op(insn, rd, rs1, rs2, imm)
            writes = True
        elif op == "mret":
            nxt = self.mepc
            self.mie, self.mpie = self.mpie, 1
        elif op == "ecall":
            raise Trap(11, 0)
        elif op == "ebreak":
            raise Trap(3, pc)
        elif op == "nop":
            pass
        else:
            raise AssertionError(op)
        rd_out, rd_val, care = 0, 0, M32
        if writes and rd != 0:
            if wval is None:
                self.x[rd] = None
                rd_out, rd_val, care = rd, 0, 0
            else:
                self.x[rd] = wval & M32
                rd_out, rd_val = rd, wval & M32
        elif (rmask or wmask) and mcare != M32:
            care = mcare
        if count:
            self.instret = (self.instret + 1) & ((1 << 64) - 1)
        self.pc = nxt
        cw, caddr, cval, ccare = 0, 0, 0, M32
        if self.csr_written is not None:
            cw, caddr, cval = 1, self.csr_written[0], self.csr_written[1]
            if cval is None:
                cval, ccare = 0, 0
        return (pc, insn, rd_out, rd_val, maddr, rmask, wmask, mdata, care, cw, caddr, cval, ccare)

    @staticmethod
    def alu(op, a, b, rs1, rs2):
        if a is None or b is None:
            same = rs2 != -1 and rs1 == rs2
            if op in ("sub", "xor") and same:
                return 0
            if op == "and" and 0 in (a, b):
                return 0
            if op == "or" and M32 in (a, b):
                return M32
            return None
        sa, sb = sext(a, 32), sext(b, 32)
        if op in ("mul", "mulh", "mulhsu", "mulhu"):
            x = sa if op in ("mulh", "mulhsu") else a
            y = sb if op == "mulh" else b
            prod = x * y                              # exact, unbounded
            return (prod if op == "mul" else prod >> 32) & M32
        if op in ("div", "rem"):
            if sb == 0:
                return -1 if op == "div" else a
            if sa == -2**31 and sb == -1:
                return sa if op == "div" else 0
            q = abs(sa) // abs(sb)
            if (sa < 0) != (sb < 0):
                q = -q                                # round towards zero
            return q if op == "div" else sa - q * sb
        if op in ("divu", "remu"):
            if b == 0:
                return M32 if op == "divu" else a
            return a // b if op == "divu" else a % b
        return {"add": a + b, "sub": a - b, "sll": a << (b & 31), "srl": a >> (b & 31),
                "sra": sa >> (b & 31), "slt": int(sa < sb), "sltu": int(a < b),
                "xor": a ^ b, "or": a | b, "and": a & b}[op]

    def csr_op(self, insn, rd, rs1, f3, addr):
        """Zicsr semantics. Returns (value for rd, whether minstret counts this instruction)."""
        write = f3 in (1, 5) or rs1 != 0            # encoding decides, not the value
        if addr not in CSR_RW_ADDRS and addr not in CSR_RO_ADDRS:
            raise Trap(2, insn)
        if write and (addr >> 10) == 3:
            raise Trap(2, insn)
        src = rs1 if f3 >= 5 else self.x[rs1]       # zimm or rs1 value
        old = self.csr_read(addr)                   # read before any write
        if write:
            kind = f3 & 3
            if kind == 1:
                new = src
            elif old is None or src is None:
                new = None
            elif kind == 2:
                new = old | src
            else:
                new = old & ~src & M32
            self.csr_write(addr, new)
            # value of the CSR after the write, as a read returns it (mcycle: the written
            # value, unknown if it was computed from mcycle)
            after = new if addr in (0xB00, 0xB80) else self.csr_read(addr)
            self.csr_written = (addr, after)
        count = not (write and addr in (0xB02, 0xB82))
        return old, count


def load_hex(path):
    """$readmemh semantics: one word per token; @<hex word index> moves the address."""
    out = bytearray(SIZE)
    k = 0
    for tok in Path(path).read_text().split():
        if tok.startswith("@"):
            k = int(tok[1:], 16)
            continue
        if k >= SIZE // 4:
            sys.exit(f"{path}: word {k} beyond the {SIZE}-byte memory")
        out[4 * k:4 * k + 4] = int(tok, 16).to_bytes(4, "little")
        k += 1
    return out


def main():
    prefix = sys.argv[1]
    max_steps = int(sys.argv[2]) if len(sys.argv) > 2 else 2_000_000
    m = Machine(load_hex(prefix + ".itcm.hex"), load_hex(prefix + ".dtcm.hex"))
    trace, traps = [], []
    for _ in range(max_steps):
        try:
            kind, r = m.step()
        except Nondeterministic as e:
            sys.exit(f"{prefix}: {e}")
        if kind == "trap":
            traps.append(r)
            continue
        trace.append(r)
        if r[6] and r[4] == TOHOST:
            break
    else:
        sys.exit(f"{prefix}: no tohost store within {max_steps} instructions")
    lines = ["%08x %08x %02d %08x %08x %x %x %08x %08x %d %03x %08x %08x" % t for t in trace]
    Path(prefix + ".trace.ref").write_bytes(("\n".join(lines) + "\n").encode())
    tl = [str(len(traps))] + ["%d %08x %08x" % t for t in traps]
    Path(prefix + ".traps.ref").write_bytes(("\n".join(tl) + "\n").encode())
    print(f"{prefix}: {len(trace)} retired, {len(traps)} traps")


if __name__ == "__main__":
    main()
