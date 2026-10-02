#!/usr/bin/env python3
"""Compare a PX32 tb_compliance trace with a Spike commit log, event by event (step 1.9).

PX32 side (tb/compliance/tb_compliance.sv +trace), one line per event in program order:
  retirement: pc insn rd value csr_we csr_addr csr_value mem_addr rmask wmask wdata
              (hex; rd 0 = no register write; memory: byte address, byte lanes of the word,
              store data on its lanes)
  trap:       trap cause epc tval                             (hex)
The bench stops at the retirement of the first word store of a nonzero value to the halt
address (tohost), and that store is the last line.

Spike side (riscv-isa-sim at the D-026 commit, run with -l --log-commits):
  commit:     core   0: <priv> 0x<pc> (0x<insn>) [x<n> 0x<v>] [c<num>_<name> 0x<v>] [mem 0x<a> [0x<d>]]
  exception:  core   0: exception trap_<name>, epc 0x<pc>   (+ "core   0:           tval 0x<v>")
  also accepted and ignored: the -l disassembly line before each instruction
  ("core   0: 0x<pc> (0x<insn>) <text>") and symbol lines ("core   0: >>>>  <label>").
The Spike log is cut after the first commit that stores a nonzero 32-bit word to the halt
address (run_spike_wsl.sh already stops Spike there).

Compared per event, in order (DECISIONS.md D-026):
  retirement  pc, instruction bits, destination register and value, CSR write (address and
              the CSR value after the write), memory access (load: address and byte lanes;
              store: address, byte lanes and data)
  trap        cause, epc, tval
Fail closed: a missing or empty trace, any line either parser does not recognise, a
retirement/trap where the other side has the other kind, a length difference, a missing
halt store on either side (the first difference before the end of Spike's log is still
reported), an interrupt in the Spike log, or more than one register write in one Spike commit
is a failure. The first mismatch is reported with the preceding events of
both sides and Spike's disassembly of the instruction.

Masks (the only values not compared exactly; each is counted and reported, D-026):
  M1  rd value of a Zicsr instruction reading mcycle/mcycleh (0xB00/0xB80), and the value
      after a csrrs/csrrc(i) write of them (it combines the old count): PX32 counts clock
      cycles, which depend on memory timing; Spike counts one cycle per instruction. A
      csrrw(i) write of mcycle(h) is compared exactly.
      A value derived from a masked value (through registers, memory or a CSR) may differ
      too: a register, memory byte or CSR whose two values differ is "tainted", and a
      difference is accepted only where an operand is tainted. A tainted value reaching a
      load/store address, a branch/jump (the next pc differs) or a trap is a failure.
  M2  mtvec reset value: PX32 resets mtvec to its MTVEC_RESET parameter (0x1000_0040 on
      tb_compliance, D-022); Spike resets it to 0 and has no option to change that. Until
      the first write of mtvec, a read of mtvec must return exactly 0x1000_0040 on PX32 and 0
      on Spike; the destination register is then tainted. A trap taken before the first
      write vectors to different addresses and fails the comparison.
Reference logging differences (not masks: the values are still checked, see D-026):
  L1  MRET: Spike logs the mstatus (and on RV32 mstatush) it writes; PX32's retirement
      interface reports only Zicsr writes. The value is checked by the next mstatus read.
  L2  Spike does not log a write that leaves a read-only-zero CSR unchanged (the hpm
      counters 0xB03-0xB1F, 0xB83-0xB9F); PX32 reports the write with the resulting value.
      Accepted only for those addresses and only with the value 0.
Resynchronisation (D-026):
  R1  Spike with zero PMP entries does not implement the PMP CSRs (0x3A0-0x3EF: illegal
      instruction); PX32 implements them as read-only zero (D-022). Where PX32 retires a PMP
      CSR access (rd value 0, CSR value 0) and Spike traps on it with the same epc and tval,
      the comparison continues at Spike's trap target: PX32 may execute at most 8
      straight-line instructions (register operations and zero-valued PMP CSR accesses; no
      memory access, branch, jump or other CSR) and must then reach that pc. The destination
      registers of those instructions, and mstatus/mepc/mcause/mtval (written by Spike's trap
      entry only), are tainted until the next common trap or an equal value. This is the
      riscv-tests reset code (INIT_PMP), which catches that trap on purpose.
  R2  Spike always implements mcountinhibit (reads 0, writes ignored without Zicntr/Zihpm);
      PX32 does not (illegal instruction, D-022). Where PX32 traps on an mcountinhibit access
      (cause 2, tval = the instruction) that Spike retires with zero results, PX32's trap
      handler is skipped: PX32 must retire, without another trap and within 200 retirements,
      an instruction at the pc of Spike's next event. Everything the skipped handler wrote
      (registers, CSRs, memory bytes), the instruction's own rd on Spike, and
      mstatus/mepc/mcause/mtval are tainted. This is the riscv-arch-test 4.1.0 start-up code
      (csrw mcountinhibit, zero), which tolerates the trap on PX32 and on Sail.

Usage:
  python scripts/compliance/trace_compare.py --dut TRACE --ref SPIKE_LOG[.gz] --halt HEX
  python scripts/compliance/trace_compare.py --selftest
Exit status: 0 match, 1 mismatch or failure.
"""

