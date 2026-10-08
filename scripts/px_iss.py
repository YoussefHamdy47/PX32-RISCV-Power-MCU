#!/usr/bin/env python3
"""px_iss: instruction-set reference model for the tb_core programs.

Written from the RISC-V unprivileged/privileged manuals (release 20240411), not from
the RTL: RV32I, M, C (compressed instructions are executed directly, not expanded),
Zicsr, Zifencei, Zba/Zbb/Zbs 1.0.0 and Zicond 1.0 (Phase 2 step 2.1), machine mode with
MRET and precise trap entry. M follows the manual's
definitions with Python integers: MULH/MULHSU/MULHU take the upper word of the exact
signed/unsigned 64-bit product; DIV/REM round towards zero with the remainder taking the
dividend's sign; division by zero gives quotient -1 (all ones) and remainder = dividend;
-2^31 / -1 gives quotient -2^31 and remainder 0.
Bit manipulation, from the instruction descriptions of the manual's "B" chapter (RV32,
XLEN = 32): shNadd rd = rs2 + (rs1 << N); andn/orn/xnor with the inverted rs2; clz/ctz
count from the most/least significant end (32 for 0); cpop counts ones; min/max signed
and unsigned; sext.b/sext.h/zext.h; rol/ror/rori rotate by the low 5 bits; orc.b sets
each nonzero byte to 0xFF; rev8 reverses the bytes; bclr/bext/binv/bset (and their
immediate forms) act on bit (rs2 or shamt) mod 32. Zicond: czero.eqz rd = 0 if rs2 == 0
else rs1; czero.nez rd = 0 if rs2 != 0 else rs1. The RV64-only forms (.w, .uw, shamt[5]
set, the RV64 rev8 encoding) are illegal.

CSRs (the PX32 choices of DECISIONS.md D-022, modelled here from the manual's field
definitions): mstatus (MIE, MPIE writable; MPP reads M; everything else 0), misa
(RV32 I, M, C and B, writes ignored), mie/mip/mstatush (read-only 0), mtvec (Direct mode only,
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
                       care csr_we csr_addr csr_wdata csr_care side_we side0..side3 (hex;
                       mem_data is the loaded word for loads, the store data aligned to its
                       byte lanes for stores; only masked lanes count; care has a 1 for
                       every bit of rd_wdata/mem_data the model knows; csr_wdata is the
                       value of the written CSR after the write, csr_care its known bits;
                       side_we/side0-3 the writes of other CSRs, step 2.2d)
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

Interrupts (Phase 2 step 2.2b, DECISIONS.md D-033; PHASE2_VERIFICATION.md § 3.3, schedule
replay): the time of an interrupt depends on memory timing, so the model cannot predict it.
`--replay <manifest>` re-executes every run listed by tb_core (one event log per run: R a
retirement, T an exception, I an interrupt with its id and the pc the core saved, E the
totals) and takes each interrupt at the recorded instruction boundary. At that boundary it
checks independently that the interrupt was allowed (mstatus.MIE = 1) and that the core's
saved pc is the model's next pc, then enters the trap as the privileged manual specifies for
an interrupt: mepc = the next pc, mcause = interrupt bit and the code (the interrupt id; the
D-022 mcause keeps code bits [4:0]), mtval = 0, MPIE = MIE, MIE = 0, pc = mtvec BASE. Every
retirement and exception before and after is compared with the model as for a static
reference (same fields, same care masks), and the log must end with the tohost store.

CLIC (Phase 2 step 2.2d, DECISIONS.md D-035; written from the pinned CLIC draft 0.9, the
"CLIC CSRs", "CLIC Interrupt Operation" and "smclicshv" chapters, PHASE2_CLIC_MATRIX.md and the
platform choices of D-034/D-035, not from px_clic or the bench models):
  CSRs: mtvec mode WARL {00, 11} (CLIC mode = 11, base [31:6]); mtvt [31:6]; mcause in CLIC
  format {interrupt, minhv, mpp = 11, mpie = mstatus.MPIE, mpil, exccode[5:0]} or the D-022
  CLINT format; leaving CLIC mode zeroes mpil and minhv; mnxti (only csrr, csrrsi, csrrci,
  uimm bits 0, 2, 4 clear); mintthresh (reads 0 in CLINT mode); mscratchcswl (csrrw with rd
  and rs1 not x0; swaps when (mpil == 0) != (mil == 0) in CLIC mode); mintstatus (mil,
  read-only). Other forms of mnxti/mscratchcswl and mscratchcsw (0x348) are illegal.
  Entry in CLIC mode: mcause = {interrupt, minhv, mpil = mil, code}, an interrupt sets
  mil = its level, an exception keeps it; target NBASE, or for a vectored interrupt the
  table word M[TBASE + 4 * id] & ~1 (a table fetch outside ITCM is an instruction access
  fault with minhv = 1, mepc = mtval = the table address); MRET sets mil = mpil and with
  minhv = 1 refetches the table word at mepc & ~3. The trace reports side writes of other
  CSRs in four slots (mstatus, mscratch, mcause, mintstatus).
  Memory-mapped CLIC at 0xE000_0000 (64 KiB): entry i at 0x1000 + 4i (i < 64): byte 0
  clicintip (bit 0), 1 clicintie (bit 0), 2 clicintattr (mode reads 11, bit 2 negative
  polarity, bit 1 edge, bit 0 shv), 3 clicintctl (bits 7:4 the level, 3:0 read 1111); all
  else reads 0, writes ignored. Pending: level mode = input ^ polarity; edge mode set by an
  edge of the input (raw sample against the previous cycle's), else written by software,
  else cleared by a vectored take of the id or an mnxti claim. Selection: the maximum
  {level, id} of the pending-and-enabled inputs (ties to the higher id), registered: the
  winner presented in cycle c is the maximum of cycle c-1's state, invalid if that id was
  acknowledged or claimed in cycle c-1; a store, claim or take acts at the end of its cycle.
  A request is presented while the winner is valid, the mode is CLIC and its level is above
  mil and mintthresh.
  The CLIC depends on time, so CLIC programs are interrupt programs checked by replay: the
  event log carries the cycle of every input change (X lines), the cycle in which each
  retired instruction left EX (its data grant or CSR commit) and retired, and the cycle of
  every take. px_iss models the CLIC cycle by cycle from those stamps and checks: every
  interrupt was eligible (pending, enabled, the maximum, above max(mil, mintthresh), MIE = 1,
  CLIC mode) when taken, its target, every CLIC register read, every mnxti value and claim,
  every CSR side write; and that no interrupt stays eligible for four retirement boundaries
  without being taken (a missing take).

Usage: python scripts/px_iss.py <prefix> [max_steps]
       reads <prefix>.itcm.hex and <prefix>.dtcm.hex
       python scripts/px_iss.py --replay <manifest>    (tb_core interrupt runs)
"""

