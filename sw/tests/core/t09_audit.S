/* t09_audit: cases added by the pre-1.6 audit.
 *   A. fetch faults at the end of ITCM: on the second half of a straddling 32-bit
 *      instruction (after a redirect and in sequence), on the first word, and faulting
 *      prefetches on the wrong path that must be dropped
 *   B. wrong-path and flushed accesses to a side-effect device: none may reach the bus
 *   C. an older bus error in WB coinciding with a younger branch, JAL, JALR, exception,
 *      FENCE.I or access
 *   D. forwarding into branches, JALR bases, store address/data, from JAL/JALR links, and
 *      x0 destinations
 *   E. consecutive redirects: EX redirect against JAL in ID, redirect chains, FENCE.I
 *
 * The traps are listed at the end; the testbench also compares every retirement with
 * the reference model. */
#include "px_test.h"

#define FAULT_ADDR 0x30000000
#define DEV        0x20010000          /* word 0: read counter; word 1: write counter */
#define ITCM_LAST  0x1000FFFC          /* last word of ITCM */

  .data
  .balign 4
abuf: .word 0x11111111, 0x22222222, 0x33333333, 0x44444444
aptr: .word 0

  .text
  .globl test_main
test_main:
  .option norvc
  la   s0, abuf
  li   s1, DEV
  li   s2, FAULT_ADDR
  li   s3, ITCM_LAST

  /* ---------------- A. fetch faults at the end of ITCM ---------------- */
  /* A1: 32-bit instruction at 0x1000FFFE, reached by a jump; its second half is outside
   *     ITCM. mtval is the address of the faulting half (0x10010000), mepc the start. */
  li   t0, 0x05130001                  /* c.nop | low half of addi a0, x0, ... */
  sw   t0, 0(s3)
  fence.i
  EXPECT_TRAP(ra1)
  addi t1, s3, 2
  jalr x0, 0(t1)
ra1:
  /* A2: the same instruction reached in sequence, after the c.nop at 0x1000FFFC */
  EXPECT_TRAP(ra2)
  jalr x0, 0(s3)
ra2:
  /* A3: two c.nops, then the next fetch (0x10010000) faults on its first word */
  li   t0, 0x00010001
  sw   t0, 0(s3)
  fence.i
  EXPECT_TRAP(ra3)
  jalr x0, 0(s3)
ra3:
  NO_TRAP
  /* A4: c.nop; c.jr ra at the end of ITCM: the prefetch of 0x10010000 faults but is on
   *     the wrong path and must be dropped */
  li   t0, 0x80820001                  /* c.jr ra | c.nop */
  sw   t0, 0(s3)
  fence.i
  la   ra, ra4
  jalr x0, 0(s3)
  j    fail_handler
ra4:
  /* A5: a 32-bit JALR filling the last word, same wrong-path prefetch */
  li   t0, 0x00008067                  /* jalr x0, 0(ra) */
  sw   t0, 0(s3)
  fence.i
  la   ra, ra5
  jalr x0, 0(s3)
  j    fail_handler
ra5:

  /* ---------------- B. wrong-path accesses to the side-effect device ---------------- */
  lw   a0, 0(s1)                       /* first architectural read: returns 0 */
  CHECK(1, a0, 0)
  /* after a taken branch */
  beq  x0, x0, 1f
  lw   a0, 0(s1)
  sw   a0, 4(s1)
1:
  /* after JAL */
  jal  x0, 2f
  lw   a0, 0(s1)
  sw   a0, 4(s1)
2:
  /* after JALR */
  la   t0, 3f
  jalr x0, 0(t0)
  lw   a0, 0(s1)
  sw   a0, 4(s1)
3:
  /* after a taken branch whose operands are forwarded */
  li   t1, 5
  li   t2, 5
  beq  t1, t2, 4f
  lw   a0, 0(s1)
  sw   a0, 4(s1)
4:
  /* after a trapping ECALL */
  EXPECT_TRAP(rb1)
tb_ecall:
  ecall
  lw   a0, 0(s1)
  sw   a0, 4(s1)
  j    fail_handler
rb1:
  /* after an illegal instruction */
  EXPECT_TRAP(rb2)
tb_ill:
  .word 0x80000033
  lw   a0, 0(s1)
  sw   a0, 4(s1)
  j    fail_handler
