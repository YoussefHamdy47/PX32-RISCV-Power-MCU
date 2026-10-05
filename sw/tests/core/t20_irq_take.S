/* t20_irq_take: interrupt take point (Phase 2 step 2.2b, DECISIONS.md D-033;
 * PHASE2_VERIFICATION.md Ã‚Â§ 3.2). px-build: irq
 *
 * Built with PX_IRQ_RESUME: crt0 resumes after an interrupt at mepc (or at an armed
 * TF_IRQ_RESUME). Every run is checked afterwards by scripts/px_iss.py --replay (the
 * boundary of each take depends on memory timing), and tb_core checks the take point.
 *
 * Each sweep arms the testbench trigger (IRQTRIG) with a delay d = 0, 1, 2, ... and then
 * runs the same block, so in ideal mode the take lands on every instruction and pipeline
 * state of the block in turn; the block's results are checked after the interrupt (the
 * interrupted instruction runs again after the handler). Trigger word: [15:0] delay,
 * [21:16] id (also the mcause code), [27:24] expected latency in ideal mode (4, the
 * non-vectored budget of PHASE2_ARCHITECTURE.md Ã‚Â§ 4.9; 0 = not checked, used where MIE is
 * 0 when the request arrives or an exception comes first), bit 31 random extra delay.
 *   S1 control flow: ALU, JAL in ID, taken branch, JALR, FENCE.I, JAL with link
 *   S2 loads and stores (the request of a memory instruction in EX is withheld)
 *   S3 multiplies (stage 1 not loaded in the take cycle)
 *   S4 three dependent divides (killed at every one of their 17 cycles, rerun afterwards)
 *   S5 CSR instructions in EX
 *   S6 MRET in flight (MIE = 1 while mepc is set: the test arms TF_IRQ_RESUME)
 *   S7 request while MIE = 0: no take; taken right after MIE is set
 *   S8 request arriving around an ECALL: the exception first, the interrupt after its
 *      handler (MIE = 0 inside the handler)
 *   S9 S1 again with a random extra delay (stall modes: random take points)
 *   S10 request around a load access fault: the older access's bus error first
 * The bench also requires every deferral cause to occur (WB bus error: S10; exception in
 * EX: S8; older access and ungranted request: the stall modes) and checks that no take
 * wins over an exception (contract Ã‚Â§ 2.3).
 */
#define FAULT_ADDR 0x30000000             /* unmapped in tb_core: access fault */
#include "px_test.h"

#define TRIG(id, lat)   (((lat) << 24) | ((id) << 16))
/* arm the trigger with the delay in register dreg; s1 counts the interrupts expected */
#define ARM_D(id, lat, dreg) \
  li t5, TRIG(id, lat); or t5, t5, dreg; li t6, IRQTRIG; sw t5, 0(t6); addi s1, s1, 1
#define ARM_X(val) \
  li t5, val; li t6, IRQTRIG; sw t5, 0(t6); addi s1, s1, 1
/* wait (bounded) until s1 interrupts have been taken; fail as test n otherwise */
#define WAIT_IRQS(n) \
  li gp, n; li t3, 400; \
  9993: li t4, TRAP_FRAME; lw t4, TF_IRQS(t4); beq t4, s1, 9994f; \
  addi t3, t3, -1; bnez t3, 9993b; j fail_handler; 9994:

  .data
  .balign 4
buf: .word 0, 0, 0, 0

  .text
  .globl test_main
test_main:
  li   s1, 0                      /* interrupts expected so far */
  csrsi mstatus, 8                /* MIE = 1 */

  /* ---- S1: control flow, d = 0..23 ---- */
  li   s0, 0
s1_loop:
  ARM_D(3, 4, s0)
  li   a0, 1
  addi a0, a0, 2
  slli a0, a0, 1                  /* 6 */
  j    1f                         /* JAL resolved in ID */
  li   a0, 999
1:
  beq  a0, a0, 2f                 /* taken branch */
  li   a0, 998
2:
  la   a1, 3f
  jalr x0, 0(a1)                  /* JALR */
  li   a0, 997
3:
  fence.i
  addi a0, a0, 1                  /* 7 */
  jal  ra, 4f                     /* JAL with a link */
4:
  addi a0, a0, 1                  /* 8 */
  WAIT_IRQS(1)
  CHECK(2, a0, 8)
  addi s0, s0, 1
  li   t0, 24
  blt  s0, t0, s1_loop

  /* ---- S2: loads and stores, d = 0..15 ---- */
  li   s0, 0
s2_loop:
  ARM_D(5, 4, s0)
  la   a2, buf
  sw   s0, 0(a2)
  lw   a3, 0(a2)
  sb   a3, 5(a2)
  lbu  a4, 5(a2)
  sh   a4, 8(a2)
  lh   a5, 8(a2)
  add  a6, a3, a5                 /* 2 * d */
  sw   a6, 12(a2)
  lw   a7, 12(a2)
  WAIT_IRQS(3)
  slli t0, s0, 1
  CHECK_REG(4, a7, t0)
  addi s0, s0, 1
  li   t0, 16
  blt  s0, t0, s2_loop

  /* ---- S3: multiplies, d = 0..10 ---- */
  li   s0, 0
s3_loop:
  ARM_D(7, 4, s0)
  li   a0, 7
  mul  a1, a0, s0                 /* 7d */
  mul  a2, a1, a0                 /* 49d */
  mulhu a3, a2, a0                /* 0 */
  add  a4, a2, a3
  WAIT_IRQS(5)
  slli t0, s0, 5
  slli t1, s0, 4
  add  t0, t0, t1
  add  t0, t0, s0                 /* 49d */
  CHECK_REG(6, a4, t0)
  addi s0, s0, 1
  li   t0, 11
  blt  s0, t0, s3_loop

  /* ---- S4: divides, d = 0..56 (every cycle of each divide) ---- */
  li   s0, 0