import sys
from pathlib import Path

ITCM, DTCM, DEV = 0x10000000, 0x20000000, 0x20010000
SIZE, DEV_SIZE = 0x10000, 0x1000
TOHOST, TRAPVEC, BOOT = 0x2000FFF0, 0x10000040, 0x10000000
M32 = 0xFFFFFFFF
CLIC_BASE, CLIC_SIZE, NIRQ = 0xE0000000, 0x10000, 64
M64 = (1 << 64) - 1
MISSING_TAKE_BOUNDARIES = 4


class Nondeterministic(Exception):
    """An unknown (timing-dependent) value reached control flow, an address or a CSR."""


# Implemented CSR addresses (privileged manual table, PX32 subset of D-022)
CSR_RW_ADDRS = {0x300, 0x301, 0x304, 0x305, 0x310, 0x340, 0x341, 0x342, 0x343, 0x344,
                0xB00, 0xB02, 0xB80, 0xB82}
CSR_RW_ADDRS |= set(range(0xB03, 0xB20)) | set(range(0xB83, 0xBA0)) | set(range(0x323, 0x340))
CSR_RW_ADDRS |= set(range(0x3A0, 0x3F0))         # pmpcfg0-15, pmpaddr0-63: zero PMP entries
CSR_RW_ADDRS |= {0x307, 0x345, 0x347, 0x349}      # CLIC: mtvt, mnxti, mintthresh, mscratchcswl
CSR_RO_ADDRS = {0xF11, 0xF12, 0xF13, 0xF14, 0xF15, 0xFB1}   # IDs; mintstatus
# MXL = 32, I, M, C and B (privileged manual: B = Zba, Zbb and Zbs all implemented)
MISA = (1 << 30) | (1 << 12) | (1 << 8) | (1 << 2) | (1 << 1)


BITMANIP = ("sh1add", "sh2add", "sh3add", "andn", "orn", "xnor", "clz", "ctz", "cpop",
            "max", "maxu", "min", "minu", "sext.b", "sext.h", "zext.h", "rol", "ror",
            "orc.b", "rev8", "bclr", "bext", "binv", "bset", "czero.eqz", "czero.nez")
ALU_OPS = ("add", "sub", "sll", "srl", "sra", "slt", "sltu", "xor", "or", "and",
           "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu") + BITMANIP


