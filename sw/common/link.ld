/* Linker script for PX32 core tests (Phase 1).
 * Code and read-only data in ITCM, data in DTCM. The last 4 KB of DTCM hold the
 * test harness words: expected-trap table (0x2000_F000), timing marker (0x2000_FFE0)
 * and tohost (0x2000_FFF0). */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ITCM    (rx) : ORIGIN = 0x10000000, LENGTH = 64K
  DTCM    (rw) : ORIGIN = 0x20000000, LENGTH = 60K
  HARNESS (rw) : ORIGIN = 0x2000F000, LENGTH = 4K
}

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text .text.*)
    *(.rodata .rodata.*)
  } > ITCM

  .data : {
    *(.data .data.* .sdata .sdata.*)
    *(.bss .bss.* .sbss .sbss.* COMMON)
  } > DTCM

  .traptab : { *(.traptab) } > HARNESS

  /DISCARD/ : { *(.riscv.attributes) *(.comment) }
}
