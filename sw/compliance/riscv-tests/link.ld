/* PX32 linker script for the riscv-tests p environment (step 1.8).
 * Same layout as upstream env/p/link.ld, rebased from 0x8000_0000 to the PX32 memory at
 * 0x1000_0000 (tb/compliance: 1 MB, read/write/execute). The p environment keeps code,
 * data and tohost in one region, and fence_i executes code placed in .data. */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x10000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
  ASSERT(_end <= 0x10100000, "test image larger than the 1 MB compliance memory")
}