def bitmanip(op, a, b):
    """Zba/Zbb/Zbs/Zicond on known 32-bit operands a (rs1) and b (rs2 or immediate)."""
    s = b & 31                                     # shift amount / bit index (RV32)
    if op in ("sh1add", "sh2add", "sh3add"):
        return (b + (a << int(op[2]))) & M32
    if op == "andn":
        return a & ~b & M32
    if op == "orn":
        return (a | ~b) & M32
    if op == "xnor":
        return ~(a ^ b) & M32
    if op == "clz":
        return next((31 - k for k in range(31, -1, -1) if a >> k & 1), 32)
    if op == "ctz":
        return next((k for k in range(32) if a >> k & 1), 32)
    if op == "cpop":
        return bin(a).count("1")
    if op in ("max", "min"):
        sa, sb = sext(a, 32), sext(b, 32)
        return (max if op == "max" else min)(sa, sb) & M32
    if op in ("maxu", "minu"):
        return (max if op == "maxu" else min)(a, b)
    if op == "sext.b":
        return sext(a, 8) & M32
    if op == "sext.h":
        return sext(a, 16) & M32
    if op == "zext.h":
        return a & 0xFFFF
    if op == "rol":
        return ((a << s) | (a >> (32 - s))) & M32
    if op == "ror":
        return ((a >> s) | (a << (32 - s))) & M32
    if op == "orc.b":
        return sum((0xFF << (8 * k)) for k in range(4) if (a >> (8 * k)) & 0xFF)
    if op == "rev8":
        return int.from_bytes(a.to_bytes(4, "little"), "big")
    if op == "bclr":
        return a & ~(1 << s) & M32
    if op == "bext":
        return (a >> s) & 1
    if op == "binv":
        return a ^ (1 << s)
    if op == "bset":
        return a | (1 << s)
    if op == "czero.eqz":
        return 0 if b == 0 else a
    if op == "czero.nez":
        return 0 if b != 0 else a
    raise AssertionError(op)


