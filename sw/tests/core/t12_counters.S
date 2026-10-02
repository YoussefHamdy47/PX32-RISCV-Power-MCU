/* t12_counters: minstret and mcycle (step 1.6, D-022).
 *   A. minstret counts retired instructions only: consecutive reads (the older read
 *      retires in WB in the same cycle), a load in between (held in stall modes), flushed
 *      wrong-path instructions, an ECALL (does not retire; the handler's 33 do), MRET
 *   B. writes: the value written is read by the next instruction (the writer's own
 *      retirement is not counted), CSRRW/CSRRS return the value including older
 *      retirements, writing minstreth leaves minstret alone
 *   C. carry into minstreth, also when the carry comes from a retirement in the same cycle
 *      as the read
 *   D. mcycle (checked exactly with ideal memories, as a lower bound otherwise): one per
 *      cycle, load-use stall, taken branch, JAL, MRET, a full trap round trip, writes of
 *      either half (no increment in the write cycle) and carry into mcycleh
 * minstret values are checked in-program in every memory mode (they do not depend on
 * timing); mcycle values through CYCLE_CHECK. */
#include "px_test.h"

  .data
  .balign 4
cbuf: .word 0x00000041, 0

  .text
  .globl test_main
test_main:
  .option norvc
  la   s0, cbuf

  /* ---------------- A. minstret counts retirements ---------------- */
  csrr a0, minstret
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(1, a2, 1)
  csrr a0, minstret
  nop
  nop
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(2, a2, 3)
  csrr a0, minstret
  lw   a3, 0(s0)                       /* retires in WB while the next read is in EX */
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(3, a2, 2)
  csrr a0, minstret
  beq  x0, x0, 1f
  nop                                  /* flushed: not counted */
  nop
1:
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(4, a2, 2)
  csrr a0, minstret
t_ecall:
  ecall                                /* not counted; the 33 handler instructions are */
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(5, a2, 34)
  la   a3, 2f
  csrr a0, minstret
  csrw mepc, a3
  mret                                 /* MRET retires */
2:
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(6, a2, 3)
  csrr a0, minstret
t_ill:
  .word 0x04000033                     /* OP with funct7 0000010: illegal, not counted */
  csrr a1, minstret
  sub  a2, a1, a0
  CHECK(7, a2, 34)

  /* ---------------- B. writes ---------------- */
  li   a2, 1000
  csrw minstret, a2
  csrr a0, minstret                    /* the write replaced the writer's increment */
  CHECK(10, a0, 1000)
  csrw minstret, a2
  nop
  csrr a0, minstret
  CHECK(11, a0, 1001)
  li   a2, 50
  csrr a3, minstret
  csrrw a0, minstret, a2               /* returns the count including csrr a3 */
  csrr a1, minstret
  sub  a4, a0, a3
  CHECK(12, a4, 1)
  CHECK(13, a1, 50)
  csrr a3, minstret
  li   a4, 0x10000
  csrrs a0, minstret, a4
  csrr a1, minstret
  sub  a5, a0, a3
  CHECK(14, a5, 2)
  li   a5, 0x10000
  or   a5, a0, a5
  CHECK_REG(15, a1, a5)
  li   a4, 5
  csrr a3, minstret
  csrw minstreth, a4                   /* not counted, minstret unchanged */
  csrr a0, minstret
  csrr a1, minstreth
  sub  a5, a0, a3
  CHECK(16, a5, 1)
  CHECK(17, a1, 5)
  csrrc a0, minstret, x0               /* no write: this one is counted */
  csrr a1, minstret
  sub  a5, a1, a0
  CHECK(18, a5, 1)

  /* ---------------- C. carry ---------------- */
  li   a4, 7
  csrw minstreth, a4
  li   a4, -3
  csrw minstret, a4                    /* 0xFFFFFFFD */
  nop                                  /* -> FFFFFFFE */
  nop                                  /* -> FFFFFFFF */
  nop                                  /* -> 0, minstreth 8 */
  csrr a0, minstreth
  csrr a1, minstret
  CHECK(20, a0, 8)
  CHECK(21, a1, 1)
  li   a4, 20
  csrw minstreth, a4
  li   a4, -1
  csrw minstret, a4                    /* FFFFFFFF, writer not counted */
  csrr a0, minstreth                   /* 20: nothing retired since the write */
  csrr a1, minstreth                   /* 21: csrr a0 retires in WB this cycle, carry */
  csrr a2, minstret
  CHECK(22, a0, 20)
  CHECK(23, a1, 21)
  CHECK(24, a2, 1)
  csrw minstreth, x0

  /* ---------------- D. mcycle ---------------- */
  csrr a0, mcycle
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 1)
  csrr a0, mcycle
  nop
  nop
  nop
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 4)
  csrr a0, mcycle
  lw   a3, 0(s0)
  addi a3, a3, 1                       /* load-use: +1 */
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 4)
  csrr a0, mcycle
  beq  x0, x0, 1f                      /* taken branch: 3 */
  nop
1:
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 4)
  csrr a0, mcycle
  jal  x0, 2f                          /* JAL: 2 */
  nop
2:
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 3)
  la   a3, 3f
  csrw mepc, a3
  csrr a0, mcycle
  mret                                 /* MRET: 3 */
3:
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 4)
  csrr a0, mcycle
t_ecall2:
  ecall                                /* entry 3 + handler + MRET 3 */
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 43)
  li   a2, 12345
  csrw mcycle, a2
  csrr a0, mcycle                      /* the written value, no increment in between */
  CYCLE_CHECK(a0, 12345)
  li   a2, 9
  csrw mcycleh, a2
  csrw mcycle, x0                      /* writing the low half keeps mcycleh */
  csrr a0, mcycleh
  csrr a1, mcycle
  CYCLE_CHECK(a0, 9)
  CYCLE_CHECK(a1, 1)
  csrr a0, mcycle
  csrw mcycleh, x0                     /* mcycle holds in the write cycle */
  csrr a1, mcycle
  sub  a2, a1, a0
  CYCLE_CHECK(a2, 1)
  li   a2, 3
  csrw mcycleh, a2
  li   a2, -4
  csrw mcycle, a2                      /* FFFFFFFC */
  nop
  nop
  nop
  nop
  csrr a0, mcycleh                     /* carried: 4 */
  CYCLE_CHECK(a0, 4)
  PASS

  TRAPS(3)
  TRAP(CAUSE_ECALL_M, t_ecall, 0)
  TRAP(CAUSE_ILLEGAL, t_ill, 0x04000033)
  TRAP(CAUSE_ECALL_M, t_ecall2, 0)
