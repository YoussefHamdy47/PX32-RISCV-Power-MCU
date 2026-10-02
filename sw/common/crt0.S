/* crt0.S: startup and trap handler for PX32 core tests (Phase 1, step 1.6).
 *
 * Reset enters at 0x1000_0000. Startup points mtvec at trap_entry (0x1000_0040, also the
 * core's mtvec reset value in tb_core) and mscratch at the handler frame, then calls
 * test_main.
 *
 * Trap handler (machine mode, Direct mtvec). It swaps sp with mscratch, saves t0-t2,
 * records mcause, mepc, mtval and mstatus in the frame and counts the trap, then chooses
 * the recovery PC:
 *   1. a recovery address armed by the test (EXPECT_TRAP), used once and cleared;
 *   2. otherwise, for a synchronous exception whose instruction was fetched (every cause
 *      except an instruction access fault), the instruction after the trapping one:
 *      mepc + 2 or + 4, from the length bits of the instruction at mepc;
 *   3. an instruction access fault without a recovery address, or an interrupt (none
 *      exist before Phase 2), cannot be resumed: the test fails as test 2047.
 * It then restores the registers and returns with MRET. The testbench records and checks
 * every trap on the core's trap port as well. */
#include "px_test.h"

  .section .text.init, "ax"
  .option norvc
  .globl _start
_start:
  la   t0, trap_entry
  csrw mtvec, t0
  li   t0, TRAP_FRAME
  csrw mscratch, t0
  sw   zero, TF_COUNT(t0)
  sw   zero, TF_RESUME(t0)
  li   gp, 0
  j    test_main

  .balign 64                     /* 0x1000_0040: trap vector */
  .globl trap_entry
trap_entry:
  csrrw sp, mscratch, sp         /* sp = frame, mscratch = interrupted sp */
  sw   t0, TF_T0(sp)
  sw   t1, TF_T1(sp)
  sw   t2, TF_T2(sp)
  csrr t0, mcause
  csrr t1, mepc
  csrr t2, mtval
  sw   t0, TF_CAUSE(sp)
  sw   t1, TF_EPC(sp)
  sw   t2, TF_TVAL(sp)
  csrr t2, mstatus
  sw   t2, TF_MSTATUS(sp)
  lw   t2, TF_COUNT(sp)
  addi t2, t2, 1
  sw   t2, TF_COUNT(sp)
  bltz t0, trap_fatal            /* interrupt: none exist before Phase 2 */
  lw   t2, TF_RESUME(sp)
  bnez t2, trap_resume           /* 1. armed recovery address */
  li   t2, CAUSE_IACCESS
  beq  t0, t2, trap_fatal        /* 3. fetch fault: nothing to skip */
  lhu  t2, 0(t1)                 /* 2. skip the trapping instruction */
  andi t2, t2, 3
  addi t1, t1, 2
  addi t2, t2, -3
  bnez t2, 1f
  addi t1, t1, 2
1:
  csrw mepc, t1
  j    trap_return
trap_resume:
  sw   zero, TF_RESUME(sp)
  csrw mepc, t2
trap_return:
  lw   t0, TF_T0(sp)
  lw   t1, TF_T1(sp)
  lw   t2, TF_T2(sp)
  csrrw sp, mscratch, sp
  mret

trap_fatal:
  li   gp, 0x7FF                 /* reported as test 2047: a trap nobody can resume */
  j    fail_handler

  .globl pass_handler
pass_handler:
  li   t0, TOHOST
  li   t1, 1
  sw   t1, 0(t0)
1: j 1b

  .globl fail_handler
fail_handler:                    /* tohost = ((gp + 1) << 1) | 1: never 1 (PASS) */
  li   t0, TOHOST
  addi t1, gp, 1
  slli t1, t1, 1
  ori  t1, t1, 1
  sw   t1, 0(t0)
1: j 1b
