/* t11_trap_mret: trap entry state and MRET (step 1.6).
 *   A. trap entry: mcause, mepc, mtval and mstatus (MPIE = MIE, MIE = 0, MPP = M) as seen
 *      by the handler, for MIE = 0 and 1; the handler's MRET restores MIE; mepc of a
 *      16-bit instruction; the handler resumes after 2- and 4-byte instructions
 *   B. MRET: immediately after writing mepc or mstatus; all MIE/MPIE combinations;
 *      halfword-aligned 16- and 32-bit targets; mepc bit 0; MRET on the wrong path,
 *      behind a trapping instruction and behind an older bus error has no effect
 *   C. a new mtvec is used by a trap in the very next instruction; mstatus written just
 *      before a trap is the one saved in MPIE
 *   D. instruction access faults: recovery through an armed address (not by skipping);
 *      MRET to an unmapped address faults with mepc = mtval = that address
 *   E. an older load/store bus error in WB beats a younger illegal CSR access
 * The traps are listed at the end; the testbench also compares every retirement with the
 * reference model. */
#include "px_test.h"

#define FAULT_ADDR 0x30000000

  .data
  .balign 4
tbuf: .word 0x600DF00D, 0x11111111, 0x22222222, 0x33333333

  .text
  .globl test_main
test_main:
  .option norvc
  la   s0, tbuf
  li   s2, FAULT_ADDR
  li   s8, 0
  li   s9, 0

  /* ---------------- A. trap entry ---------------- */
t_a1:
  ecall                                /* MIE = 0 */
  CHECK_TRAP(1, TF_CAUSE, CAUSE_ECALL_M)
  CHECK_TRAP_AT(2, TF_EPC, t_a1)
  CHECK_TRAP(3, TF_TVAL, 0)
  CHECK_TRAP(4, TF_MSTATUS, 0x1800)
  csrr a0, mstatus
  CHECK(5, a0, 0x1880)                 /* after MRET: MIE = old MPIE = 0, MPIE = 1 */
  csrr a0, mcause                      /* the CSRs keep the trap values after MRET */
  CHECK(6, a0, CAUSE_ECALL_M)
  csrsi mstatus, 8                     /* MIE = 1 */
t_a2:
  ebreak
  CHECK_TRAP(7, TF_MSTATUS, 0x1880)    /* MPIE = 1, MIE = 0 */
  CHECK_TRAP_AT(8, TF_TVAL, t_a2)
  csrr a0, mstatus
  CHECK(9, a0, 0x1888)                 /* MIE restored */
  csrci mstatus, 8
  .option push
  .option rvc
t_a3:
  c.ebreak                             /* 16-bit: the handler resumes at +2 */
  c.nop
  .option pop
  CHECK_TRAP_AT(10, TF_EPC, t_a3)
  CHECK_TRAP(11, TF_CAUSE, CAUSE_BREAK)
t_a4:
  lw   a1, 2(s0)                       /* misaligned load */
  CHECK_TRAP_AT(12, TF_TVAL, tbuf + 2)
  CHECK_TRAP(13, TF_CAUSE, CAUSE_LMISAL)
  .option push
  .option rvc
  c.nop
t_a5:
  .half 0x0000                         /* illegal 16-bit word at a halfword offset */
  .option pop
  CHECK_TRAP(14, TF_TVAL, 0)
  CHECK_TRAP_AT(15, TF_EPC, t_a5)
  csrr a0, mtval
  CHECK(16, a0, 0)
  csrr a0, mepc
  la   a1, t_a5 + 2                    /* the handler advanced mepc by 2 */
  CHECK_REG(17, a0, a1)

  /* ---------------- B. MRET ---------------- */
  la   a0, b1
  csrw mepc, a0
  mret                                 /* MRET right after the mepc write */
  j    fail_handler
b1:
  csrr a0, mstatus
  CHECK(20, a0, 0x1888)                /* MPIE was 1 (left by the last handler MRET) */
  /* the four MIE/MPIE combinations, mstatus written just before MRET */
  la   a0, b2
  csrw mepc, a0
  csrwi mstatus, 0                     /* MPIE = 0, MIE = 0 */
  mret
  j    fail_handler
b2:
  csrr a0, mstatus
  CHECK(21, a0, 0x1880)
  la   a0, b3
  csrw mepc, a0
  csrwi mstatus, 8                     /* MPIE = 0, MIE = 1 */
  mret
  j    fail_handler
b3:
  csrr a0, mstatus
  CHECK(22, a0, 0x1880)
  la   a0, b4
  csrw mepc, a0
  li   a1, 0x80                        /* MPIE = 1, MIE = 0 */
  csrw mstatus, a1
  mret
  j    fail_handler
b4:
  csrr a0, mstatus
  CHECK(23, a0, 0x1888)
  la   a0, b5
  csrw mepc, a0
  li   a1, 0x88                        /* MPIE = 1, MIE = 1 */
  csrw mstatus, a1
  mret
  j    fail_handler
b5:
  csrr a0, mstatus
  CHECK(24, a0, 0x1888)
  csrwi mstatus, 0
  /* halfword-aligned targets: a 16-bit and a 32-bit instruction */
  la   a0, b6
  csrw mepc, a0
  mret
  j    fail_handler
  .option push
  .option rvc
  c.nop