rb2:
  /* after a misaligned load */
  EXPECT_TRAP(rb3)
tb_mis:
  lw   a1, 1(s0)
  lw   a0, 0(s1)
  sw   a0, 4(s1)
  j    fail_handler
rb3:
  /* after a load that gets a bus error */
  EXPECT_TRAP(rb4)
tb_lacc:
  lw   a1, 0(s2)
  lw   a0, 0(s1)
  sw   a0, 4(s1)
  j    fail_handler
rb4:
  /* after a store that gets a bus error */
  EXPECT_TRAP(rb5)
tb_sacc:
  sw   a1, 0(s2)
  sw   a0, 4(s1)
  lw   a0, 0(s1)
  j    fail_handler
rb5:
  NO_TRAP
  /* on the correct path right after FENCE.I: exactly once */
  fence.i
  lw   a0, 0(s1)                       /* second architectural read: returns 1 */
  CHECK(2, a0, 1)
  lw   a0, 4(s1)                       /* no write reached the device */
  CHECK(3, a0, 0)
  sw   a0, 4(s1)                       /* one architectural write */
  lw   a0, 4(s1)
  CHECK(4, a0, 1)
  lw   a0, 0(s1)                       /* third read: returns 2 */
  CHECK(5, a0, 2)

  /* ---------------- C. older bus error against younger events ---------------- */
  li   ra, 0x1111
  /* load error in WB, taken branch in EX */
  EXPECT_TRAP(rc1)
tc_br:
  lw   a1, 0(s2)
  beq  x0, x0, fail_handler_far
  j    fail_handler
rc1:
  /* load error in WB, JAL behind it (resolved in ID while the load was in EX) */
  EXPECT_TRAP(rc2)
tc_jal:
  lw   a1, 0(s2)
  jal  ra, fail_handler_far
  j    fail_handler
rc2:
  CHECK(6, ra, 0x1111)
  /* store error in WB, JAL in ID */
  EXPECT_TRAP(rc3)
tc_sjal:
  sw   a1, 0(s2)
  nop
  jal  ra, fail_handler_far
  j    fail_handler
rc3:
  CHECK(7, ra, 0x1111)
  /* load error, JALR behind it */
  la   t0, fail_handler_far
  EXPECT_TRAP(rc4)
tc_jalr:
  lw   a1, 0(s2)
  jalr ra, 0(t0)
  j    fail_handler
rc4:
  CHECK(8, ra, 0x1111)
  /* store error, illegal instruction behind it: only the store traps */
  EXPECT_TRAP(rc5)
tc_ill:
  sw   a1, 0(s2)
  .word 0x80000033
  j    fail_handler
rc5:
  /* load error, misaligned store behind it: only the load traps, memory unchanged */
  EXPECT_TRAP(rc6)
tc_mis:
  lw   a1, 0(s2)
  sw   a1, 1(s0)
  j    fail_handler
rc6:
  lw   a0, 0(s0)
  CHECK(9, a0, 0x11111111)
  /* load error, FENCE.I behind it */
  EXPECT_TRAP(rc7)
tc_fi:
  lw   a1, 0(s2)
  fence.i
  j    fail_handler
rc7:
  /* load error, second access behind it to good memory: not performed */
  li   a2, 0x77
  EXPECT_TRAP(rc8)
tc_acc:
  lw   a1, 0(s2)
  sw   a2, 4(s0)
  j    fail_handler
rc8:
  NO_TRAP
  lw   a0, 4(s0)
  CHECK(10, a0, 0x22222222)

  /* ---------------- D. forwarding ---------------- */
  /* branch operands from distance 1 (both) and distance 2 */
  li   a0, 3
  li   a1, 3
  bne  a0, a1, fail_handler_far
  li   a0, 4
  nop
  li   a1, 4
  bne  a0, a1, fail_handler_far
  /* branch operand from a load (load-use) on rs2 */
  li   a0, 0x11111111
  lw   a1, 0(s0)
  bne  a0, a1, fail_handler_far
  /* JALR base from the ALU at distance 1 */
  la   t0, 5f
  jalr ra, 0(t0)
  j    fail_handler
5:
  /* JALR base from a load (load-use) */
  la   t0, 6f
  sw   t0, 0(s0)
  lw   t1, 0(s0)
  jalr ra, 0(t1)
  j    fail_handler
6:
  /* JAL link used by the next instruction, by a store, and as a JALR base */
  jal  ra, 7f