class Clic:
    """The memory-mapped CLIC and its registered winner, cycle by cycle (see the docstring).

    State "during cycle c" is the state after the edge that ends cycle c-1. Events stamped c
    (stores, claims, takes) act at the edge that ends cycle c. inputs(c) is the input vector
    during cycle c, from the X lines of the event log.
    """

    def __init__(self, xlines):
        self.xs = sorted(xlines)          # (cycle, vector)
        self.xi = 0
        self.cyc = 0                      # current state = state during cycle self.cyc
        self.pend = self.ie = self.edge = self.neg = self.shv = 0
        self.lvl = [0] * NIRQ             # PX32 level bits (clicintctl[7:4])
        self.w = None                     # winner presented in cycle self.cyc: (id, level, shv)
        self.events = {}                  # cycle -> list of ("st", off, be, data) / ("ack", id) / ("claim", id)
        self.inp_last = 0
        self.inp = self.input_at(0)       # inputs during self.cyc
        self.prev = 0                     # inputs during self.cyc - 1

    def input_at(self, c):
        while self.xi < len(self.xs) and self.xs[self.xi][0] <= c:
            self.inp_last = self.xs[self.xi][1]
            self.xi += 1
        return self.inp_last

    def add_event(self, c, ev):
        if c < self.cyc:
            raise Nondeterministic(f"CLIC event at cycle {c} after the model reached cycle {self.cyc}")
        self.events.setdefault(c, []).append(ev)

    @staticmethod
    def level8(l4):
        return (l4 << 4) | 0xF

    def max_of(self, cand):
        best = None
        while cand:
            i = cand.bit_length() - 1
            cand &= ~(1 << i)
            k = (self.lvl[i], i)
            if best is None or k > best:
                best = k
        return best

    def step(self):
        """State during self.cyc -> state during self.cyc + 1."""
        c = self.cyc
        evs = self.events.pop(c, [])
        inp = self.inp
        w_ip = w_ie = w_attr = w_ctl = 0          # masks of entries written this cycle (per field)
        d_ip = d_ie = 0
        attr_new, ctl_new = {}, {}
        clr = 0
        inval = set()
        for ev in evs:
            if ev[0] == "st":
                _, off, be, data = ev
                i = self.entry(off)
                if i is None:
                    continue
                b = 1 << i
                if be & 1:
                    w_ip |= b
                    if data & 1:
                        d_ip |= b
                if be & 2:
                    w_ie |= b
                    if (data >> 8) & 1:
                        d_ie |= b
                if be & 4:
                    w_attr |= b
                    attr_new[i] = (data >> 16) & 7
                if be & 8:
                    w_ctl |= b
                    ctl_new[i] = (data >> 28) & 0xF
            elif ev[0] == "ack":
                inval.add(ev[1])
                if self.w is not None and self.w[2]:      # cleared only after a vectored entry
                    clr |= 1 << ev[1]
            elif ev[0] == "claim":
                inval.add(ev[1])
                clr |= 1 << ev[1]
        # winner presented in the next cycle: the maximum of this cycle's state
        cand = self.pend & self.ie
        m = self.max_of(cand)
        if m is None or m[1] in inval:
            nw = None
        else:
            nw = (m[1], self.level8(m[0]), bool((self.shv >> m[1]) & 1))
        # pending flops (edge > software write > clear > hold; level mode follows the input)
        ev_edge = ((~self.neg & inp & ~self.prev) | (self.neg & ~inp & self.prev)) & M64
        pe = ev_edge | (w_ip & d_ip) | (~w_ip & ~clr & self.pend & M64)
        self.pend = ((self.edge & pe) | (~self.edge & (inp ^ self.neg))) & M64
        self.ie = (w_ie & d_ie) | (~w_ie & self.ie & M64)
        for i, a in attr_new.items():
            b = 1 << i
            self.shv = (self.shv & ~b) | ((a & 1) << i)
            self.edge = (self.edge & ~b) | (((a >> 1) & 1) << i)
            self.neg = (self.neg & ~b) | (((a >> 2) & 1) << i)
        for i, l4 in ctl_new.items():
            self.lvl[i] = l4
        self.w = nw
        self.cyc = c + 1
        self.prev = inp
        self.inp = self.input_at(self.cyc)

    def advance_to(self, c):
        if c < self.cyc:
            raise Nondeterministic(f"CLIC model asked for cycle {c} after reaching cycle {self.cyc}")
        while self.cyc < c:
            self.step()

    @staticmethod
    def entry(off):
        if (off >> 12) == 1 and ((off >> 2) & 0x3FF) < NIRQ:
            return (off >> 2) & 0x3FF
        return None

    def read(self, off):
        """Word at offset off (state during the current cycle)."""
        i = self.entry(off)
        if i is None:
            return 0
        attr = 0xC0 | (((self.neg >> i) & 1) << 2) | (((self.edge >> i) & 1) << 1) | ((self.shv >> i) & 1)
        ctl = (self.lvl[i] << 4) | 0xF
        return (ctl << 24) | (attr << 16) | (((self.ie >> i) & 1) << 8) | ((self.pend >> i) & 1)