s4_loop:
  ARM_D(9, 4, s0)
  li   a0, 1000003
  li   a1, 7
  div  a2, a0, a1                 /* 142857 */
  rem  a3, a0, a1                 /* 4 */
  divu a4, a2, a1                 /* 20408 */
  add  a5, a3, a4                 /* 20412 */
  WAIT_IRQS(7)
  CHECK(8, a2, 142857)
  CHECK(9, a5, 20412)
  addi s0, s0, 1
  li   t0, 57
  blt  s0, t0, s4_loop

  /* ---- S5: CSR instructions, d = 0..10 ---- */
  li   s0, 0
s5_loop:
  ARM_D(11, 4, s0)
  csrr a0, misa
  csrw mie, s0                    /* read-only zero: the write is ignored */
  csrrw a1, minstreth, zero
  csrr a2, mie
  csrrs a3, mstatush, zero
  WAIT_IRQS(10)
  CHECK(11, a0, 0x40001106)
  CHECK(12, a2, 0)
  CHECK(13, a3, 0)
  addi s0, s0, 1
  li   t0, 11
  blt  s0, t0, s5_loop

  /* ---- S6: MRET in flight, d = 0..15 ---- */
  li   s0, 0
s6_loop:
  csrci mstatus, 8                /* MIE = 0 while mepc is set */
  la   t0, 5f
  csrw mepc, t0
  li   t1, TRAP_FRAME
  sw   t0, TF_IRQ_RESUME(t1)      /* an interrupt before the MRET resumes at 5f */
  ARM_D(13, 0, s0)
  li   t0, 0x88
  csrs mstatus, t0                /* MPIE = 1, MIE = 1: interrupts possible from here */
  nop
  nop
  mret
  j    fail_handler
5:
  li   t1, TRAP_FRAME
  sw   zero, TF_IRQ_RESUME(t1)
  WAIT_IRQS(14)
  csrr a0, mstatus
  CHECK(15, a0, 0x1888)           /* MPP = M, MPIE = 1, MIE = 1 */
  addi s0, s0, 1
  li   t0, 16
  blt  s0, t0, s6_loop

  /* ---- S7: request while MIE = 0 ---- */
  csrci mstatus, 8
  ARM_X(TRIG(15, 0))
  li   t3, 30
1:
  addi t3, t3, -1
  bnez t3, 1b
  li   t4, TRAP_FRAME
  lw   t4, TF_IRQS(t4)
  addi t0, s1, -1
  CHECK_REG(16, t4, t0)           /* not taken while MIE = 0 */
  csrsi mstatus, 8
  WAIT_IRQS(17)
  li   t4, TRAP_FRAME
  lw   t4, TF_IRQ_ID(t4)
  CHECK(18, t4, 0x8000000F)       /* mcause: interrupt bit, code = id 15 */

  /* ---- S8: request around an ECALL, d = 0..11 ---- */
  li   s0, 0
s8_loop:
  ARM_D(17, 0, s0)
  nop                             /* the request becomes visible 2 + d cycles after
  nop                                the trigger store retires: the delays cross the
  nop                                cycle in which the ECALL is in EX */
  nop
  nop
  nop
s8_ecall:
  ecall                           /* crt0 skips it; the interrupt waits for its MRET */
  WAIT_IRQS(19)
  addi s0, s0, 1
  li   t0, 12
  blt  s0, t0, s8_loop

  /* ---- S9: S1 with a random extra delay (bit 31), 20 times ---- */
  li   s0, 0
s9_loop:
  li   t0, 7
  and  t2, s0, t0
  ARM_D(19 | 0x8000, 4, t2)       /* id 19, bit 31 of the trigger word: random extra delay */
  li   a0, 1
  addi a0, a0, 2
  slli a0, a0, 1
  j    1f
  li   a0, 999
1:
  beq  a0, a0, 2f
  li   a0, 998
2:
  la   a1, 3f
  jalr x0, 0(a1)
  li   a0, 997
3:
  fence.i
  addi a0, a0, 1
  jal  ra, 4f
4:
  addi a0, a0, 1
  WAIT_IRQS(20)
  CHECK(21, a0, 8)
  addi s0, s0, 1
  li   t0, 20
  blt  s0, t0, s9_loop

  /* ---- S10: request around a load access fault, d = 0..5 (the older bus error first) ---- */
  li   s0, 0
s10_loop:
  ARM_D(21, 0, s0)
  li   a0, FAULT_ADDR
  addi a1, a1, 1
  addi a1, a1, 1
s10_load:
  lw   a2, 0(a0)                  /* bus error in WB; crt0 skips the load */
  addi a1, a1, 1
  addi a1, a1, 1
  WAIT_IRQS(22)
  addi s0, s0, 1
  li   t0, 6
  blt  s0, t0, s10_loop

  /* every armed request was taken exactly once */
  li   t4, TRAP_FRAME
  lw   t4, TF_IRQS(t4)
  CHECK_REG(23, t4, s1)
  li   t0, 174                    /* 24 + 16 + 11 + 57 + 11 + 16 + 1 + 12 + 20 + 6 */
  CHECK_REG(24, s1, t0)
  PASS

  TRAPS(18)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_ECALL_M, s8_ecall, 0)
  TRAP(CAUSE_LACCESS, s10_load, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, s10_load, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, s10_load, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, s10_load, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, s10_load, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, s10_load, FAULT_ADDR)