b6:
  c.li a2, 6                           /* 16-bit target at a halfword offset */
  .option pop
  la   a0, b7
  csrw mepc, a0
  mret
  j    fail_handler
  .option push
  .option rvc
  .balign 4
  c.nop
  .option pop
b7:
  addi a3, x0, 7                       /* 32-bit target at a halfword offset */
  CHECK(25, a2, 6)
  CHECK(26, a3, 7)
  /* mepc bit 0 cannot be set */
  la   a0, b8
  csrw mepc, a0
  csrsi mepc, 1
  mret
  j    fail_handler
b8:
  csrr a0, mepc
  la   a1, b8
  CHECK_REG(27, a0, a1)
  /* MRET on the wrong path, behind a trap and behind an older bus error: no effect */
  la   a0, fail_handler
  csrw mepc, a0
  csrwi mstatus, 8                     /* MIE = 1, MPIE = 0: an MRET would clear MIE */
  beq  x0, x0, 1f
  mret
1:
  jal  x0, 2f
  mret
2:
  csrr a0, mstatus
  CHECK(28, a0, 0x1808)
  csrwi mstatus, 0
  EXPECT_TRAP(3f)
t_b_ecall:
  ecall
  mret
3:
  EXPECT_TRAP(4f)
t_b_lacc:
  lw   a0, 0(s2)
  mret
4:
  EXPECT_TRAP(5f)
t_b_sacc:
  sw   a0, 0(s2)
  mret
5:
  CHECK_TRAP(29, TF_CAUSE, CAUSE_SACCESS)

  /* ---------------- C. mtvec and mstatus just before a trap ---------------- */
  csrr s1, mtvec
  la   a0, alt_vector
  csrw mtvec, a0
t_c1:
  ecall                                /* taken through the new vector */
  csrw mtvec, s1
  CHECK(30, s8, 1)
  la   a1, t_c1 + 4
  CHECK_REG(31, s9, a1)
  csrr a0, mcause
  CHECK(32, a0, CAUSE_ECALL_M)
  csrsi mstatus, 8
t_c2:
  ecall                                /* MPIE takes the MIE written just before */
  CHECK_TRAP(33, TF_MSTATUS, 0x1880)
  csrci mstatus, 8
  li   a0, 0x5555
  csrw mtval, a0
t_c3:
  csrr a1, mtval                       /* read right after the write, then a trap */
  ebreak
  CHECK(34, a1, 0x5555)
  csrr a0, mtval
  la   a1, t_c3 + 4
  CHECK_REG(35, a0, a1)

  /* ---------------- D. instruction access faults ---------------- */
  EXPECT_TRAP(d1)
t_d0:
  la   a7, tbuf
t_d1:
  jalr ra, 0(a7)                       /* fetch from DTCM: not executable */
d1:
  CHECK_TRAP(40, TF_CAUSE, CAUSE_IACCESS)
  CHECK_TRAP_AT(41, TF_EPC, tbuf)
  CHECK_TRAP_AT(42, TF_TVAL, tbuf)
  csrw mepc, s2
  EXPECT_TRAP(d2)
  mret                                 /* MRET to an unmapped address */
d2:
  CHECK_TRAP(43, TF_EPC, FAULT_ADDR)
  CHECK_TRAP(44, TF_TVAL, FAULT_ADDR)

  /* ---------------- E. older bus error against a younger illegal CSR access ------------- */
  EXPECT_TRAP(e1)
t_e0:
  lw   a0, 0(s2)
  csrw mhartid, a0                     /* illegal, but younger: never reported */
e1:
  EXPECT_TRAP(e2)
t_e1:
  sw   a0, 0(s2)
  csrw 0x7C0, a0                       /* unimplemented */
e2:
  CHECK_TRAP(45, TF_COUNT, 14)          /* t_c1 went to alt_vector */
  PASS

  .balign 4
alt_vector:                            /* second handler: counts and skips a 4-byte ECALL */
  addi s8, s8, 1
  csrr s9, mepc
  addi s9, s9, 4
  csrw mepc, s9
  mret

  TRAPS(15)
  TRAP(CAUSE_ECALL_M, t_a1, 0)
  TRAP(CAUSE_BREAK,   t_a2, t_a2)
  TRAP(CAUSE_BREAK,   t_a3, t_a3)
  TRAP(CAUSE_LMISAL,  t_a4, tbuf + 2)
  TRAP(CAUSE_ILLEGAL, t_a5, 0)
  TRAP(CAUSE_ECALL_M, t_b_ecall, 0)
  TRAP(CAUSE_LACCESS, t_b_lacc, FAULT_ADDR)
  TRAP(CAUSE_SACCESS, t_b_sacc, FAULT_ADDR)
  TRAP(CAUSE_ECALL_M, t_c1, 0)
  TRAP(CAUSE_ECALL_M, t_c2, 0)
  TRAP(CAUSE_BREAK,   t_c3 + 4, t_c3 + 4)
  TRAP(CAUSE_IACCESS, tbuf, tbuf)
  TRAP(CAUSE_IACCESS, FAULT_ADDR, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, t_e0, FAULT_ADDR)
  TRAP(CAUSE_SACCESS, t_e1, FAULT_ADDR)