class Trap(Exception):
    def __init__(self, cause, tval, inhv=0, pc=None):
        super().__init__(cause, tval)
        self.cause, self.tval, self.inhv, self.pc = cause, tval & M32, inhv, pc


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
        self.mtvec = TRAPVEC            # read value: base and mode bits (11 = CLIC mode)
        self.mscratch = self.mepc = self.mtval = 0
        self.mc_irq = self.mc_inhv = self.mc_pil = self.mc_code = 0   # mcause fields
        self.mtvt = self.mil = self.mth = 0
        self.instret = 0                # 64-bit minstret
        self.clic = None                # Clic model (replay runs only)
        self.stamp_ex = self.stamp_ret = None
        self.csr_side = {}              # slot -> value written to another CSR
        self.vec_fault = None           # table address of a vector fetch that faults next

    # ------------------------------------------------------------------ CSRs
    def clic_mode(self):
        return (self.mtvec & 3) == 3

    def mcause_val(self):
        if self.clic_mode():
            return ((self.mc_irq << 31) | (self.mc_inhv << 30) | (3 << 28) | (self.mpie << 27) |
                    (self.mc_pil << 16) | self.mc_code)
        return (self.mc_irq << 31) | (self.mc_code & 0x1F)

    def winner(self):
        """CLIC winner presented in the cycle of the current instruction's EX commit."""
        if self.clic is None:
            raise Nondeterministic("CLIC winner needed outside a replay run")
        self.clic.advance_to(self.stamp_ex)
        return self.clic.w

    def nxti(self):
        """(mnxti read value, winner it names or None)."""
        if not self.clic_mode():
            return 0, None
        w = self.winner()
        if w is None or w[2] or w[1] <= self.mc_pil or w[1] <= self.mth:
            return 0, None
        return (self.mtvt + 4 * w[0]) & M32, w

    def cswl_swap(self):
        return self.clic_mode() and ((self.mc_pil == 0) != (self.mil == 0))

    def csr_read(self, a):
        if a == 0x300:
            return (3 << 11) | (self.mpie << 7) | (self.mie << 3)
        if a == 0x301:
            return MISA
        if a == 0x305:
            return self.mtvec
        if a == 0x307:
            return self.mtvt
        if a == 0x340:
            return self.mscratch
        if a == 0x341:
            return self.mepc
        if a == 0x342:
            return self.mcause_val()
        if a == 0x343:
            return self.mtval
        if a == 0x345:
            return self.nxti()[0]
        if a == 0x347:
            return self.mth if self.clic_mode() else 0
        if a == 0xFB1:
            return self.mil << 24
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
            was = self.clic_mode()
            self.mtvec = ((v & 0xFFFFFFC0) | 3) if (v & 3) == 3 else (v & ~3 & M32)
            if was and not self.clic_mode():       # leaving CLIC mode zeroes pil and inhv
                self.mc_pil = self.mc_inhv = 0
                self.csr_side[2] = self.mcause_val()
        elif a == 0x307:
            self.mtvt = v & 0xFFFFFFC0
        elif a == 0x340:
            self.mscratch = v
        elif a == 0x341:
            self.mepc = v & ~1 & M32
        elif a == 0x342:
            self.mc_irq = v >> 31
            if self.clic_mode():
                self.mc_inhv, self.mc_pil, self.mc_code = (v >> 30) & 1, (v >> 16) & 0xFF, v & 0x3F
                self.mpie = (v >> 27) & 1             # the mpie alias writes mstatus.MPIE
                self.csr_side[0] = self.csr_read(0x300)
            else:
                self.mc_code = v & 0x1F
        elif a == 0x347:
            self.mth = v & 0xFF
        elif a == 0x343:
            self.mtval = v
        elif a == 0xB02:
            self.instret = (self.instret & ~M32) | v
        elif a == 0xB82:
            self.instret = (self.instret & M32) | (v << 32)
        # misa, mie, mip, mstatush, hpm counters and events: writes ignored

    def take_trap(self, pc, cause, tval, irq=0, inhv=0, level=0):
        self.mepc = pc & ~1
        self.mc_irq, self.mc_code = irq, cause
        if self.clic_mode():
            self.mc_inhv, self.mc_pil = inhv, self.mil
            if irq:
                self.mil = level
        self.mtval = tval & M32
        self.mpie, self.mie = self.mie, 0
        self.pc = self.mtvec & ~3 & M32           # OBASE, or NBASE (bits 5:2 are 0 in CLIC mode)

    def table_fetch(self, addr):
        """Handler address from the vector table entry at addr, or None (fetch fault)."""
        if not (ITCM <= addr < ITCM + SIZE - 3):
            return None
        o = addr - ITCM
        return int.from_bytes(self.itcm[o:o + 4], "little") & ~1

    def take_interrupt(self, code, level=0, shv=False):
        """Interrupt entry before the instruction at self.pc (it does not execute)."""
        self.take_trap(self.pc, code, 0, irq=1, level=level)
        if shv:
            tbl = (self.mtvt + 4 * code) & M32
            h = self.table_fetch(tbl)
            if h is None:
                self.vec_fault = tbl
            else:
                self.pc = h

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
        if CLIC_BASE <= addr < CLIC_BASE + CLIC_SIZE:
            if self.clic is None:
                raise Nondeterministic("CLIC access outside a replay run")
            self.clic.advance_to(self.stamp_ex)
            return self.clic.read(addr - CLIC_BASE), False
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
        if CLIC_BASE <= addr < CLIC_BASE + CLIC_SIZE:
            if self.clic is None:
                raise Nondeterministic("CLIC access outside a replay run")
            if not known:
                raise Nondeterministic(f"unknown value stored to the CLIC at {addr:08x}")
            self.clic.advance_to(self.stamp_ex)
            self.clic.add_event(self.stamp_ex, ("st", addr - CLIC_BASE, mask, data))
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
            imm12 = bit(i, 31, 20)
            if f3 == 1:
                # shift-immediate forms: imm[11:5] is the funct7, rs2 field = shamt[4:0]
                op = {0x00: "sll", 0x24: "bclr", 0x34: "binv", 0x14: "bset"}.get(f7)
                if op:
                    return (op, rd, rs1, -1, rs2)
                op = {0x600: "clz", 0x601: "ctz", 0x602: "cpop", 0x604: "sext.b",
                      0x605: "sext.h"}.get(imm12)
                return (op, rd, rs1, -1, 0) if op else None
            if f3 == 5:
                op = {0x00: "srl", 0x20: "sra", 0x30: "ror", 0x24: "bext"}.get(f7)
                if op:
                    return (op, rd, rs1, -1, rs2)
                op = {0x287: "orc.b", 0x698: "rev8"}.get(imm12)
                return (op, rd, rs1, -1, 0) if op else None
            return (("add", "", "slt", "sltu", "xor", "", "or", "and")[f3], rd, rs1, -1, imm_i)
        if opc == 0x33:
            if f7 == 0:
                return (("add", "sll", "slt", "sltu", "xor", "srl", "or", "and")[f3], rd, rs1, rs2, 0)
            if f7 == 1:
                return (("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu")[f3],
                        rd, rs1, rs2, 0)
            if f7 == 0x04 and f3 == 4 and rs2 == 0:
                return ("zext.h", rd, rs1, -1, 0)
            op = {(0x20, 0): "sub", (0x20, 5): "sra", (0x20, 7): "andn", (0x20, 6): "orn",
                  (0x20, 4): "xnor", (0x10, 2): "sh1add", (0x10, 4): "sh2add", (0x10, 6): "sh3add",
                  (0x05, 4): "min", (0x05, 5): "minu", (0x05, 6): "max", (0x05, 7): "maxu",
                  (0x30, 1): "rol", (0x30, 5): "ror", (0x24, 1): "bclr", (0x24, 5): "bext",
                  (0x34, 1): "binv", (0x14, 1): "bset", (0x07, 5): "czero.eqz",
                  (0x07, 7): "czero.nez"}.get((f7, f3))
            return (op, rd, rs1, rs2, 0) if op else None
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
        if self.vec_fault is not None:            # the table fetch faults (smclicshv, K-73)
            tbl, self.vec_fault = self.vec_fault, None
            self.take_trap(tbl, 1, tbl, inhv=1)
            return "trap", (1, tbl, tbl)
        try:
            insn, length = self.fetch()
            d = self.decode32(insn) if length == 4 else self.decode16(insn)
            if d is None:
                raise Trap(2, insn)
            rec = self.execute(pc, insn, length, d)
            return "retire", rec
        except Trap as t:
            tpc = pc if t.pc is None else t.pc
            self.take_trap(tpc, t.cause, t.tval, inhv=t.inhv)
            return "trap", (t.cause, tpc, t.tval)

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
        self.csr_side = {}
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
        elif op in ALU_OPS:
            writes = True
            wval = self.alu(op, a, b, rs1, rs2)
        elif op == "csr":
            wval, count = self.csr_op(insn, rd, rs1, rs2, imm)
            writes = True
        elif op == "mret":
            nxt = self.mepc
            self.mie, self.mpie = self.mpie, 1
            if self.clic_mode():
                self.mil = self.mc_pil                # mpil unchanged
                if self.mc_inhv:                      # refetch the table entry (K-74)
                    tbl = self.mepc & ~3 & M32
                    h = self.table_fetch(tbl)
                    if h is None:                     # MRET retires; the fetch fault follows
                        self.vec_fault = tbl
                        nxt = tbl
                    else:
                        nxt = h
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
        sx = sum(1 << k for k in self.csr_side)
        sv = [self.csr_side.get(k, 0) & M32 for k in range(4)]
        return (pc, insn, rd_out, rd_val, maddr, rmask, wmask, mdata, care, cw, caddr, cval, ccare,
                sx, sv[0], sv[1], sv[2], sv[3])

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
        if op in BITMANIP:
            return bitmanip(op, a, b)
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
        # reserved forms (draft: mnxti only csrr, csrrsi, csrrci with uimm bits 0, 2, 4 clear;
        # mscratchcswl only csrrw with rd and rs1 not x0)
        if addr == 0x345 and not ((f3 == 2 and rs1 == 0) or (f3 in (6, 7) and rs1 & 0b10101 == 0)):
            raise Trap(2, insn)
        if addr == 0x349 and not (f3 == 1 and rd != 0 and rs1 != 0):
            raise Trap(2, insn)
        src = rs1 if f3 >= 5 else self.x[rs1]       # zimm or rs1 value
        if addr == 0x345:                           # mnxti: read pointer, read-modify-write mstatus
            val, w = self.nxti()
            if write:
                self.mie = (self.mie | (src >> 3) & 1) if f3 == 6 else (self.mie & ~(src >> 3) & 1)
                self.csr_side[0] = self.csr_read(0x300)
                if w is not None:
                    self.mil, self.mc_code, self.mc_irq = w[1], w[0], 1
                    self.csr_side[2] = self.mcause_val()
                    self.csr_side[3] = self.mil << 24
                    self.clic.add_event(self.stamp_ex, ("claim", w[0]))
                self.csr_written = (addr, 0)
            return val, True
        if addr == 0x349:                           # mscratchcswl
            if src is None:
                raise Nondeterministic(f"unknown value written to CSR {addr:03x}")
            if self.cswl_swap():
                val, self.mscratch = self.mscratch, src
                self.csr_side[1] = src
            else:
                val = src
            self.csr_written = (addr, 0)
            return val, True
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


