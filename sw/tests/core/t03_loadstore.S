/* t03_loadstore: every load/store width at every legal byte offset, sign and zero
 * extension, byte-lane merging, store-to-load ordering, negative offsets, and data
 * reads from ITCM through the data port. */
#include "px_test.h"

  .data
  .balign 4
w0:   .word 0x80FF7F01
w1:   .word 0
w2:   .word 0

  .section .rodata
  .balign 4
rom:  .word 0xCAFEF00D

  .text
  .globl test_main
test_main:
  la   a0, w0
  lb   a1, 0(a0)
  CHECK(1, a1, 0x01)
  lb   a1, 1(a0)
  CHECK(2, a1, 0x7F)
  lb   a1, 2(a0)
  CHECK(3, a1, -1)
  lb   a1, 3(a0)
  CHECK(4, a1, -128)
  lbu  a1, 2(a0)
  CHECK(5, a1, 0xFF)
  lbu  a1, 3(a0)
  CHECK(6, a1, 0x80)
  lh   a1, 0(a0)
  CHECK(7, a1, 0x7F01)
  lh   a1, 2(a0)
  CHECK(8, a1, 0xFFFF80FF)
  lhu  a1, 2(a0)
  CHECK(9, a1, 0x80FF)
  lw   a1, 0(a0)
  CHECK(10, a1, 0x80FF7F01)
  /* byte stores into each lane */
  la   a0, w1
  li   a2, 0x11
  sb   a2, 0(a0)
  li   a2, 0x22
  sb   a2, 1(a0)
  li   a2, 0x33
  sb   a2, 2(a0)
  li   a2, 0x44
  sb   a2, 3(a0)
  lw   a1, 0(a0)
  CHECK(11, a1, 0x44332211)
  /* halfword stores into each half; upper bits of the source are ignored */
  li   a2, 0xABCD5566
  sh   a2, 0(a0)
  lw   a1, 0(a0)
  CHECK(12, a1, 0x44335566)
  sh   a2, 2(a0)
  lw   a1, 0(a0)
  CHECK(13, a1, 0x55665566)
  /* store immediately followed by a load of the same word */
  la   a0, w2
  li   a2, 0x0BADF00D
  sw   a2, 0(a0)
  lw   a1, 0(a0)
  CHECK(14, a1, 0x0BADF00D)
  /* negative offset */
  la   a0, w2
  lw   a1, -8(a0)
  CHECK(15, a1, 0x80FF7F01)
  /* data read from ITCM (read-only data placed with the code) */
  la   a0, rom
  lw   a1, 0(a0)
  CHECK(16, a1, 0xCAFEF00D)
  lhu  a1, 2(a0)
  CHECK(17, a1, 0xCAFE)
  PASS
