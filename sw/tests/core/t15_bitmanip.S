/* t15_bitmanip: Zba, Zbb, Zbs and Zicond on the core (Phase 2 step 2.1, DECISIONS.md D-028).
 *
 * Expected values are worked out by hand from the instruction descriptions of the pinned
 * unprivileged manual (20240411), independently of px_alu and of the reference model; the
 * testbench also compares every retirement with scripts/px_iss.py.
 *   A. every one of the 31 instructions on fixed operands, including the corner cases
 *      (counts of 0 and all ones, rotate/bit index 0, 31 and >= 32 in rs2, min/max across
 *      the sign boundary, czero with a zero and a nonzero condition); each result is used
 *      by the very next instruction (CHECK's branch: forwarding out of EX)
 *   B. forwarding into each kind of instruction: from an ALU op in WB, from a load (load-use
 *      stall), from a multiply (MUL-use stall), from a CSR read, chains of bit-manipulation
 *      instructions
 *   C. forwarding out: branch operand, store data, store and load address base (shNadd on a
 *      word index), jump base
 *   D. 32-bit bit-manipulation instructions at halfword offsets between compressed
 *      instructions, producing and consuming compressed results
 *   E. RV64-only and reserved neighbours trap as illegal instructions (table below)
 *   F. timing (ideal memories, ARCHITECTURE.md § 4.1 "ALU op: 1"): one block per
 *      instruction form, a dependent chain of three; DELTA = instructions + end marker,
 *      plus the § 4.1 penalties where a block has them (load-use +1, taken branch 3).
 *      Every redirect target is word aligned. */
#include "px_test.h"

#define BLOCK(id, delta)  MARK_PREP(s0, 0, 0); MARK_PREP(s1, id, delta); MARK_REG(s0)
#define END               MARK_REG(s1)
#define NORVC             .option push; .option norvc
#define RVC               .option pop
/* three dependent instances of one form: 3 + end marker = 4 cycles */
#define T3(id, ...)       .balign 4; BLOCK(id, 4); __VA_ARGS__; __VA_ARGS__; __VA_ARGS__; END

  .data
  .balign 4
bdat: .word 0x00100300, 0x80000000, 0x12345678, 0
bbuf: .space 64

  .text
  .globl test_main
