/* t02_forwarding: every data-hazard distance and path.
 *   EX->EX (WB-to-EX forwarding) on rs1 and rs2, distance 2 (register-file
 *   write-through), distance 3, long chains, store data, branch operands, JAL link,
 *   and every load-use case (ALU operand, store data, address, branch operand). */
#include "px_test.h"

  .data
  .balign 4
buf:  .word 0, 0, 0, 0
ptr:  .word 0
val:  .word 0x00000123

  .text
  .globl test_main
test_main:
  .option norvc
  /* distance 1, rs1 and rs2 */
  li   a0, 5
  addi a1, a0, 1
  CHECK(1, a1, 6)
  li   a0, 7
  add  a1, x0, a0
  CHECK(2, a1, 7)
  li   a0, 3
  sub  a1, a0, a0                  /* both operands forwarded */
  CHECK(3, a1, 0)
  /* distance 2 and 3 */
  li   a0, 11
  nop
  addi a1, a0, 1
  CHECK(4, a1, 12)
  li   a0, 13
  nop
  nop
  addi a1, a0, 1
  CHECK(5, a1, 14)
  /* chain: every instruction depends on the one before */
  li   a0, 0
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  CHECK(6, a0, 5)
  /* newest value wins when two older instructions write the same register */
  li   a0, 1
  li   a0, 2
  addi a1, a0, 0
  CHECK(7, a1, 2)
  /* store data and address forwarded */
  la   a2, buf
  li   a3, 0x55
  sw   a3, 0(a2)
  lw   a4, 0(a2)
  CHECK(8, a4, 0x55)
  la   a2, buf
  addi a2, a2, 4                    /* address register forwarded into the store */
  sw   a3, 0(a2)
  lw   a4, 0(a2)
  CHECK(9, a4, 0x55)
  /* branch operands forwarded */
  li   a0, 9
  li   a1, 9
  beq  a0, a1, 1f
  j    fail_handler
1:
  /* JAL link forwarded */
  jal  ra, 2f
3:
  j    fail_handler
2:
  la   a5, 3b
  CHECK_REG(10, ra, a5)
  /* load-use: ALU operand */
  la   a2, val
  lw   a0, 0(a2)
  addi a1, a0, 1
  CHECK(11, a1, 0x124)
  /* load-use: store data */
  la   a2, val
  la   a6, buf
  lw   a0, 0(a2)
  sw   a0, 8(a6)
  lw   a1, 8(a6)
  CHECK(12, a1, 0x123)
  /* load-use: address (pointer chase) */
  la   a2, ptr
  la   a3, val
  sw   a3, 0(a2)
  lw   a0, 0(a2)
  lw   a1, 0(a0)
  CHECK(13, a1, 0x123)
  /* load-use: branch operand */
  la   a2, val
  li   a1, 0x123
  lw   a0, 0(a2)
  beq  a0, a1, 4f
  j    fail_handler
4:
  /* load then independent instruction, then use (distance 2, no stall needed) */
  lw   a0, 0(a2)
  nop
  addi a1, a0, 2
  CHECK(14, a1, 0x125)
  /* load into rd that the next instruction does not use */
  lw   a0, 0(a2)
  addi a1, a3, 0
  CHECK_REG(15, a1, a3)
  PASS
