/* t14_timing_isa: cycle-exact timing of every RV32IMC instruction form (step 1.10).
 *
 * t08 (and t12/t13) check each row of the ARCHITECTURE.md Â§ 4.1 table with one instruction
 * form. This program checks the same rows for every other form: all register/immediate ALU
 * instructions, every compressed ALU form, every load and store width including C.LW/C.LWSP/
 * C.SW/C.SWSP, load-use after each load form, all six branch conditions taken and not taken,
 * C.BEQZ/C.BNEZ, JAL/C.J/C.JAL with and without a link, JALR/C.JR/C.JALR, MULH/MULHSU/MULHU
 * with independent and dependent successors, the six Zicsr forms, FENCE and WFI.
 *
 * Each block is bracketed by timing markers (ideal memories; see t08): the end marker must
 * retire exactly DELTA cycles after the start marker. DELTA counts every instruction between
 * the markers plus the end marker itself, plus the Â§ 4.1 penalties: load-use +1, taken
 * branch 3, JAL (any form) 2, JALR (any form) 3, MUL dependent successor +1. Every redirect
 * target is word aligned, so the D-020 halfword-offset penalty never applies here. */
#include "px_test.h"

#define BLOCK(id, delta)  MARK_PREP(s0, 0, 0); MARK_PREP(s1, id, delta); MARK_REG(s0)
#define END               MARK_REG(s1)
#define NORVC             .option push; .option norvc
#define RVC               .option pop

  .data
  .balign 4
tv:   .word 0x80018002, 6, tv, 0x7FFF8000
buf:  .space 64

  .text
  .globl test_main
test_main:
  .option rvc
  NORVC
  MARK_BASE
  la   a1, tv
  la   sp, buf
  la   a5, buf
  li   a2, 3
  li   a3, -7
  li   a4, 100

  /* 1. every RV32I register and immediate ALU form, a dependent chain: 21 + end */
  .balign 4
  BLOCK(1, 22)
  lui   a0, 0x12345
  auipc a0, 0x1
  addi  a0, a0, 7
  slti  a0, a0, 100
  sltiu a0, a0, 2
  xori  a0, a0, 0x55
  ori   a0, a0, 0x100
  andi  a0, a0, 0x1F0
  slli  a0, a0, 3
  srli  a0, a0, 1
  srai  a0, a0, 2
  add   a0, a0, a2
  sub   a0, a0, a3
  sll   a0, a0, a2
  slt   a0, a0, a4
  sltu  a0, a0, a4
  xor   a0, a0, a3
  srl   a0, a0, a2
  sra   a0, a0, a2
  or    a0, a0, a4
  and   a0, a0, a3
  END
  RVC

  /* 2. every compressed ALU form, mostly dependent: 17 + end */
  .balign 4
  NORVC; BLOCK(2, 18); RVC
  c.li       a0, 5
  c.lui      a0, 3
  c.addi     a0, 1
  c.addi16sp sp, 16
  c.addi4spn a0, sp, 8
  c.slli     a0, 2
  c.srli     a0, 1
  c.srai     a0, 1
  c.andi     a0, 15
  c.mv       a5, a0
  c.add      a5, a0
  c.sub      a5, a0
  c.xor      a5, a0
  c.or       a5, a0
  c.and      a5, a0
  c.nop
  c.addi16sp sp, -16
  NORVC; END; RVC
  la   a5, buf

  /* 3. every load form, result not used next: 7 + end */
  .balign 4
  NORVC; BLOCK(3, 8)
  lb   a2, 0(a1)
  lbu  a3, 1(a1)
  lh   a4, 2(a1)
  lhu  a0, 2(a1)
  lw   a2, 4(a1)
  RVC
  c.lw   a3, 4(a1)
  c.lwsp a4, 0(sp)
  NORVC; END; RVC

  /* 4. every load form, result used next: 7 x (1 + 1 stall + 1) + end */
  .balign 4
  NORVC; BLOCK(4, 22)
  lb   a2, 0(a1)
  addi a2, a2, 1
  lbu  a3, 1(a1)
  addi a3, a3, 1
  lh   a4, 2(a1)
  addi a4, a4, 1
  lhu  a0, 2(a1)
  addi a0, a0, 1
  lw   a2, 4(a1)
  addi a2, a2, 1
  RVC
  c.lw   a3, 4(a1)
  c.addi a3, 1
  c.lwsp a4, 0(sp)
  c.addi a4, 1
  NORVC; END; RVC

  /* 5. every store form: 5 + end */
  .balign 4
  NORVC; BLOCK(5, 6)
  sb   a2, 0(sp)
  sh   a2, 2(sp)
  sw   a2, 4(sp)
  RVC
  c.sw   a2, 8(a5)
  c.swsp a2, 12(sp)
  NORVC; END; RVC

  /* operands for the branches: a2 = 3, a3 = -7, a4 = 100, a0 = 0 */
  NORVC
  li   a2, 3
  li   a3, -7
  li   a4, 100
  li   a0, 0
  RVC

  /* 6. every branch form, not taken: 8 + end */
  .balign 4
  NORVC; BLOCK(6, 9)
  beq  a2, a3, 69f
  bne  a2, a2, 69f
  blt  a4, a2, 69f
  bge  a3, a2, 69f
  bltu a3, a2, 69f
  bgeu a2, a3, 69f
  RVC
  c.beqz a2, 69f
  c.bnez a0, 69f
  NORVC; END; RVC
  NORVC; j 70f; RVC