test_main:
  .option norvc
  MARK_BASE
  li   a1, 0x12345678
  li   a2, 0x80000001
  li   a3, 0x0000FFFF
  li   a4, 0x000000F0
  li   a5, 4
  li   s2, -1
  li   s3, 36                      /* index >= 32: only bits [4:0] = 4 count */
  li   s4, 31
  li   s5, 0x00008000

  /* ---------------- A. every instruction ---------------- */
  /* Zba: rd = rs2 + (rs1 << n) */
  sh1add a0, a1, a2
  CHECK(1, a0, 0xA468ACF1)
  sh2add a0, a1, a2
  CHECK(2, a0, 0xC8D159E1)
  sh3add a0, a1, a2
  CHECK(3, a0, 0x11A2B3C1)
  sh1add a0, s2, zero              /* bit 31 of rs1 shifted out */
  CHECK(4, a0, 0xFFFFFFFE)
  /* Zbb logic with negate */
  andn a0, a1, a3
  CHECK(5, a0, 0x12340000)
  orn  a0, a1, a3
  CHECK(6, a0, 0xFFFF5678)
  xnor a0, a1, a3
  CHECK(7, a0, 0xEDCB5678)
  /* counts */
  clz  a0, a1
  CHECK(8, a0, 3)
  clz  a0, zero
  CHECK(9, a0, 32)
  clz  a0, a2
  CHECK(10, a0, 0)
  ctz  a0, a1
  CHECK(11, a0, 3)
  ctz  a0, zero
  CHECK(12, a0, 32)
  li   t0, 0x80000000
  ctz  a0, t0
  CHECK(13, a0, 31)
  cpop a0, a1
  CHECK(14, a0, 13)
  cpop a0, s2
  CHECK(15, a0, 32)
  cpop a0, zero
  CHECK(16, a0, 0)
  /* min/max across the sign boundary (a2 is negative as a signed value) */
  max  a0, a2, a1
  CHECK(17, a0, 0x12345678)
  maxu a0, a2, a1
  CHECK(18, a0, 0x80000001)
  min  a0, a2, a1
  CHECK(19, a0, 0x80000001)
  minu a0, a2, a1
  CHECK(20, a0, 0x12345678)
  /* extensions */
  sext.b a0, a1
  CHECK(21, a0, 0x00000078)
  sext.b a0, a4
  CHECK(22, a0, 0xFFFFFFF0)
  sext.h a0, a1
  CHECK(23, a0, 0x00005678)
  sext.h a0, s5
  CHECK(24, a0, 0xFFFF8000)
  zext.h a0, a2
  CHECK(25, a0, 0x00000001)
  zext.h a0, s2
  CHECK(26, a0, 0x0000FFFF)
  /* rotates */
  rol  a0, a1, a5
  CHECK(27, a0, 0x23456781)
  rol  a0, a1, zero
  CHECK(28, a0, 0x12345678)
  rol  a0, a1, s4
  CHECK(29, a0, 0x091A2B3C)
  rol  a0, a1, s3                  /* 36 -> 4 */
  CHECK(30, a0, 0x23456781)
  ror  a0, a1, a5
  CHECK(31, a0, 0x81234567)
  ror  a0, a2, s4                  /* ror by 31 = rol by 1 */
  CHECK(32, a0, 0x00000003)
  rori a0, a1, 8
  CHECK(33, a0, 0x78123456)
  rori a0, a2, 1
  CHECK(34, a0, 0xC0000000)
  rori a0, a1, 0
  CHECK(35, a0, 0x12345678)
  /* byte operations */
  la   t0, bdat
  lw   t1, 0(t0)
  orc.b a0, t1
  CHECK(36, a0, 0x00FFFF00)
  orc.b a0, a1
  CHECK(37, a0, 0xFFFFFFFF)
  orc.b a0, zero
  CHECK(38, a0, 0)
  rev8 a0, a1
  CHECK(39, a0, 0x78563412)
  /* single-bit operations */
  bclr  a0, a1, a5
  CHECK(40, a0, 0x12345668)
  bclri a0, a1, 28
  CHECK(41, a0, 0x02345678)
  bext  a0, a1, a5
  CHECK(42, a0, 1)
  bext  a0, a1, s3                 /* 36 -> bit 4 */
  CHECK(43, a0, 1)
  bexti a0, a1, 0
  CHECK(44, a0, 0)
  bexti a0, a2, 31
  CHECK(45, a0, 1)
  binv  a0, a1, zero
  CHECK(46, a0, 0x12345679)
  binvi a0, a1, 31
  CHECK(47, a0, 0x92345678)
  bset  a0, a1, zero
  CHECK(48, a0, 0x12345679)
  bseti a0, a1, 3                  /* already set: unchanged */
  CHECK(49, a0, 0x12345678)
  bseti a0, zero, 31
  CHECK(50, a0, 0x80000000)
  /* Zicond */
  czero.eqz a0, a1, a3
  CHECK(51, a0, 0x12345678)
  czero.eqz a0, a1, zero
  CHECK(52, a0, 0)
  czero.nez a0, a1, a3
  CHECK(53, a0, 0)
  czero.nez a0, a1, zero
  CHECK(54, a0, 0x12345678)

  /* ---------------- B. forwarding into the new instructions ---------------- */
  addi t0, a1, 1                   /* ALU result forwarded from WB */
  ctz  a0, t0
  CHECK(55, a0, 0)
  la   t2, bdat
  lw   t0, 4(t2)                   /* load-use: 0x80000000 */
  clz  a0, t0
  CHECK(56, a0, 0)
  lw   t0, 8(t2)                   /* load-use into the rs2 operand */
  czero.nez a0, a1, t0
  CHECK(57, a0, 0)
  li   t0, 3
  mul  t1, t0, a5                  /* MUL-use: 12 */
  bset a0, zero, t1
  CHECK(58, a0, 0x00001000)
  csrr t0, mscratch                /* CSR result forwarded */
  csrw mscratch, t0
  li   t0, 0x0F0F0000
  csrrw t1, mtval, t0
  csrr t1, mtval
  cpop a0, t1
  CHECK(59, a0, 8)
  rev8 a0, a1                      /* chain: every result feeds the next */
  rev8 a0, a0
  rori a0, a0, 4
  rol  a0, a0, a5
  sh3add a0, a0, zero
  ctz  a0, a0
  CHECK(60, a0, 6)
  max  a0, a2, zero                /* max(INT_MIN + 1, 0) = 0 */
  minu a0, a0, a1
  CHECK(61, a0, 0)

  /* ---------------- C. forwarding out of the new instructions ---------------- */
  li   gp, 62
  bexti t0, a1, 3                  /* branch operand, taken */
  beqz t0, fail_handler
  bexti t0, a1, 2
  bnez t0, fail_handler            /* not taken */
  min  t0, a2, a1
  bge  t0, zero, fail_handler      /* signed min is negative */
  czero.eqz t0, a1, zero
  bnez t0, fail_handler
  li   gp, 63
  la   t2, bbuf
  rev8 t0, a1                      /* store data */
  sw   t0, 0(t2)
  lw   a0, 0(t2)
  CHECK(63, a0, 0x78563412)
  li   t0, 3
  sh2add t1, t0, t2                /* store address base: bbuf + 12 */
  sw   a1, 0(t1)
  lw   a0, 12(t2)
  CHECK(64, a0, 0x12345678)
  li   t0, 5
  sh1add t1, t0, t2                /* load address base: bbuf + 10 (halfword) */
  sh   a3, 0(t1)
  lhu  a0, 10(t2)
  CHECK(65, a0, 0x0000FFFF)
  li   t0, 2
  sh3add t1, t0, t2                /* bbuf + 16 (not written above) */
  lw   a0, 0(t1)
  CHECK(66, a0, 0)
  la   t0, c_tgt
  zext.h t1, t0                    /* jump base: c_tgt is in the low 64 KB of ITCM */
  li   t0, 0x10000000
  or   t1, t1, t0
  jalr ra, 0(t1)
  j    fail_handler
