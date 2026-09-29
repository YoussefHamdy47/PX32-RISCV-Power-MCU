/* t06_traps: every synchronous exception the Phase 1 core raises, with cause, PC and
 * tval checked by the testbench against the TRAP table, plus precision checks: the
 * trapping instruction and everything after it have no effect.
 *
 * Until the CSR unit exists (step 1.6) the handler resumes at the address in s11. */
#include "px_test.h"

#define FAULT_ADDR 0x30000000           /* unmapped: bus error */

  .data
  .balign 4
tbuf: .word 0x600DF00D, 0x600DF00D, 0x600DF00D

  .text
  .globl test_main
test_main:
  .option norvc
  la   a0, tbuf

  /* 1. ECALL */
  EXPECT_TRAP(r1)
t_ecall:
  ecall
  j    fail_handler
r1:
  /* 2. EBREAK (32-bit) and 3. C.EBREAK */
  EXPECT_TRAP(r2)
t_ebreak:
  ebreak
  j    fail_handler
r2:
  EXPECT_TRAP(r3)
  .option push
  .option rvc
t_cebreak:
  c.ebreak
  .option pop
  j    fail_handler
r3:
  /* 4. Illegal 32-bit instruction: tval holds the instruction bits */
  EXPECT_TRAP(r4)
t_ill32:
  .word 0x80000033                    /* OP with funct7 1000000: reserved */
  j    fail_handler
r4:
  /* 5. Illegal compressed instruction (C.ADDI16SP with a zero immediate): tval holds
   *    the 16 original bits */
  EXPECT_TRAP(r5)
t_ill16:
  .half 0x6101
  .half 0x0001                        /* c.nop, keeps 4-byte alignment */
  j    fail_handler
r5:
  /* 6. Misaligned word load: rd keeps its old value */
  li   a1, 0x1234
  EXPECT_TRAP(r6)
t_lmis:
  lw   a1, 1(a0)
  j    fail_handler
r6:
  CHECK(1, a1, 0x1234)
  /* 7. Misaligned halfword store: memory unchanged */
  li   a2, 0xFFFF
  EXPECT_TRAP(r7)
t_smis:
  sh   a2, 1(a0)
  j    fail_handler
r7:
  lw   a3, 0(a0)
  CHECK(2, a3, 0x600DF00D)
  /* aligned halfword at offset 2 is legal */
  lh   a3, 2(a0)
  CHECK(3, a3, 0x600D)
  /* 8. Load access fault: rd unchanged, the store right behind it never happens */
  li   a1, 0x5678
  li   a4, FAULT_ADDR
  li   a5, 0xBAD
  EXPECT_TRAP(r8)
t_lacc:
  lw   a1, 0(a4)
  sw   a5, 4(a0)
  j    fail_handler
r8:
  CHECK(4, a1, 0x5678)
  lw   a3, 4(a0)
  CHECK(5, a3, 0x600DF00D)
  /* 9. Store access fault: the load behind it does not update rd */
  li   a6, 0x9999
  EXPECT_TRAP(r9)
t_sacc:
  sw   a5, 0(a4)
  lw   a6, 0(a0)
  j    fail_handler
r9:
  CHECK(6, a6, 0x9999)
  /* 10. A load fault is older than the ECALL behind it: only the load traps */
  EXPECT_TRAP(r10)
t_lacc2:
  lw   a1, 0(a4)
  ecall
  j    fail_handler
r10:
  /* 11. Instruction access fault: fetch from DTCM (not executable) */
  EXPECT_TRAP(r11)
  la   a7, tbuf
t_iacc_jump:
  jalr ra, 0(a7)
r11:
  NO_TRAP
  /* 12. Illegal instruction on the wrong path of a taken branch: no trap */
  beq  x0, x0, 1f
  .word 0x80000033
1:
  /* 13. Misaligned load on the wrong path of a JAL: no trap */
  jal  x0, 2f
  lw   a1, 1(a0)
2:
  PASS

  /* Expected traps, in order: cause, pc, tval */
  TRAPS(11)
  TRAP(CAUSE_ECALL_M, t_ecall,   0)
  TRAP(CAUSE_BREAK,   t_ebreak,  t_ebreak)
  TRAP(CAUSE_BREAK,   t_cebreak, t_cebreak)
  TRAP(CAUSE_ILLEGAL, t_ill32,   0x80000033)
  TRAP(CAUSE_ILLEGAL, t_ill16,   0x00006101)
  TRAP(CAUSE_LMISAL,  t_lmis,    tbuf + 1)
  TRAP(CAUSE_SMISAL,  t_smis,    tbuf + 1)
  TRAP(CAUSE_LACCESS, t_lacc,    FAULT_ADDR)
  TRAP(CAUSE_SACCESS, t_sacc,    FAULT_ADDR)
  TRAP(CAUSE_LACCESS, t_lacc2,   FAULT_ADDR)
  TRAP(CAUSE_IACCESS, tbuf,      tbuf)