def eligible(m, c):
    """The model's interrupt request in cycle c: (id, level, shv) or None."""
    if not m.clic_mode() or m.mie != 1:
        return None
    m.clic.advance_to(c)
    w = m.clic.w
    if w is None or w[1] <= m.mil or w[1] <= m.mth:
        return None
    return w


def replay_run(ev_path, prefix):
    """Check one tb_core event log against the model. Returns (errors, summary)."""
    m = Machine(load_hex(prefix + ".itcm.hex"), load_hex(prefix + ".dtcm.hex"))
    lines = Path(ev_path).read_text().splitlines()
    if not lines or not lines[-1].startswith("E "):
        return [f"{ev_path}: incomplete event log (no E line)"], ""
    xl = [(int(f[1]), int(f[2], 16)) for f in (ln.split() for ln in lines) if f and f[0] == "X"]
    m.clic = Clic(xl)
    n_r = n_t = n_i = 0
    last_store_tohost = False
    elig_run = 0                              # consecutive retirement boundaries with an eligible interrupt
    last_ex = last_ret = -1                   # stamps of the previous retirement
    errs = []
    for k, ln in enumerate(lines[:-1], 1):
        f = ln.split()
        where = f"{ev_path}:{k}"
        if f[0] == "X":
            continue
        try:
            if f[0] == "I":
                code, epc, cyc = int(f[1]), int(f[2], 16), int(f[3])
                if m.mie != 1:
                    errs.append(f"{where}: interrupt taken while mstatus.MIE = 0 (pc {m.pc:08x})")
                if epc != m.pc:
                    errs.append(f"{where}: interrupt saved pc {epc:08x}, model next pc {m.pc:08x}")
                w = eligible(m, cyc)
                if w is None or w[0] != code:
                    errs.append(f"{where}: interrupt {code} taken in cycle {cyc}; the model's request is {w}"
                                f" (mode {'CLIC' if m.clic_mode() else 'CLINT'}, mil {m.mil:02x}, mintthresh {m.mth:02x})")
                    level, shv = 0, False
                else:
                    level, shv = w[1], w[2]
                m.clic.add_event(cyc, ("ack", code))
                m.take_interrupt(code, level, shv)
                n_i += 1
                elig_run = 0
                last_store_tohost = False
                continue
            if f[0] == "R":
                m.stamp_ex, m.stamp_ret = int(f[17]), int(f[18])
                # in-order pipeline: one instruction leaves EX per cycle and retires in a
                # later cycle, one retirement per cycle (a log with inconsistent stamps
                # would move CLIC stores, claims and inputs against each other unchecked)
                if not (last_ex < m.stamp_ex < m.stamp_ret and last_ret < m.stamp_ret):
                    errs.append(f"{where}: stamps ex {m.stamp_ex} retire {m.stamp_ret} inconsistent"
                                f" (previous ex {last_ex}, retire {last_ret})")
                    break
                last_ex, last_ret = m.stamp_ex, m.stamp_ret
            kind, r = m.step()
        except Nondeterministic as e:
            errs.append(f"{where}: {e}")
            break
        if f[0] == "T":
            n_t += 1
            got = (int(f[1]), int(f[2], 16), int(f[3], 16))
            if kind != "trap" or r != got:
                errs.append(f"{where}: exception {got[0]} pc {got[1]:08x} tval {got[2]:08x}; model {kind} {r if kind == 'trap' else '%08x' % r[0]}")
            last_store_tohost = False
            elig_run = 0
        elif f[0] == "R":
            n_r += 1
            pc, insn, rd, wd, ma = int(f[1], 16), int(f[2], 16), int(f[3]), int(f[4], 16), int(f[5], 16)
            rm, wm, md = int(f[6], 16), int(f[7], 16), int(f[8], 16)
            cw, ca, cd = int(f[9]), int(f[10], 16), int(f[11], 16)
            sx, sv = int(f[12], 16), [int(x, 16) for x in f[13:17]]
            if kind != "retire":
                errs.append(f"{where}: retirement pc {pc:08x}; model trap {r}")
            else:
                (e_pc, e_insn, e_rd, e_wd, e_ma, e_rm, e_wm, e_md, e_care, e_cw, e_ca, e_cd,
                 e_ccare, e_sx, *e_sv) = r
                lm = sum(0xFF << (8 * b) for b in range(4) if (rm | wm) >> b & 1)
                bad = (pc != e_pc or insn != e_insn or rd != e_rd or (wd & e_care) != (e_wd & e_care)
                       or rm != e_rm or wm != e_wm
                       or ((rm | wm) and (ma != e_ma or (md & lm & e_care) != (e_md & lm & e_care))))
                if not bad and (cw != e_cw or (e_cw and (ca != e_ca or (cd & e_ccare) != (e_cd & e_ccare)))):
                    bad = True
                if not bad and (sx != e_sx or any(sx >> j & 1 and sv[j] != e_sv[j] for j in range(4))):
                    bad = True
                if bad:
                    errs.append(f"{where}: retirement pc {pc:08x} insn {insn:08x} x{rd}={wd:08x} mem {ma:08x} r{rm:x} w{wm:x} {md:08x} csr {cw} {ca:03x}={cd:08x} side {sx:x} {' '.join('%08x' % v for v in sv)}; "
                                f"model pc {e_pc:08x} insn {e_insn:08x} x{e_rd}={e_wd:08x} mem {e_ma:08x} r{e_rm:x} w{e_wm:x} {e_md:08x} csr {e_cw} {e_ca:03x}={e_cd:08x} side {e_sx:x} {' '.join('%08x' % v for v in e_sv)}")
                last_store_tohost = bool(e_wm) and e_ma == TOHOST
            # missing take: an interrupt the model finds eligible at several consecutive
            # retirement boundaries without a take (the core takes it within two)
            try:
                w = eligible(m, m.stamp_ret)
            except Nondeterministic as e:
                errs.append(f"{where}: {e}")
                break
            elig_run = elig_run + 1 if w is not None else 0
            if elig_run >= MISSING_TAKE_BOUNDARIES:
                errs.append(f"{where}: interrupt {w[0]} (level {w[1]:02x}) eligible at {elig_run} retirement boundaries up to cycle {m.stamp_ret} and not taken")
                elig_run = -1000000
        else:
            errs.append(f"{where}: unknown event {f[0]}")
        if len(errs) >= 10:
            break
    totals = [int(x) for x in lines[-1].split()[1:4]]
    if not errs and totals != [n_r, n_t, n_i]:
        errs.append(f"{ev_path}: totals {totals} differ from the events ({n_r}, {n_t}, {n_i})")
    if not errs and not last_store_tohost:
        errs.append(f"{ev_path}: the log does not end with the tohost store")
    return errs, f"{n_r} retirements, {n_t} exceptions, {n_i} interrupts"


