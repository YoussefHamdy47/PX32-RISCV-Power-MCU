#!/usr/bin/env python3
"""Generate the PX32 ACT4 DUT configuration (riscv-arch-test 4.1.0) from a template.

The UDB and Sail configurations are long schema-checked files; they are derived here from the
upstream CVA6 cv32a65x configuration (RV32, Direct-only mtvec, misaligned accesses trap, no
PMP) at the pinned suite commit, with every PX32-specific change listed explicitly below.
Each edit must apply exactly once, otherwise the script stops (fail closed), so an upstream
template change cannot silently produce a wrong PX32 configuration.

PX32 facts encoded (D-022, D-023, contract section 1):
  I 2.1, M 2.0 (Zmmul), C 2.0 (Zca), Zicsr 2.0, Zifencei 2.0, Sm (priv. 20240411 = 1.13.0)
  misa fixed (0x4000_1104); mtvec Direct only, BASE 4-byte aligned, MODE writes ignored
  mvendorid/marchid/mimpid 0 (not implemented); mhartid 0; mconfigptr 0
  misaligned halfword/word accesses raise the misaligned exceptions (no hardware support)
  mtval: faulting address for access/misaligned faults, pc for EBREAK, instruction bits for
  illegal instructions; unimplemented CSRs trap; mcause WLRL writes do not trap
  no Zicntr, no Zihpm (hpm counters read-only 0), no mcountinhibit, no U/S mode,
  zero PMP entries, no interrupt sources before Phase 2 (no CLINT, no interrupt generator)
  memory: one RWX region at 0x1000_0000 (1 MB in tb_compliance), halt word at its top

NOT VALIDATED: until the ACT4 framework (make + UDB + Sail) runs, these files have only been
generated, not checked against the UDB schema or Sail's config schema.

Usage: python scripts/compliance/make_act4_config.py [--suite DIR]
       writes sw/compliance/act4/px32/{px32.yaml,sail.json,test_config.yaml,link.ld,
       rvmodel_macros.h}
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "sw/compliance/act4/px32"
SUITE_COMMIT = "6e8a45123f14cebfb3df151a0e7b849b4389b33b"      # riscv-arch-test 4.1.0
RAM_BASE, RAM_SIZE = 0x10000000, 0x100000
HALT = RAM_BASE + RAM_SIZE - 0x10                           # tohost-style halt word
CONSOLE = RAM_BASE + RAM_SIZE - 0x08                        # byte-wide console


def edit(text, old, new, count=1, what=""):
    n = text.count(old)
    if n != count:
        sys.exit(f"template edit '{what or old[:60]}' found {n} times (expected {count})")
    return text.replace(old, new)


def sub(text, pattern, new, what):
    t, n = re.subn(pattern, new, text, flags=re.M)
    if n != 1:
        sys.exit(f"template edit '{what}' matched {n} times (expected 1)")
    return t


def udb(tpl):
    t = tpl
    t = sub(t, r"^name: cv32a65x$", "name: px32", "name")
    t = sub(t, r"^description: .*$", "description: PX32 Phase 1 core (RV32IMC_Zicsr_Zifencei, M-mode only)", "description")
    t = sub(t, r"^implemented_extensions:\n(?:  - .*\n)+",
            "implemented_extensions:\n"
            "  - { name: I, version: \"= 2.1\" }\n"
            "  - { name: M, version: \"= 2.0\" }\n"
            "  - { name: Zmmul, version: \"= 1.0.0\" }\n"
            "  - { name: C, version: \"= 2.0\" }\n"
            "  - { name: Zca, version: \"= 1.0.0\" }\n"
            "  - { name: Zicsr, version: \"= 2.0\" }\n"
            "  - { name: Zifencei, version: \"= 2.0\" }\n"
            "  - { name: Sm, version: \"= 1.13.0\" }\n", "extensions")
    t = sub(t, r"^  PMA_GRANULARITY: .*$", "  PMA_GRANULARITY: 2 # 4-byte natural granule (32-bit OBI, byte enables)", "PMA")
    t = sub(t, r"^  MTVAL_WIDTH: .*$", "  MTVAL_WIDTH: 32 # full mtval (D-022)", "MTVAL_WIDTH")
    t = sub(t, r"^  MTVEC_ILLEGAL_WRITE_BEHAVIOR: .*$",
            "  MTVEC_ILLEGAL_WRITE_BEHAVIOR: custom # BASE is written, MODE is forced to Direct (D-022)", "mtvec illegal")
    for p in ["REPORT_ENCODING_IN_MTVAL_ON_ILLEGAL_INSTRUCTION", "REPORT_VA_IN_MTVAL_ON_BREAKPOINT",
              "REPORT_VA_IN_MTVAL_ON_LOAD_MISALIGNED", "REPORT_VA_IN_MTVAL_ON_STORE_AMO_MISALIGNED",
              "REPORT_VA_IN_MTVAL_ON_INSTRUCTION_ACCESS_FAULT", "REPORT_VA_IN_MTVAL_ON_INSTRUCTION_MISALIGNED",
              "REPORT_VA_IN_MTVAL_ON_LOAD_ACCESS_FAULT", "REPORT_VA_IN_MTVAL_ON_STORE_AMO_ACCESS_FAULT"]:
        t = sub(t, rf"^  {p}: false$", f"  {p}: true", p)
    t = sub(t, r"^  MARCHID_IMPLEMENTED: true$", "  MARCHID_IMPLEMENTED: false # marchid reads 0", "marchid")
    t = sub(t, r"^  ARCH_ID_VALUE: .*\n", "", "archid value")
    t = sub(t, r"^  MIMPID_IMPLEMENTED: true$", "  MIMPID_IMPLEMENTED: false # mimpid reads 0 (MIMPID parameter)", "mimpid")
    t = sub(t, r"^  IMP_ID_VALUE: .*\n", "", "impid value")
    t = sub(t, r"^  VENDOR_ID_BANK: .*$", "  VENDOR_ID_BANK: 0x0 # mvendorid reads 0", "vendor bank")
    t = sub(t, r"^  VENDOR_ID_OFFSET: .*$", "  VENDOR_ID_OFFSET: 0x0", "vendor offset")
    t = sub(t, r"^  MCOUNTINHIBIT_IMPLEMENTED: true$", "  MCOUNTINHIBIT_IMPLEMENTED: false # mcountinhibit traps (D-022)",
            "mcountinhibit")
    # every entry of the three 32-entry arrays: no inhibit, no hpm counters, no mcounteren
    for arr in ["COUNTINHIBIT_EN", "HPM_COUNTER_EN", "MCOUNTENABLE_EN"]:
        m = re.search(rf"^  {arr}:\n\s*\[(.*?)\]", t, re.S | re.M)
        if not m:
            sys.exit(f"template array {arr} not found")
        t = t[:m.start(1)] + "\n" + "      false,\n" * 31 + "      false\n    " + t[m.end(1):]
    return ("# PX32 UDB configuration for riscv-arch-test 4.1.0 (ACT4). Generated by\n"
            "# scripts/compliance/make_act4_config.py from config/cores/cva6/cv32a65x; NOT VALIDATED.\n" + t)


def sail(tpl):
    t = tpl
    t = edit(t, '"vendorid": 1538,', '"vendorid": 0,')
    t = edit(t, '"archid": 3,', '"archid": 0,')
    t = sub(t, r'"clint": \{\s*"supported": true', '"clint": {\n      "supported": false', "clint")
    for ext, sup in [("Zifencei", "true"), ("Zcb", "false"), ("Zba", "false"), ("Zbb", "false"),
                     ("Zbs", "false"), ("Zbc", "false")]:
        t = sub(t, rf'("{ext}": \{{\s*"supported": )(true|false)', rf"\g<1>{sup}", ext)
    # xtval: PX32 writes mtval for every exception class it raises (D-022)
    t = sub(t, r"^    // mtval is hardwired to 0 in CVA6.*$",
            "    // PX32 writes mtval for every exception class it raises (D-022)", "xtval comment")
    m = re.search(r'"xtval_nonzero": \{(.*?)\}', t, re.S)
    if not m:
        sys.exit("xtval_nonzero not found")
    block = m.group(1)
    for k in ["illegal_instruction", "software_breakpoint", "load_address_misaligned", "load_access_fault",
              "samo_address_misaligned", "samo_access_fault", "fetch_address_misaligned", "fetch_access_fault"]:
        block, n = re.subn(rf'("{k}": )(true|false)', r"\g<1>true", block)
        if n != 1:
            sys.exit(f"xtval_nonzero.{k} matched {n} times")
    t = t[:m.start(1)] + block + t[m.end(1):]
    # memory: replace the region list with the single PX32 RAM
    m = re.search(r'"regions": \[(.*)\n    \]', t, re.S)
    if not m:
        sys.exit("memory regions not found")
    region = f'''
      // PX32 compliance memory: 1 MB read/write/execute at 0x1000_0000 (tb_compliance)
      {{
        "base": {{ "len": 64, "value": "0x{RAM_BASE:08x}" }},
        "size": {{ "len": 64, "value": "0x{RAM_SIZE:x}" }},
        "attributes": {{
          "mem_type": "MainMemory",
          "cacheable": false,
          "coherent": true,
          "executable": true,
          "readable": true,
          "writable": true,
          "read_idempotent": true,
          "write_idempotent": true,
          "misaligned_exceptions": {{
            "load_store": {{ "Some": "AlignmentException" }},
            "vector": {{ "Some": "AlignmentException" }},
            "amo": "AlignmentException"
          }},
          "atomic_support": "AMONone",
          "misaligned_atomicity_granule_size_exp": 0,
          "vector_misaligned_atomicity_granule_size_exp": 0,
          "reservability": "RsrvNone",
          "supports_cbo_zero": false,
          "supports_pte_read": false,
          "supports_pte_write": false
        }},
        "include_in_device_tree": true
      }}'''
    t = t[:m.start(1)] + region + t[m.end(1):]
    return t


def link():
    return f"""/* PX32 linker script for riscv-arch-test 4.1.0 (ACT4). Layout from the upstream DUT
 * examples; memory = tb_compliance's single RWX region at 0x1000_0000 (1 MB). The last 16
 * bytes hold the halt word (0x{HALT:08x}) and the console byte (0x{CONSOLE:08x}). */