import argparse
import re
import sys
from pathlib import Path

M32 = 0xFFFFFFFF
TIMING_CSRS = {0xB00, 0xB80}                         # mcycle, mcycleh (mask M1)
RESET_DIFF = {0x305: (0x10000040, 0x00000000)}       # mtvec reset: (PX32, Spike) (mask M2)
# L2: CSRs whose ignored writes Spike does not log (read-only zero on both sides)
RO_ZERO_UNLOGGED = set(range(0xB03, 0xB20)) | set(range(0xB83, 0xBA0))
MRET = 0x30200073
MCOUNTINHIBIT = 0x320
R2_MAX_SKIP = 200
PMP_CSRS = set(range(0x3A0, 0x3F0))                  # pmpcfg0-15, pmpaddr0-63
TRAP_CSRS = {0x300, 0x341, 0x342, 0x343}             # mstatus, mepc, mcause, mtval
R1_MAX_SKIP = 8
CAUSES = {
    "instruction_address_misaligned": 0, "instruction_access_fault": 1,
    "illegal_instruction": 2, "breakpoint": 3, "load_address_misaligned": 4,
    "load_access_fault": 5, "store_address_misaligned": 6, "store_access_fault": 7,
    "user_ecall": 8, "supervisor_ecall": 9, "virtual_supervisor_ecall": 10,
    "machine_ecall": 11, "instruction_page_fault": 12, "load_page_fault": 13,
    "store_page_fault": 15, "double_trap": 16, "software_check": 18,
    "instruction_guest_page_fault": 20, "load_guest_page_fault": 21,
    "virtual_instruction": 22, "store_guest_page_fault": 23,
}


class ParseError(Exception):
    pass


# ---------------------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------------------
def parse_dut(path):
    """tb_compliance trace -> list of events."""
    ev = []
    text = Path(path).read_text()
    for n, ln in enumerate(text.splitlines(), 1):
        f = ln.split()
        try:
            if len(f) == 4 and f[0] == "trap":
                ev.append({"k": "trap", "cause": int(f[1], 16), "epc": int(f[2], 16),
                           "tval": int(f[3], 16), "src": f"dut:{n}"})
            elif len(f) == 11:
                pc, insn, rd, val, we, ca, cv, ma, rm, wm, wd = f
                if we not in ("0", "1"):
                    raise ValueError
                rm, wm = int(rm, 16), int(wm, 16)
                if rm and wm:
                    raise ValueError
                ev.append({"k": "ret", "pc": int(pc, 16), "insn": int(insn, 16), "rd": int(rd),
                           "val": int(val, 16), "csr": (int(ca, 16), int(cv, 16)) if we == "1" else None,
                           "mem": (int(ma, 16), rm, wm, int(wd, 16)) if rm or wm else None,
                           "src": f"dut:{n}"})
            else:
                raise ValueError
        except ValueError:
            raise ParseError(f"{path}:{n}: unparsed PX32 trace line: {ln!r}")
    return ev


RE_COMMIT = re.compile(r"^core\s+\d+: (\d) 0x([0-9a-f]+) \(0x([0-9a-f]+)\)(.*)$")
RE_DISASM = re.compile(r"^core\s+\d+: 0x([0-9a-f]+) \(0x([0-9a-f]+)\) (.*)$")
RE_EXC = re.compile(r"^core\s+\d+: (exception|interrupt) (\S+), epc 0x([0-9a-f]+)$")
RE_TVAL = re.compile(r"^core\s+\d+:\s+tval 0x([0-9a-f]+)$")
RE_LABEL = re.compile(r"^core\s+\d+: >>>>  ")


