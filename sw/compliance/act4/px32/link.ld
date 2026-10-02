/* PX32 linker script for riscv-arch-test 4.1.0 (ACT4). Layout from the upstream DUT
 * examples; memory = tb_compliance's single RWX region at 0x1000_0000 (1 MB). The last 16
 * bytes hold the halt word (0x100ffff0) and the console byte (0x100ffff8). */
RAM_ORIGIN = 0x10000000;
RAM_LENGTH = 0xffff0;
TEST_BASE = 0x10000000;
NUM_HARTS = 1;
STACK_SIZE = 0x4000;

OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY
{
  ram (rwx) : ORIGIN = RAM_ORIGIN, LENGTH = RAM_LENGTH
}

PROVIDE(__stack_size = STACK_SIZE);
PROVIDE(__num_harts = NUM_HARTS);

SECTIONS
{
  .text.init   TEST_BASE : { *(.text.init) } > ram
  .text.rvtest . : { *(.text.rvtest) *(.text.rvtest.*) } > ram
  . = ALIGN(0x1000);
  .rodata . : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > ram
  .data   . : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) } > ram
  . = ALIGN(16);
  .bss . : {
    __bss_start = .;
    *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > ram
  . = ALIGN(16);
  __stack_bottom = .;
  . += __stack_size * __num_harts;
  __stack_top = .;
  . = ALIGN(0x1000);
  .text.rvmodel . : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) } > ram
  . = ALIGN(0x1000);
  _end = .;
  ASSERT(_end <= ORIGIN(ram) + LENGTH(ram), "ACT ELF exceeds the PX32 compliance memory")
}
