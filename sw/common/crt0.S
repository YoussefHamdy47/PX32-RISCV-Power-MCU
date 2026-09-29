/* crt0.S: startup and harness code for PX32 core tests (Phase 1).
 *
 * Reset enters at 0x1000_0000. The core's trap vector input is tied to 0x1000_0040 by
 * the core testbench; until the CSR unit exists (step 1.6) the handler cannot read
 * mepc/mcause, so it resumes at the address the test placed in s11. The testbench
 * records and checks every trap itself. */
#include "px_test.h"

  .section .text.init, "ax"
  .option norvc
  .globl _start
_start:
  la   s11, unexpected_trap
  li   gp, 0
  j    test_main

  .balign 64                     /* 0x1000_0040: trap vector */
trap_entry:
  jr   s11

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

  .globl unexpected_trap
unexpected_trap:
  li   gp, 0x7FF                 /* reported as test 2047: a trap nobody expected */
  j    fail_handler