RAM_ORIGIN = 0x{RAM_BASE:08x};
RAM_LENGTH = 0x{RAM_SIZE - 0x10:x};
TEST_BASE = 0x{RAM_BASE:08x};
NUM_HARTS = 1;
STACK_SIZE = 0x4000;

OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY
{{
  ram (rwx) : ORIGIN = RAM_ORIGIN, LENGTH = RAM_LENGTH
}}

PROVIDE(__stack_size = STACK_SIZE);
PROVIDE(__num_harts = NUM_HARTS);

SECTIONS
{{
  .text.init   TEST_BASE : {{ *(.text.init) }} > ram
  .text.rvtest . : {{ *(.text.rvtest) *(.text.rvtest.*) }} > ram
  . = ALIGN(0x1000);
  .rodata . : {{ *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) }} > ram
  .data   . : {{ *(.data) *(.data.*) *(.sdata) *(.sdata.*) }} > ram
  . = ALIGN(16);
  .bss . : {{
    __bss_start = .;
    *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  }} > ram
  . = ALIGN(16);
  __stack_bottom = .;
  . += __stack_size * __num_harts;
  __stack_top = .;
  . = ALIGN(0x1000);
  .text.rvmodel . : {{ *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) }} > ram
  . = ALIGN(0x1000);
  _end = .;
  ASSERT(_end <= ORIGIN(ram) + LENGTH(ram), "ACT ELF exceeds the PX32 compliance memory")
}}
"""


def macros():
    return f"""# rvmodel_macros.h: RVMODEL macros for PX32 (riscv-arch-test 4.1.0, ACT4).
