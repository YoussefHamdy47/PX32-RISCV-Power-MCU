/* t05_compressed: every RV32C instruction executed, 32-bit instructions straddling
 * word boundaries, branches and jumps to targets at both halfword offsets (16- and
 * 32-bit), and link values PC + 2 for C.JAL / C.JALR. */
#include "px_test.h"

  .data
  .balign 4
cbuf: .word 0x11111111, 0x22222222, 0, 0

  .text
  .globl test_main
test_main:
  .option rvc
  li   sp, 0x2000E000
  /* C.LI, C.ADDI, C.LUI, C.MV, C.ADD */
  c.li   a0, 5
  c.addi a0, -3
  CHECK(1, a0, 2)
  c.lui  a1, 0x12
  CHECK(2, a1, 0x12000)
  c.mv   a2, a0
  c.add  a2, a1
  CHECK(3, a2, 0x12002)
  /* C.SUB, C.XOR, C.OR, C.AND, C.ANDI, C.SLLI, C.SRLI, C.SRAI (rd' = x8..x15) */
  li   s0, 0x0F0
  li   s1, 0x0FF
  c.sub s1, s0
  CHECK(4, s1, 0x00F)
  c.xor s1, s0
  CHECK(5, s1, 0x0FF)
  c.or  s0, s1
  CHECK(6, s0, 0x0FF)
  c.and s0, s1
  CHECK(7, s0, 0x0FF)
  c.andi s0, 0x0F
  CHECK(8, s0, 0x0F)
  c.slli s0, 28
  CHECK(9, s0, 0xF0000000)
  c.srai s0, 4
  CHECK(10, s0, 0xFF000000)
  c.srli s0, 24
  CHECK(11, s0, 0xFF)
  /* C.ADDI16SP, C.ADDI4SPN, C.SWSP, C.LWSP */
  c.addi16sp sp, -32
  li   a3, 0x2000DFE0
  CHECK_REG(12, sp, a3)
  c.addi4spn a4, sp, 16
  li   a3, 0x2000DFF0
  CHECK_REG(13, a4, a3)
  li   a5, 0x5A5A5A5A
  c.swsp a5, 8(sp)
  c.lwsp a1, 8(sp)
  CHECK(14, a1, 0x5A5A5A5A)
  c.addi16sp sp, 32
  /* C.LW, C.SW */
  la   s0, cbuf
  c.lw s1, 4(s0)
  CHECK(15, s1, 0x22222222)
  c.sw s1, 8(s0)
  c.lw a0, 8(s0)
  CHECK(16, a0, 0x22222222)
  /* C.BEQZ, C.BNEZ taken and not taken */
  li   s0, 0
  c.beqz s0, 1f
  j    fail_handler
1:
  c.bnez s0, cfail                 /* s0 == 0: must not be taken */
  li   s0, 1
  c.bnez s0, 2f
  j    fail_handler
cfail:                             /* near target for the short-range c.bnez */
  li   gp, 99
  j    fail_handler
2:
  /* C.J, C.JR */
  c.j  3f
  j    fail_handler
3:
  la   a5, 4f
  c.jr a5
  j    fail_handler
4:
  /* C.JAL: link is PC + 2 */
  c.jal 5f
6:
  j    fail_handler
5:
  la   a5, 6b
  CHECK_REG(17, ra, a5)
  /* C.JALR: link is PC + 2 */
  la   a5, 7f
  c.jalr a5
8:
  j    fail_handler
7:
  la   a6, 8b
  CHECK_REG(18, ra, a6)

  /* 32-bit instructions straddling word boundaries: c.nop shifts alignment by 2 */
  .balign 4
  c.nop
  li   a0, 0x12345678              /* lui + addi, both 32-bit, at offset 2 */
  add  a1, a0, x0
  sub  a2, a1, a0
  CHECK(19, a1, 0x12345678)
  CHECK(20, a2, 0)

  /* Branch to a 32-bit instruction at offset 2 of a word */
  .balign 4
  beq  x0, x0, 9f
  j    fail_handler
  .balign 4
  c.nop
9:
  .option push
  .option norvc
  addi a0, x0, 77                  /* 32-bit target at halfword offset 2 */
  .option pop
  CHECK(21, a0, 77)
  /* Branch to a 16-bit instruction at offset 2 of a word */
  .balign 4
  beq  x0, x0, 10f
  j    fail_handler
  .balign 4
  c.nop
10:
  c.li a0, 9
  CHECK(22, a0, 9)
  PASS