69:
  NORVC; j fail_handler; RVC
70:

  /* 7-12. each branch condition taken: 3 + end */
#define TAKEN(id, op, a, b)    \
  .balign 4;                   \
  NORVC; BLOCK(id, 4);         \
  op a, b, 1f;                 \
  j fail_handler;              \
  .balign 4;                   \
1:                             \
  END; RVC
  TAKEN(7, beq, a2, a2)
  TAKEN(8, bne, a2, a3)
  TAKEN(9, blt, a3, a2)
  TAKEN(10, bge, a2, a3)
  TAKEN(11, bltu, a2, a3)
  TAKEN(12, bgeu, a3, a2)

  /* 13-14. C.BEQZ / C.BNEZ taken: 3 + end */
  .balign 4
  NORVC; BLOCK(13, 4); RVC
  c.beqz a0, 13f
  c.j    fail_rvc
  .balign 4
13:
  NORVC; END; RVC
  .balign 4
  NORVC; BLOCK(14, 4); RVC
  c.bnez a2, 14f
  c.j    fail_rvc
  .balign 4
14:
  NORVC; END; RVC

  /* 15-17. JAL with a link, C.J, C.JAL: 2 + end */
  .balign 4
  NORVC; BLOCK(15, 3)
  jal  ra, 15f
  j    fail_handler
  .balign 4
15:
  END; RVC
  .balign 4
  NORVC; BLOCK(16, 3); RVC
  c.j  16f
  c.j  fail_rvc
  .balign 4
16:
  NORVC; END; RVC
  .balign 4
  NORVC; BLOCK(17, 3); RVC
  c.jal 17f
  c.j   fail_rvc
  .balign 4
17:
  NORVC; END; RVC

  /* 18-20. JALR with a link, C.JR, C.JALR: 3 + end */
  NORVC; la a5, 18f; RVC
  .balign 4
  NORVC; BLOCK(18, 4)
  jalr ra, 0(a5)
  j    fail_handler
  .balign 4
18:
  END; RVC
  NORVC; la a5, 19f; RVC
  .balign 4
  NORVC; BLOCK(19, 4); RVC
  c.jr a5
  c.j  fail_rvc
  .balign 4
19:
  NORVC; END; RVC
  NORVC; la a5, 20f; RVC
  .balign 4
  NORVC; BLOCK(20, 4); RVC
  c.jalr a5
  c.j    fail_rvc
  .balign 4
20:
  NORVC; END; RVC

  /* 21-26. MULH, MULHSU, MULHU: independent successor 1 + 1 + end, dependent +1 stall */
  NORVC
  li   a2, -3
  li   a3, 0x7FFFFFFF
  .balign 4
  BLOCK(21, 3)
  mulh   a0, a2, a3
  addi   a4, a2, 1
  END
  BLOCK(22, 4)
  mulh   a0, a2, a3
  addi   a4, a0, 1
  END
  BLOCK(23, 3)
  mulhsu a0, a2, a3
  addi   a4, a2, 1
  END
  BLOCK(24, 4)
  mulhsu a0, a2, a3
  addi   a4, a0, 1
  END
  BLOCK(25, 3)
  mulhu  a0, a2, a3
  addi   a4, a2, 1
  END
  BLOCK(26, 4)
  mulhu  a0, a2, a3
  addi   a4, a0, 1
  END

  /* 27. MULH, MULHSU, MULHU back to back, independent: throughput 1, 3 + end */
  BLOCK(27, 4)
  mulh   a0, a2, a3
  mulhsu a4, a2, a3
  mulhu  a5, a2, a3
  END

  /* 28. the six Zicsr forms on mscratch: 6 + end (mscratch restored afterwards) */
  csrr s2, mscratch
  BLOCK(28, 7)
  csrrw  a0, mscratch, a2
  csrrs  a0, mscratch, a3
  csrrc  a0, mscratch, a2
  csrrwi a0, mscratch, 5
  csrrsi a0, mscratch, 3
  csrrci a0, mscratch, 1
  END
  csrw mscratch, s2

  /* 29. a CSR read used by the next instruction: no stall, 2 + end */
  BLOCK(29, 3)
  csrr a0, mscratch
  addi a0, a0, 1
  END

  /* 30. FENCE, FENCE RW,RW and WFI retire like ALU operations: 3 + end */
  BLOCK(30, 4)
  fence
  fence rw, rw
  wfi
  END
  RVC
  PASS

fail_rvc:
  j    fail_handler