# Generated by scripts/compliance/make_act4_config.py; NOT VALIDATED by the framework yet.
# Halting uses the tb_compliance tohost protocol: store 1 (pass) or 3 (fail) to the halt
# word; the bench ends the simulation on that store. Console: byte stores to 0x{CONSOLE:08x}.

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION

#define STANDARD_SM_SUPPORTED

# Unmapped address: PX32 raises a load/store access fault (bus error, contract section 3.2).
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x30000000

#define RVMODEL_HALT_PASS  \\
  li x1, 1                ;\\
  li t0, 0x{HALT:08x}     ;\\
  write_halt_pass:        ;\\
    sw x1, 0(t0)          ;\\
  self_loop_pass:         ;\\
    j self_loop_pass      ;\\

#define RVMODEL_HALT_FAIL \\
  li x1, 3                ;\\
  li t0, 0x{HALT:08x}     ;\\
  write_halt_fail:        ;\\
    sw x1, 0(t0)          ;\\
  self_loop_fail:         ;\\
    j self_loop_fail      ;\\

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \\
1:                           ;                        \\
  lbu  _R1, 0(_STR_PTR)      ;                        \\
  beqz _R1, 3f               ;                        \\
  li   _R2, 0x{CONSOLE:08x}  ;                        \\
  sb   _R1, 0(_R2)           ;                        \\
  addi _STR_PTR, _STR_PTR, 1 ;                        \\
  j 1b                       ;                        \\
3:

# No interrupt sources before Phase 2 (CLIC): interrupt tests are not selected by the
# configuration; the macros stay empty.
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", type=Path, default=Path("C:/px32-tools/src/riscv-arch-test"))
    a = ap.parse_args()
    head = (a.suite / ".git/HEAD").read_text().strip() if (a.suite / ".git/HEAD").exists() else ""
    if head != SUITE_COMMIT:
        sys.exit(f"riscv-arch-test checkout is at {head or 'unknown'}, expected {SUITE_COMMIT}")
    tpl = a.suite / "config/cores/cva6/cv32a65x"
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "px32.yaml").write_bytes(udb((tpl / "cv32a65x.yaml").read_text(encoding="utf-8")).encode())
    (OUT / "sail.json").write_bytes(sail((tpl / "sail.json").read_text(encoding="utf-8")).encode())
    (OUT / "link.ld").write_bytes(link().encode())
    (OUT / "rvmodel_macros.h").write_bytes(macros().encode())
    (OUT / "test_config.yaml").write_bytes(
        ("# PX32 ACT4 test configuration (riscv-arch-test 4.1.0). NOT VALIDATED.\n"
         "name: px32\n"
         "compiler_exe: riscv-none-elf-gcc # xPack 15.2.0-1 (Windows build through wsl_wingcc.sh)\n"
         "objdump_exe: riscv-none-elf-objdump\n"
         "ref_model_exe: sail_riscv_sim # Sail 0.14.1\n"
         "udb_config: px32.yaml\n"
         "linker_script: link.ld\n"
         "dut_include_dir: .\n").encode())
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