def replay(manifest):
    lines = Path(manifest).read_text().splitlines()
    runs = [ln.split() for ln in lines if ln.startswith("run ")]
    if not lines or not lines[-1].startswith("end ") or int(lines[-1].split()[1]) != len(runs):
        print(f"FAIL replay: {manifest} is incomplete (the bench did not finish)")
        return 1
    bad = 0
    tot = [0, 0, 0]
    for _, ev, name, mode, seed in runs:
        errs, summ = replay_run(ev, str(Path("tb/core/programs") / name))
        if errs:
            bad += 1
            print(f"FAIL replay {name} {mode} {seed}")
            for e in errs:
                print("  " + e)
        else:
            print(f"ok   replay {name} {mode} {seed}: {summ}")
            for k, v in enumerate(int(x) for x in summ.split()[::2]):
                tot[k] += v
    if bad:
        print(f"FAIL replay: {bad} of {len(runs)} runs differ from the model")
        return 1
    print(f"PASS replay: {len(runs)} runs, {tot[0]} retirements, {tot[1]} exceptions, "
          f"{tot[2]} interrupts matched the model")
    return 0


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--replay":
        sys.exit(replay(sys.argv[2]))
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
    lines = ["%08x %08x %02d %08x %08x %x %x %08x %08x %d %03x %08x %08x %x %08x %08x %08x %08x" % t for t in trace]
    Path(prefix + ".trace.ref").write_bytes(("\n".join(lines) + "\n").encode())
    tl = [str(len(traps))] + ["%d %08x %08x" % t for t in traps]
    Path(prefix + ".traps.ref").write_bytes(("\n".join(tl) + "\n").encode())
    print(f"{prefix}: {len(trace)} retired, {len(traps)} traps")


if __name__ == "__main__":
    main()
