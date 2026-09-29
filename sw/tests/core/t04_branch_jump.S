/* t04_branch_jump: all six branch conditions taken and not taken at signed/unsigned
 * boundaries, forward and backward branches, wrong-path instructions after taken
 * branches and jumps (must not execute), JAL/JALR link values, JALR clearing bit 0,
 * and JALR with rd == rs1. */
#include "px_test.h"

#define TAKEN(br, x, y, n)     li gp, n; br x, y, 8f; j fail_handler; 8:
#define NOT_TAKEN(br, x, y, n) br x, y, fail_handler_far_##n; j 8f; fail_handler_far_##n: li gp, n; j fail_handler; 8:

  .text
  .globl test_main
test_main:
  li   a0, -1
  li   a1, 1
  li   a2, 1
  TAKEN(beq, a1, a2, 1)
  NOT_TAKEN(beq, a0, a1, 2)
  TAKEN(bne, a0, a1, 3)
  NOT_TAKEN(bne, a1, a2, 4)
  TAKEN(blt, a0, a1, 5)            /* -1 < 1 signed */
  NOT_TAKEN(blt, a1, a0, 6)
  NOT_TAKEN(blt, a1, a2, 7)        /* equal is not less */
  TAKEN(bge, a1, a0, 8)
  TAKEN(bge, a1, a2, 9)            /* equal */
  NOT_TAKEN(bge, a0, a1, 10)
  TAKEN(bltu, a1, a0, 11)          /* 1 < 0xFFFFFFFF unsigned */
  NOT_TAKEN(bltu, a0, a1, 12)
  TAKEN(bgeu, a0, a1, 13)
  NOT_TAKEN(bgeu, a1, a0, 14)
  li   a3, 0x80000000
  li   a4, 0x7FFFFFFF
  TAKEN(blt, a3, a4, 15)           /* most negative < most positive */
  TAKEN(bltu, a4, a3, 16)

  /* backward branch loop */
  li   a0, 0
  li   a1, 10
1:
  addi a0, a0, 1
  bne  a0, a1, 1b
  CHECK(17, a0, 10)

  /* wrong-path instructions after a taken branch must not execute */
  li   a0, 0
  beq  x0, x0, 2f
  addi a0, a0, 1
  addi a0, a0, 1
2:
  CHECK(18, a0, 0)
  /* ... and after JAL and JALR */
  li   a0, 0
  jal  x0, 3f
  addi a0, a0, 1
3:
  la   a5, 4f
  jalr x0, 0(a5)
  addi a0, a0, 1
4:
  CHECK(19, a0, 0)

  /* JAL link value */
  jal  ra, 5f
6:
  j    fail_handler
5:
  la   a5, 6b
  CHECK_REG(20, ra, a5)
  /* JALR link value, bit 0 of the target cleared */
  la   a5, 7f
  jalr ra, 1(a5)                   /* target 7f + 1, bit 0 cleared -> 7f */
9:
  j    fail_handler
7:
  la   a6, 9b
  CHECK_REG(21, ra, a6)
  /* JALR with rd == rs1: target uses the old value */
  la   a0, 10f
  jalr a0, 0(a0)
11:
  j    fail_handler
10:
  la   a6, 11b
  CHECK_REG(22, a0, a6)
  PASS