7:
  la   t0, 7b
  CHECK_REG(11, ra, t0)
  jal  ra, 8f
8:
  sw   ra, 8(s0)
  lw   t1, 8(s0)
  la   t0, 8b
  CHECK_REG(12, t1, t0)
  jal  ra, 9f
  j    fail_handler                    /* ra points here */
9:
  jalr x0, 12(ra)                      /* to ra + 12: past the j below */
  j    fail_handler
  /* JALR link used next */
  la   t0, 10f
  jalr ra, 0(t0)
10:
  la   t1, 10b
  CHECK_REG(13, ra, t1)
  /* store address from LUI at distance 1 (data at distance 2), store data from AUIPC */
  lui  t1, 0xABCDE
  lui  t0, %hi(abuf + 12)
  sw   t1, %lo(abuf + 12)(t0)
  lw   t2, 12(s0)
  CHECK(14, t2, 0xABCDE000)
td_auipc:
  auipc t2, 0
  sw   t2, 12(s0)
  lw   t1, 12(s0)
  la   t0, td_auipc
  CHECK_REG(21, t1, t0)
  /* x0 destinations are never forwarded */
  li   a0, 9
  addi x0, a0, 5
  add  a1, x0, x0
  CHECK(15, a1, 0)
  lw   x0, 0(s0)
  add  a1, x0, x0
  CHECK(16, a1, 0)
  /* newest of two producers wins, with write-through on the other operand */
  li   a0, 1
  li   a0, 2
  add  a1, a0, a0
  CHECK(17, a1, 4)

  /* ---------------- E. consecutive redirects ---------------- */
  li   ra, 0x2222
  /* taken branch in EX, JAL in ID: the branch wins, JAL leaves no link */
  beq  x0, x0, 11f
  jal  ra, fail_handler_far
11:
  CHECK(18, ra, 0x2222)
  /* JALR in EX, JAL in ID */
  la   t0, 12f
  jalr x0, 0(t0)
  jal  ra, fail_handler_far
12:
  CHECK(19, ra, 0x2222)
  /* chain: taken branch -> taken branch -> JAL -> JALR */
  la   t0, 15f
  beq  x0, x0, 13f
  j    fail_handler
13:
  beq  x0, x0, 14f
  j    fail_handler
14:
  jal  x0, 16f
  j    fail_handler
16:
  jalr x0, 0(t0)
  j    fail_handler
15:
  /* FENCE.I followed by JAL, by a taken branch, and by another FENCE.I */
  fence.i
  jal  x0, 17f
  j    fail_handler
17:
  fence.i
  beq  x0, x0, 18f
  j    fail_handler
18:
  fence.i
  fence.i
  li   a0, 1
  CHECK(20, a0, 1)
  PASS

  /* far target for wrong-path jumps (reaching it is a failure) */
fail_handler_far:
  j    fail_handler

  TRAPS(16)
  TRAP(CAUSE_IACCESS, 0x1000FFFE, 0x10010000)
  TRAP(CAUSE_IACCESS, 0x1000FFFE, 0x10010000)
  TRAP(CAUSE_IACCESS, 0x10010000, 0x10010000)
  TRAP(CAUSE_ECALL_M, tb_ecall,   0)
  TRAP(CAUSE_ILLEGAL, tb_ill,     0x80000033)
  TRAP(CAUSE_LMISAL,  tb_mis,     abuf + 1)
  TRAP(CAUSE_LACCESS, tb_lacc,    FAULT_ADDR)
  TRAP(CAUSE_SACCESS, tb_sacc,    FAULT_ADDR)
  TRAP(CAUSE_LACCESS, tc_br,      FAULT_ADDR)
  TRAP(CAUSE_LACCESS, tc_jal,     FAULT_ADDR)
  TRAP(CAUSE_SACCESS, tc_sjal,    FAULT_ADDR)
  TRAP(CAUSE_LACCESS, tc_jalr,    FAULT_ADDR)
  TRAP(CAUSE_SACCESS, tc_ill,     FAULT_ADDR)
  TRAP(CAUSE_LACCESS, tc_mis,     FAULT_ADDR)
  TRAP(CAUSE_LACCESS, tc_fi,      FAULT_ADDR)
  TRAP(CAUSE_LACCESS, tc_acc,     FAULT_ADDR)