def parse_spike(path, halt):
    """Spike -l --log-commits log -> (events, halted, disassembly by pc)."""
    ev, dis = [], {}
    halted = False
    if str(path).endswith(".gz"):
        import gzip
        text = gzip.open(path, "rt", errors="replace").read()
    else:
        text = Path(path).read_text(errors="replace")
    for n, ln in enumerate(text.splitlines(), 1):
        if RE_LABEL.match(ln):
            continue
        m = RE_COMMIT.match(ln)
        if m:
            priv, pc, insn, rest = m.groups()
            if priv != "3":
                raise ParseError(f"{path}:{n}: commit in privilege {priv}: {ln!r}")
            e = {"k": "ret", "pc": int(pc, 16), "insn": int(insn, 16), "rd": 0, "val": 0,
                 "csrs": [], "mem": None, "src": f"spike:{n}"}
            toks = rest.split()
            i = 0
            while i < len(toks):
                t = toks[i]
                if re.fullmatch(r"x\d+", t) and i + 1 < len(toks):
                    if e["rd"]:
                        raise ParseError(f"{path}:{n}: two register writes in one commit: {ln!r}")
                    e["rd"], e["val"] = int(t[1:]), int(toks[i + 1], 16)
                    i += 2
                elif re.fullmatch(r"c\d+_\w+", t) and i + 1 < len(toks):
                    e["csrs"].append((int(t[1:].split("_")[0]), int(toks[i + 1], 16) & M32))
                    i += 2
                elif t == "mem" and i + 1 < len(toks):
                    a = int(toks[i + 1], 16)
                    if i + 2 < len(toks) and toks[i + 2].startswith("0x"):
                        d = toks[i + 2]
                        e["mem"] = ("w", a, int(d, 16), (len(d) - 2) // 2)
                        i += 3
                    else:
                        e["mem"] = ("r", a, None, None)
                        i += 2
                else:
                    raise ParseError(f"{path}:{n}: unparsed Spike commit field {t!r}: {ln!r}")
            ev.append(e)
            mm = e["mem"]
            if mm and mm[0] == "w" and mm[1] == halt and mm[3] == 4 and mm[2] != 0:
                halted = True
                break
            continue
        m = RE_DISASM.match(ln)
        if m:
            dis[int(m.group(1), 16)] = m.group(3).strip()
            continue
        m = RE_EXC.match(ln)
        if m:
            kind, name, epc = m.groups()
            name = name[5:] if name.startswith("trap_") else name
            if kind == "interrupt" or name not in CAUSES:
                raise ParseError(f"{path}:{n}: unexpected {kind} {name} in the Spike log")
            ev.append({"k": "trap", "cause": CAUSES[name], "epc": int(epc, 16), "tval": 0,
                       "src": f"spike:{n}"})
            continue
        m = RE_TVAL.match(ln)
        if m and ev and ev[-1]["k"] == "trap":
            ev[-1]["tval"] = int(m.group(1), 16) & M32
            continue
        raise ParseError(f"{path}:{n}: unparsed Spike log line: {ln!r}")
    return ev, halted, dis


# ---------------------------------------------------------------------------------------
# Instruction operand decode (RV32IMC + Zicsr), for taint propagation only
# ---------------------------------------------------------------------------------------
def operands(insn):
    """(source registers, memory access kind 'load'/'store'/None, access bytes, is_zicsr, csr)."""
    if insn & 3 != 3:                                  # compressed
        q, f3 = insn & 3, (insn >> 13) & 7
        r1, r2 = (insn >> 7) & 0x1F, (insn >> 2) & 0x1F
        p1, p2 = ((insn >> 7) & 7) + 8, ((insn >> 2) & 7) + 8
        if q == 0:
            return {0: ({2}, None), 2: ({p1}, "load"), 6: ({p1, p2}, "store")}.get(f3, (set(), None)) + (4, False, None)
        if q == 1:
            if f3 == 0:
                return {r1}, None, 0, False, None
            if f3 == 3:
                return ({2} if r1 == 2 else set()), None, 0, False, None
            if f3 == 4:
                if (insn >> 10) & 3 == 3:
                    return {p1, p2}, None, 0, False, None
                return {p1}, None, 0, False, None
            if f3 in (6, 7):
                return {p1}, None, 0, False, None
            return set(), None, 0, False, None
        if f3 == 0:
            return {r1}, None, 0, False, None
        if f3 == 2:
            return {2}, "load", 4, False, None
        if f3 == 4:
            if r2 == 0:
                return {r1}, None, 0, False, None          # C.JR / C.JALR / C.EBREAK
            return ({r2} if not (insn >> 12) & 1 else {r1, r2}), None, 0, False, None
        if f3 == 6:
            return {2, r2}, "store", 4, False, None
        return set(), None, 0, False, None
    op, f3 = insn & 0x7F, (insn >> 12) & 7
    rs1, rs2 = (insn >> 15) & 0x1F, (insn >> 20) & 0x1F
    if op == 0x67:
        return {rs1}, None, 0, False, None
    if op in (0x63, 0x33):
        return {rs1, rs2}, None, 0, False, None
    if op == 0x03:
        return {rs1}, "load", 1 << (f3 & 3), False, None
    if op == 0x23:
        return {rs1, rs2}, "store", 1 << (f3 & 3), False, None
    if op == 0x13:
        return {rs1}, None, 0, False, None
    if op == 0x73 and f3 not in (0, 4):
        return ({rs1} if f3 < 4 else set()), None, 0, True, insn >> 20
    return set(), None, 0, False, None


# ---------------------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------------------
def fmt(e, dis=None):
    if e is None:
        return "(none: trace ended)"
    if e["k"] == "trap":
        return f"trap cause {e['cause']} epc {e['epc']:08x} tval {e['tval']:08x}  [{e['src']}]"
    s = f"pc {e['pc']:08x} insn {e['insn']:08x}"
    s += f" x{e['rd']}={e['val']:08x}" if e["rd"] else " (no rd)"
    if "csrs" in e:
        s += "".join(f" csr {a:03x}={v:08x}" for a, v in e["csrs"])
    elif e["csr"]:
        s += f" csr {e['csr'][0]:03x}={e['csr'][1]:08x}"
    if dis and e["pc"] in dis:
        s += f"  ({dis[e['pc']]})"
    return s + f"  [{e['src']}]"


def compare(dut, ref, dis=None, context=6):
    """Returns (ok, message, stats). i walks the PX32 events, j Spike's (they differ only
    after an R1 resynchronisation)."""
    dis = dis or {}
    xt = [False] * 32                               # tainted registers
    mt = set()                                      # tainted memory bytes
    ct = set(TIMING_CSRS) | set(RESET_DIFF)         # tainted CSRs (mcycle/mcycleh always)
    reset = dict(RESET_DIFF)                        # CSRs not yet written since reset (M2)
    st = {"retirements": 0, "traps": 0, "M1": 0, "M2": 0, "taint": 0, "L1": 0, "L2": 0, "R1": 0, "R2": 0, "notes": []}

    def fail(i, j, why):
        lines = [f"MISMATCH at px32 event {i}, spike event {j}: {why}"]
        for a, b in zip(range(max(0, i - context), i), range(max(0, j - context), j)):
            lines.append(f"   {a:7d}  px32  {fmt(dut[a])}")
            lines.append(f"   {b:7d}  spike {fmt(ref[b], dis)}")
        lines.append(f"-> {i:7d}  px32  {fmt(dut[i] if i < len(dut) else None)}")
        lines.append(f"-> {j:7d}  spike {fmt(ref[j] if j < len(ref) else None, dis)}")
        return False, "\n".join(lines), st

    i = j = 0
    while i < len(dut) or j < len(ref):
        if i >= len(dut) or j >= len(ref):
            return fail(i, j, f"length differs: px32 {len(dut)} events, spike {len(ref)}")
        d, r = dut[i], ref[j]
        if d["k"] == "ret" and r["k"] == "trap" and r1_applies(d, r):
            # R1: Spike has no PMP CSRs with zero PMP entries; PX32 implements them as
            # read-only zero (D-022). Resynchronise at Spike's trap target.
            if j + 1 >= len(ref) or ref[j + 1]["k"] != "ret":
                return fail(i, j, "R1: no Spike retirement after the PMP CSR trap")
            target, k = ref[j + 1]["pc"], i + 1
            while k < len(dut) and k - i <= R1_MAX_SKIP and not (dut[k]["k"] == "ret" and dut[k]["pc"] == target):
                if dut[k]["k"] != "ret" or not r1_skippable(dut[k]):
                    return fail(k, j + 1, "R1: px32 does something other than straight-line code "
                                          "before the Spike trap target")
                k += 1
            if k >= len(dut) or dut[k]["k"] != "ret" or dut[k]["pc"] != target:
                return fail(i, j, f"R1: px32 does not reach the Spike trap target {target:08x}")
            st["R1"] += 1
            ct.update(TRAP_CSRS)                    # Spike's trap entry wrote them, PX32's did not
            for e in dut[i + 1:k]:
                if e["rd"]:
                    xt[e["rd"]] = True              # values Spike never computed
            i, j = k, j + 1
            continue
        if d["k"] == "trap" and r["k"] == "ret" and r2_applies(d, r):
            # R2: Spike implements mcountinhibit; PX32 does not (illegal, D-022). Skip PX32's
            # handler for that trap and resynchronise at Spike's next pc.
            if j + 1 >= len(ref) or ref[j + 1]["k"] != "ret":
                return fail(i, j, "R2: no Spike retirement after the mcountinhibit access")
            target, k = ref[j + 1]["pc"], i + 1
            while k < len(dut) and dut[k]["k"] == "ret" and dut[k]["pc"] != target and k - i <= R2_MAX_SKIP:
                k += 1
            if k >= len(dut) or dut[k]["k"] != "ret" or dut[k]["pc"] != target:
                return fail(i, j, f"R2: px32 does not return to {target:08x} within {R2_MAX_SKIP} "
                                  "retirements without another trap")
            st["R2"] += 1
            ct.update(TRAP_CSRS)                    # PX32's trap entry wrote them, Spike's did not
            if r["rd"]:
                xt[r["rd"]] = True
            for e in dut[i + 1:k]:                  # everything PX32's handler wrote is tainted
                if e["rd"]:
                    xt[e["rd"]] = True
                if e["csr"]:
                    ct.add(e["csr"][0])
                if e["mem"] and e["mem"][2]:
                    mt.update(e["mem"][0] - (e["mem"][0] & 3) + b for b in range(4) if e["mem"][2] >> b & 1)
            i, j = k, j + 1
            continue
        if d["k"] != r["k"]:
            return fail(i, j, f"px32 has a {'trap' if d['k'] == 'trap' else 'retirement'}, "
                              f"spike a {'trap' if r['k'] == 'trap' else 'retirement'}")
        if d["k"] == "trap":
            st["traps"] += 1
            for f in ("cause", "epc", "tval"):
                if d[f] != r[f]:
                    return fail(i, j, f"trap {f}: px32 {d[f]:x}, spike {r[f]:x}")
            ct.difference_update(TRAP_CSRS)         # the same trap entry rewrote them on both
            i, j = i + 1, j + 1
            continue
        st["retirements"] += 1
        if d["pc"] != r["pc"]:
            return fail(i, j, "pc differs")
        if d["insn"] != r["insn"]:
            return fail(i, j, "instruction bits differ")
        srcs, acc, nbytes, zicsr, csr = operands(r["insn"])
        tainted_src = any(xt[s] for s in srcs if s)
        if acc and xt[_base(r["insn"])]:
            return fail(i, j, "a tainted (masked) value reached a memory address")
        load_taint = False
        why = mem_differs(d, r, acc, nbytes, xt)
        if why:
            return fail(i, j, why)
        if acc and r["mem"]:
            a = r["mem"][1]
            span = range(a, a + nbytes)
            if acc == "load":
                load_taint = any(b in mt for b in span)
            else:
                data_reg = _store_data_reg(r["insn"])
                for b in span:
                    (mt.add if xt[data_reg] else mt.discard)(b)
        # destination register
        if d["rd"] != r["rd"]:
            return fail(i, j, f"destination register: px32 x{d['rd']}, spike x{r['rd']}")
        if d["rd"]:
            if d["val"] != r["val"]:
                if zicsr and csr in TIMING_CSRS:
                    st["M1"] += 1
                    st["notes"].append((i, j, "M1 (mcycle read)", d["pc"], dis.get(d["pc"], "")))
                elif zicsr and csr in reset:
                    if (d["val"], r["val"]) != reset[csr]:
                        return fail(i, j, f"x{d['rd']} value (reset value of CSR {csr:03x}): "
                                          f"px32 {d['val']:08x}, spike {r['val']:08x}")
                    st["M2"] += 1
                    st["notes"].append((i, j, "M2 (mtvec reset value)", d["pc"], dis.get(d["pc"], "")))
                elif tainted_src or load_taint or (zicsr and csr in ct):
                    st["taint"] += 1
                    st["notes"].append((i, j, "taint (rd value)", d["pc"], dis.get(d["pc"], "")))
                else:
                    return fail(i, j, f"x{d['rd']} value: px32 {d['val']:08x}, spike {r['val']:08x}")
            xt[d["rd"]] = d["val"] != r["val"]
        # CSR write
        dcsr = d["csr"]
        rcsr = r["csrs"][0] if r["csrs"] else None
        if not zicsr:
            if dcsr:
                return fail(i, j, "px32 reports a CSR write for a non-Zicsr instruction")
            if r["csrs"]:
                if r["insn"] == MRET and {a for a, _ in r["csrs"]} <= {0x300, 0x310}:
                    st["L1"] += 1
                else:
                    return fail(i, j, "spike logs a CSR write for a non-Zicsr instruction")
        elif len(r["csrs"]) > 1:
            return fail(i, j, "spike logs more than one CSR write")
        elif dcsr and not rcsr:
            if not (dcsr[0] in RO_ZERO_UNLOGGED and dcsr[1] == 0 and dcsr[0] == csr):
                return fail(i, j, f"px32 writes CSR {dcsr[0]:03x}, spike logs no write")
            st["L2"] += 1
        elif rcsr and not dcsr:
            return fail(i, j, f"spike writes CSR {rcsr[0]:03x}, px32 reports no write")
        elif dcsr:
            if dcsr[0] != rcsr[0]:
                return fail(i, j, f"CSR address: px32 {dcsr[0]:03x}, spike {rcsr[0]:03x}")
            if dcsr[1] != rcsr[1]:
                if tainted_src or dcsr[0] in ct:
                    st["taint"] += 1
                    st["notes"].append((i, j, "taint (CSR value)", d["pc"], dis.get(d["pc"], "")))
                else:
                    return fail(i, j, f"CSR {dcsr[0]:03x} value: px32 {dcsr[1]:08x}, spike {rcsr[1]:08x}")
            if dcsr[0] not in TIMING_CSRS:
                (ct.add if dcsr[1] != rcsr[1] else ct.discard)(dcsr[0])
            reset.pop(dcsr[0], None)
        i, j = i + 1, j + 1
    return True, (f"MATCH {st['retirements']} retirements, {st['traps']} traps; "
                  f"masked M1 {st['M1']}, M2 {st['M2']}, tainted {st['taint']}; logging L1 {st['L1']}, L2 {st['L2']}; "
                  f"R1 {st['R1']}, R2 {st['R2']}") + "".join(
        f"\n  accepted at px32 event {a}, spike event {b}: {k}, pc {pc:08x} ({t})"
        for a, b, k, pc, t in st["notes"]), st


def mem_differs(d, r, acc, nbytes, xt):
    """Compare the memory access of one retirement: PX32 (byte address, byte lanes, store data
    on its lanes) against Spike (address; store data with its width). None if equal."""
    dm, rm = d["mem"], r["mem"]
    if not acc:
        return "memory access on a non-load/store instruction" if (dm or rm) else None
    if not rm:
        return None if not dm else "px32 accesses memory, spike logs no access"
    if not dm:
        return "spike accesses memory, px32 reports no access"
    a = rm[1]
    lanes = ((1 << nbytes) - 1) << (a & 3)
    if dm[0] != a:
        return f"memory address: px32 {dm[0]:08x}, spike {a:08x}"
    if rm[0] == "r":
        return None if (dm[1], dm[2]) == (lanes, 0) else f"load lanes: px32 {dm[1]:x}, expected {lanes:x}"
    if (dm[1], dm[2]) != (0, lanes) or rm[3] != nbytes:
        return f"store lanes: px32 {dm[2]:x}, expected {lanes:x} (spike width {rm[3]})"
    m = (1 << (8 * nbytes)) - 1
    got = (dm[3] >> (8 * (a & 3))) & m
    if got != rm[2] and not xt[_store_data_reg(r["insn"])]:
        return f"store data: px32 {got:0{2 * nbytes}x}, spike {rm[2]:0{2 * nbytes}x}"
    return None


def r2_applies(d, r):
    """PX32 traps (illegal instruction) on an mcountinhibit access that Spike executes with
    zero results (R2)."""
    _, _, _, zicsr, csr = operands(r["insn"])
    return (zicsr and csr == MCOUNTINHIBIT and d["cause"] == 2 and d["epc"] == r["pc"]
            and d["tval"] == r["insn"] and (not r["rd"] or r["val"] == 0)
            and all(v == 0 for _, v in r["csrs"]) and {a for a, _ in r["csrs"]} <= {MCOUNTINHIBIT})


def r1_applies(d, r):
    """PX32 retires a PMP CSR access with zero results where Spike traps on it (R1)."""
    _, _, _, zicsr, csr = operands(d["insn"])
    return (zicsr and csr in PMP_CSRS and r["cause"] == 2 and r["epc"] == d["pc"]
            and r["tval"] == d["insn"] and d["val"] == 0
            and (d["csr"] is None or (d["csr"][0] == csr and d["csr"][1] == 0)))


def r1_skippable(e):
    """What PX32 may execute between an R1 access and Spike's trap target: straight-line
    register instructions or PMP CSR accesses (no memory access, control transfer or other
    CSR)."""
    insn = e["insn"]
    _, acc, _, zicsr, csr = operands(insn)
    if acc:
        return False
    if zicsr:
        return csr in PMP_CSRS and (e["csr"] is None or e["csr"][1] == 0) and e["val"] == 0
    if insn & 3 != 3:
        q, f3 = insn & 3, (insn >> 13) & 7
        # C.ADDI/NOP, C.LI, C.LUI/C.ADDI16SP, C.ALU group, C.SLLI, C.MV/C.ADD (not C.JR/JALR/EBREAK)
        return (q, f3) in {(1, 0), (1, 2), (1, 3), (1, 4), (2, 0)} or ((q, f3) == (2, 4) and (insn >> 2) & 0x1F != 0)
    return insn & 0x7F in (0x13, 0x33, 0x37, 0x17)


def _base(insn):
    """Address base register of a load/store."""
    if insn & 3 != 3:
        q, f3 = insn & 3, (insn >> 13) & 7
        return 2 if q == 2 else ((insn >> 7) & 7) + 8
    return (insn >> 15) & 0x1F


def _store_data_reg(insn):
    if insn & 3 != 3:
        return (insn >> 2) & 0x1F if insn & 3 == 2 else ((insn >> 2) & 7) + 8
    return (insn >> 20) & 0x1F


def run(dut_path, ref_path, halt, context=6):
    """Returns (ok, message, stats)."""
    for p in (dut_path, ref_path):
        if not Path(p).is_file() or Path(p).stat().st_size == 0:
            return False, f"FAIL missing or empty trace {p}", {}
    try:
        dut = parse_dut(dut_path)
        ref, halted, dis = parse_spike(ref_path, halt)
    except ParseError as e:
        return False, f"FAIL {e}", {}
    if not dut or not (dut[-1]["k"] == "ret"):
        return False, "FAIL px32 trace does not end with a retirement (no halt store)", {}
    if not halted:
        # still report where the two differ first, if they do before Spike's log ends
        ok, msg, st = compare(dut, ref, dis, context)
        if not ok and "length differs" not in msg.splitlines()[0]:
            return False, msg + f"\n(spike log has no halt store at {halt:08x})", st
        return False, f"FAIL spike log has no word store of a nonzero value to the halt address {halt:08x}", {}
    return compare(dut, ref, dis, context)


# ---------------------------------------------------------------------------------------
# Selftest: fixtures with known outcomes (fail closed on every malformed case)
# ---------------------------------------------------------------------------------------
_SPIKE = """core   0: >>>>  _start
core   0: 0x10000000 (0x00000297) auipc   t0, 0x0
core   0: 3 0x10000000 (0x00000297) x5  0x10000000
core   0: 3 0x10000004 (0x34029073) c832_mscratch 0x10000000
core   0: exception trap_illegal_instruction, epc 0x10000008
core   0:           tval 0x00000000
core   0: 3 0x10000040 (0x4501) x10 0x00000000
core   0: 3 0x10000042 (0xb0002373) x6  0x00000123
core   0: 3 0x10000046 (0x006303b3) x7  0x00000246
core   0: 3 0x1000004a (0x00b2a023) mem 0x10001000 0x00000001
core   0: 3 0x1000004e (0x0000006f)
"""
_DUT = """10000000 00000297 5 10000000 0 000 00000000
10000004 34029073 0 00000000 1 340 10000000
trap 2 10000008 00000000
10000040 00004501 10 00000000 0 000 00000000
10000042 b0002373 6 00000123 0 000 00000000
10000046 006303b3 7 00000246 0 000 00000000
1000004a 00b2a023 0 00000000 0 000 00000000 10001000 0 f 00000001
"""
_HALT = 0x10001000


def _fixtures():
    sp, du = _SPIKE, _DUT
    mtv_d = "1000003c 30502473 8 {} 0 000 00000000\n".format    # csrr s0, mtvec (PX32 value)
    mtv_s = "core   0: 3 0x1000003c (0x30502473) x8  0x00000000"
    r2_d = ("trap 2 10000034 32001073\n"                    # csrw mcountinhibit, zero: PX32 traps
            "10000080 00000013 0 00000000 0 000 00000000\n"  # its handler (skipped, tainted)
            "10000084 00532023 0 00000000 0 000 00000000 10000000 0 f 10000000\n"
            "10000088 00000013 0 00000000 0 000 00000000\n"
            "10000038 00000013 0 00000000 0 000 00000000\n")
    r2_s = ("core   0: 3 0x10000034 (0x32001073) c800_mcountinhibit 0x00000000\n"
            "core   0: 3 0x10000038 (0x00000013)")
    mret_d = "10000030 30200073 0 00000000 0 000 00000000"
    mret_s = "core   0: 3 0x10000030 (0x30200073) c768_mstatus 0x00001880 c784_mstatush 0x00000000"
    pmp_d = ("10000044 3b029073 0 00000000 1 3b0 00000000\n"
             "10000048 00a00493 9 0000000a 0 000 00000000\n"
             "1000004c 00000013 0 00000000 0 000 00000000")
    pmp_s = ("core   0: exception trap_illegal_instruction, epc 0x10000044\n"
             "core   0:           tval 0x3b029073\n"
             "core   0: 3 0x1000004c (0x00000013)")
    taint_addr_s = sp.replace("(0x006303b3) x7  0x00000246", "(0x006303b3) x5  0x00000246")
    taint_addr_d = du.replace("006303b3 7 00000246", "006303b3 5 00000247").replace(
        "b0002373 6 00000123", "b0002373 6 00000124")
    return {
        # name: (dut text, spike text, True (match) or the expected failure reason)
        "identical": (du, sp, True),
        "mcycle_masked": (du.replace("6 00000123", "6 00000456").replace("7 00000246", "7 000008ac"), sp, True),
        "single_bit_value": (du.replace("5 10000000", "5 10000001"), sp, 'x5 value'),
        "missing_retirement": (du.replace("10000040 00004501 10 00000000 0 000 00000000\n", ""), sp, 'pc differs'),
        "extra_trap": (du.replace("trap 2 10000008 00000000\n", "trap 2 10000008 00000000\ntrap 2 10000040 00004501\n"), sp, 'px32 has a trap'),
        "csr_value": (du.replace("1 340 10000000", "1 340 10000004"), sp, 'CSR 340 value'),
        "csr_missing": (du.replace("1 340 10000000", "0 000 00000000"), sp, 'spike writes CSR 340'),
        "trap_tval": (du.replace("trap 2 10000008 00000000", "trap 2 10000008 00000001"), sp, 'trap tval'),
        "taint_to_address": (taint_addr_d, taint_addr_s, 'reached a memory address'),
        "spike_unparsed_line": (du, sp.replace("core   0: 3 0x10000040", "garbage\ncore   0: 3 0x10000040"), 'unparsed Spike log line'),
        "spike_no_halt": (du, sp.split("core   0: 3 0x1000004a")[0], 'no word store'),
        "spike_halt_other_address": (du, sp.replace("mem 0x10001000 0x00000001", "mem 0x10001004 0x00000001"),
                                     'memory address: px32 10001000, spike 10001004'),
        "spike_halt_zero": (du, sp.replace("mem 0x10001000 0x00000001", "mem 0x10001000 0x00000000"), 'store data'),
        "store_lanes": (du.replace("10001000 0 f 00000001", "10001000 0 3 00000001"), sp, 'store lanes'),
        "load_address": (du.replace("10000040 00004501", "1000003e 00042403 8 00000000 0 000 00000000 10001004 f 0 00000000\n10000040 00004501"),
                         sp.replace("core   0: 3 0x10000040 (0x4501)", "core   0: 3 0x1000003e (0x00042403) x8  0x00000000 mem 0x10001000\ncore   0: 3 0x10000040 (0x4501)"),
                         'memory address: px32 10001004, spike 10001000'),
        "r2_mcountinhibit_resync": (du.replace("10000040 00004501", r2_d + "10000040 00004501"),
                                    sp.replace("core   0: 3 0x10000040 (0x4501)", r2_s + "\ncore   0: 3 0x10000040 (0x4501)"), True),
        "r2_nested_trap": (du.replace("10000040 00004501", r2_d.replace("10000084 00532023", "trap 2 10000084 00000000\n10000084 00532023") + "10000040 00004501"),
                           sp.replace("core   0: 3 0x10000040 (0x4501)", r2_s + "\ncore   0: 3 0x10000040 (0x4501)"), 'R2: px32 does not return'),
        "r2_spike_nonzero": (du.replace("10000040 00004501", r2_d + "10000040 00004501"),
                             sp.replace("core   0: 3 0x10000040 (0x4501)", r2_s.replace("mcountinhibit 0x00000000", "mcountinhibit 0x00000004")
                                        + "\ncore   0: 3 0x10000040 (0x4501)"), 'px32 has a trap, spike a retirement'),
        "px32_unparsed_line": (du.replace("trap 2", "trap two"), sp, 'unparsed PX32 trace line'),
        "px32_empty": ("", sp, 'missing or empty'),
        "spike_interrupt": (du, sp.replace("exception trap_illegal_instruction", "interrupt interrupt_m_timer"), 'unexpected interrupt'),
        "extra_spike_events": (du.replace("1000004a 00b2a023 0 00000000 0 000 00000000 10001000 0 f 00000001\n", ""), sp, 'length differs'),
        "mtvec_reset_read": (du.replace("10000040 00004501", mtv_d("10000040") + "10000040 00004501"),
                             sp.replace("core   0: 3 0x10000040 (0x4501)", mtv_s + "\ncore   0: 3 0x10000040 (0x4501)"), True),
        "mtvec_reset_wrong": (du.replace("10000040 00004501", mtv_d("10000044") + "10000040 00004501"),
                              sp.replace("core   0: 3 0x10000040 (0x4501)", mtv_s + "\ncore   0: 3 0x10000040 (0x4501)"), 'reset value of CSR 305'),
        "mtvec_after_write": (du.replace("10000040 00004501", "10000038 30529073 0 00000000 1 305 10000000\n"
                                         + mtv_d("10000040") + "10000040 00004501"),
                              sp.replace("core   0: 3 0x10000040 (0x4501)", "core   0: 3 0x10000038 (0x30529073) "
                                         "c773_mtvec 0x10000000\n" + mtv_s.replace("x8  0x00000000", "x8  0x10000000")
                                         + "\ncore   0: 3 0x10000040 (0x4501)"), 'x8 value'),
        "mret_mstatus_logged": (du.replace("10000040 00004501", mret_d + "\n10000040 00004501"),
                                sp.replace("core   0: 3 0x10000040 (0x4501)", mret_s + "\ncore   0: 3 0x10000040 (0x4501)"), True),
        "mret_other_csr": (du.replace("10000040 00004501", mret_d + "\n10000040 00004501"),
                           sp.replace("core   0: 3 0x10000040 (0x4501)",
                                      mret_s.replace("c768_mstatus", "c833_mepc") + "\ncore   0: 3 0x10000040 (0x4501)"), 'non-Zicsr'),
        "r1_pmp_resync": (du.replace("10000040 00004501", pmp_d + "\n10000040 00004501"),
                          sp.replace("core   0: 3 0x10000040 (0x4501)", pmp_s + "\ncore   0: 3 0x10000040 (0x4501)"), True),
        "r1_pmp_nonzero": (du.replace("10000040 00004501", pmp_d.replace("1 3b0 00000000", "1 3b0 00000001") + "\n10000040 00004501"),
                           sp.replace("core   0: 3 0x10000040 (0x4501)", pmp_s + "\ncore   0: 3 0x10000040 (0x4501)"), 'px32 has a retirement, spike a trap'),
        "r1_pmp_store_skipped": (du.replace("10000040 00004501", pmp_d.replace("10000048 00a00493 9 0000000a", "10000048 00532023 0 00000000") + "\n10000040 00004501"),
                                 sp.replace("core   0: 3 0x10000040 (0x4501)", pmp_s + "\ncore   0: 3 0x10000040 (0x4501)"), 'R1: px32 does something other'),
        "r1_pmp_no_target": (du.replace("10000040 00004501", pmp_d.replace("1000004c", "1000004e") + "\n10000040 00004501"),
                             sp.replace("core   0: 3 0x10000040 (0x4501)", pmp_s + "\ncore   0: 3 0x10000040 (0x4501)"), 'R1:'),
    }


def _ext(text):
    """Fixture shorthand: a 7-field retirement line has no memory access."""
    return "".join(ln + (" 00000000 0 0 00000000" if len(ln.split()) == 7 else "") + "\n"
                   for ln in text.splitlines())


def selftest():
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as td:
        for name, (d, s, want) in _fixtures().items():
            dp, sp = Path(td) / f"{name}.dut", Path(td) / f"{name}.spike"
            dp.write_text(_ext(d))
            sp.write_text(s)
            got, msg, _ = run(dp, sp, _HALT, context=2)
            # a failure must fail for the stated reason, not for a malformed fixture
            good = got if want is True else (not got and want in msg)
            ok &= good
            print(f"  selftest {name:<22} expected {'match' if want is True else 'fail':<5} got "
                  f"{'match' if got else 'fail':<5} {'ok' if good else 'WRONG'}  {msg.splitlines()[0]}")
    print("PASS trace_compare selftest" if ok else "FAIL trace_compare selftest")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dut")
    ap.add_argument("--ref")
    ap.add_argument("--halt", type=lambda x: int(x, 16))
    ap.add_argument("--context", type=int, default=6)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return 0 if selftest() else 1
    if not (a.dut and a.ref and a.halt is not None):
        ap.error("--dut, --ref and --halt are required")
    ok, msg, _ = run(a.dut, a.ref, a.halt, a.context)
    print(msg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