c_tgt:
  CHECK(67, a0, 0)

  /* ---------------- D. halfword offsets between compressed instructions ---------------- */
  .option rvc
  .balign 4
  c.li   a0, 5
  sh1add a0, a0, a1                /* at a halfword offset, straddles the word */
  c.mv   s6, a0
  cpop   a0, s6
  c.addi a0, 1
  rori   a0, a0, 1
  c.nop
  czero.eqz a3, a0, a0
  c.mv   a4, a3
  .option norvc
  CHECK(68, s6, 0x12345682)
  CHECK(69, a4, 0x00000006)
  li   a3, 0x0000FFFF
  li   a4, 0x000000F0

  /* ---------------- E. RV64-only and reserved neighbours: illegal ---------------- */
t_adduw:
  .word 0x083100bb                 /* add.uw x1, x2, x3 (RV64 OP-32) */
t_rori64:
  .word 0x63f3d313                 /* rori x6, x7, 63 (shamt[5] set) */
t_pack:
  .word 0x0815c533                 /* pack x10, x11, x1 (Zbkb; zext.h needs rs2 = 0) */
t_rev864:
  .word 0x6b85d593                 /* rev8 x11, x11, RV64 encoding */
t_clzw:
  .word 0x6005951b                 /* clzw x10, x11 (RV64 OP-IMM-32) */
t_czw:
  .word 0x0e65d53b                 /* czero.eqz in OP-32 (reserved) */

  /* ---------------- F. timing ---------------- */
  li   a2, 3
  li   a5, 4
  NORVC
  T3(1,  sh1add a0, a0, a2)
  T3(2,  sh2add a0, a0, a2)
  T3(3,  sh3add a0, a0, a2)
  T3(4,  andn a0, a0, a2)
  T3(5,  orn  a0, a0, a2)
  T3(6,  xnor a0, a0, a2)
  T3(7,  clz  a0, a0)
  T3(8,  ctz  a0, a0)
  T3(9,  cpop a0, a0)
  T3(10, max  a0, a0, a2)
  T3(11, maxu a0, a0, a2)
  T3(12, min  a0, a0, a2)
  T3(13, minu a0, a0, a2)
  T3(14, sext.b a0, a0)
  T3(15, sext.h a0, a0)
  T3(16, zext.h a0, a0)
  T3(17, rol  a0, a0, a5)
  T3(18, ror  a0, a0, a5)
  T3(19, rori a0, a0, 7)
  T3(20, orc.b a0, a0)
  T3(21, rev8 a0, a0)
  T3(22, bclr a0, a0, a2)
  T3(23, bclri a0, a0, 9)
  T3(24, bext a0, a0, a2)
  T3(25, bexti a0, a0, 1)
  T3(26, binv a0, a0, a2)
  T3(27, binvi a0, a0, 17)
  T3(28, bset a0, a0, a2)
  T3(29, bseti a0, a0, 30)
  T3(30, czero.eqz a0, a0, a2)
  T3(31, czero.nez a0, a0, a2)

  /* 32. load-use into a bit-manipulation instruction: lw 1 + stall 1 + clz 1 + end */
  la   t2, bdat
  .balign 4
  BLOCK(32, 4)
  lw   a0, 0(t2)
  clz  a0, a0
  END

  /* 33. result into a taken branch: bexti 1 + taken branch 3 + end */
  .balign 4
  BLOCK(33, 5)
  bexti a0, a1, 3
  bnez a0, 1f
  nop
  .balign 4
1:
  END

  /* 34. result into store data and into the next address: 3 + end */
  .balign 4
  BLOCK(34, 4)
  rev8 a0, a1
  sw   a0, 0(t2)
  sh2add t0, a2, t2
  END

  /* 35. 32-bit instructions at halfword offsets between compressed ones: 6 + end */
  .balign 4
  BLOCK(35, 7)
  .option push
  .option rvc
  c.nop
  sh1add a0, a1, a2
  c.mv   a3, a0
  clz    a4, a3
  c.add  a4, a3
  czero.nez a4, a4, a0
  .option pop
  END
  RVC
  PASS

  TRAPS(6)
  TRAP(CAUSE_ILLEGAL, t_adduw,  0x083100bb)
  TRAP(CAUSE_ILLEGAL, t_rori64, 0x63f3d313)
  TRAP(CAUSE_ILLEGAL, t_pack,   0x0815c533)
  TRAP(CAUSE_ILLEGAL, t_rev864, 0x6b85d593)
  TRAP(CAUSE_ILLEGAL, t_clzw,   0x6005951b)
  TRAP(CAUSE_ILLEGAL, t_czw,    0x0e65d53b)
