/* t01_alu: every RV32I register and immediate ALU instruction, LUI and AUIPC,
 * at edge values. Mix of 32-bit and compressed encodings (the assembler compresses
 * eligible instructions). */
#include "px_test.h"

  .text
  .globl test_main
test_main:
  li   a0, 0x7FFFFFFF
  li   a1, 1
  add  a2, a0, a1
  CHECK(1, a2, 0x80000000)          /* signed overflow wraps */
  sub  a2, a1, a0
  CHECK(2, a2, 0x80000002)
  li   a3, -1
  sltu a2, a1, a3
  CHECK(3, a2, 1)
  slt  a2, a1, a3
  CHECK(4, a2, 0)
  slti a2, a3, 0
  CHECK(5, a2, 1)
  sltiu a2, a1, -1                  /* immediate sign-extended, then unsigned compare */
  CHECK(6, a2, 1)
  xori a2, a0, -1
  CHECK(7, a2, 0x80000000)
  ori  a2, a1, 0x7F0
  CHECK(8, a2, 0x7F1)
  andi a2, a3, 0x0F0
  CHECK(9, a2, 0xF0)
  li   a4, 0x80000001
  srai a2, a4, 31
  CHECK(10, a2, -1)
  srli a2, a4, 31
  CHECK(11, a2, 1)
  slli a2, a1, 31
  CHECK(12, a2, 0x80000000)
  li   a5, 33                       /* shift amounts use only the low 5 bits */
  sll  a2, a1, a5
  CHECK(13, a2, 2)
  srl  a2, a4, a5
  CHECK(14, a2, 0x40000000)
  sra  a2, a4, a5
  CHECK(15, a2, 0xC0000000)
  xor  a2, a0, a3
  CHECK(16, a2, 0x80000000)
  or   a2, a4, a1
  CHECK(17, a2, 0x80000001)
  and  a2, a4, a0
  CHECK(18, a2, 1)
  lui  a2, 0xFFFFF
  CHECK(19, a2, 0xFFFFF000)
1:
  auipc a2, 0x1
  la    a6, 1b
  li    a7, 0x1000
  add   a6, a6, a7
  CHECK_REG(20, a2, a6)             /* auipc = pc + imm */
  addi  x0, a0, 5                   /* HINT: x0 stays zero */
  mv    a2, x0
  CHECK(21, a2, 0)
  PASS
