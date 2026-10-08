/* t17_clic_nest: CLIC preemption, mnxti and the claim cycle (Phase 2 step 2.2d, DECISIONS.md
 * D-035; PHASE2_CLIC_MATRIX.md K-37..K-41, K-50..K-57). px-build: irq
 *
 * Built with PX_IRQ_RESUME and checked by px_iss --replay. The program uses one NBASE handler
 * written the way CLIC handlers are meant to be: it switches to an interrupt stack with
 * mscratchcswl (only when it interrupted level-0 code), saves mepc and mcause on that stack,
 * may re-enable interrupts, and restores both before its MRET. Every entry is logged (id,
 * mintstatus, mcause). What a handler does besides logging is chosen by the test phase.
 *
 *   N1 preemption (K-55, draft test plan direct-nesting): the handler of id 2 (level 0x3F)
 *      re-enables MIE; id 5 (0x9F) preempts it: inside, mil = 0x9F and mcause.mpil = 0x3F;
 *      back in id 2's handler mil = 0x3F; id 3 at the same level (0x3F) does not preempt and
 *      is taken after id 2's MRET (mil back to 0). mscratchcswl swaps only on the outer entry
 *      and exit (K-41)
 *   N2 mnxti (K-37..K-40, draft mnxti cases): inside id 5's handler (mil 0x9F, MIE 0), id 4
 *      at the same level is pending; csrrci mnxti, MIE claims it: the result is mtvt + 4 * 4,
 *      mcause.exccode = 4, mil = its level, the edge pending bit cleared; a second mnxti finds
 *      nothing and returns 0
 *   N3 O5 (D-034, cycle-exact): with MIE already 1, csrrsi mnxti, MIE claims id 4 while a
 *      level-15 request (id 7) arrives around the claim; id 7 is taken as soon as it is
 *      presented. The trigger delay is swept so that in ideal mode it is presented in every
 *      cycle around the claim, among them the cycle right after it; tb_core counts that cycle
 *      (O5 bin) and fails any eligible cycle without a take
 */
#include "px_test.h"

#define MAIN_SP  0x20008000
#define TRIG(id, lat)   (((lat) << 24) | ((id) << 16))
#define CFG(id, l, attr, ie) li t5, CLIC_WORD(l, attr, ie); li t6, CLIC_ENTRY(id); sw t5, 0(t6)
/* wait (bounded) until the log holds n entries; fail as test t otherwise */
#define WAIT_LOG(t, reg) \
  li gp, t; li t3, 400; \
  9993: la t4, log_n; lw t4, 0(t4); beq t4, reg, 9994f; \
  addi t3, t3, -1; bnez t3, 9993b; j fail_handler; 9994:
/* log entry k (12 bytes: id, mintstatus, mcause) field f into reg */
#define LOGF(reg, k, f) la t4, log; lw reg, (12 * (k) + (f))(t4)

  .text
  .globl test_main
test_main:
  li   sp, MAIN_SP                /* level-0 code's sp: swapped out by the handler */
  la   t0, istack_top
  csrw mscratch, t0               /* interrupt stack (mscratchcswl swaps it in) */
  la   t0, isr_nbase
  ori  t0, t0, 3
  csrw mtvec, t0
  la   t0, ptab
  csrw CSR_MTVT, t0
  CFG(2, 3, CLIC_ATTR_EDGE, 1)    /* 0x3F */
  CFG(3, 3, CLIC_ATTR_EDGE, 1)    /* 0x3F */
  CFG(4, 9, CLIC_ATTR_EDGE, 1)    /* 0x9F */
  CFG(5, 9, CLIC_ATTR_EDGE, 1)    /* 0x9F */
  CFG(7, 15, CLIC_ATTR_EDGE, 1)   /* 0xFF */
  csrsi mstatus, 8

  /* ---- N1: preemption ---- */
  li   t0, 1
  la   t1, phase
  sw   t0, 0(t1)
  li   t5, TRIG(2, 0)
  li   t6, IRQTRIG
  sw   t5, 0(t6)
  li   s7, 3                      /* entries: 2, 5, 3 */
  WAIT_LOG(1, s7)
  LOGF(a0, 0, 0)
  CHECK(2, a0, 2)
  LOGF(a0, 0, 4)
  CHECK(3, a0, 0x3F000000)        /* mil = 0x3F in id 2's handler */
  LOGF(a0, 0, 8)
  CHECK(4, a0, 0xB8000002)        /* mpil 0 */
  LOGF(a0, 1, 0)
  CHECK(5, a0, 5)                 /* id 5 preempted id 2's handler */
  LOGF(a0, 1, 4)
  CHECK(6, a0, 0x9F000000)
  LOGF(a0, 1, 8)
  CHECK(7, a0, 0xB83F0005)        /* mpil = 0x3F, mpie 1 (MIE was 1) */
  LOGF(a0, 2, 0)
  CHECK(8, a0, 3)                 /* id 3 only after id 2's handler */
  LOGF(a0, 2, 4)
  CHECK(9, a0, 0x3F000000)
  LOGF(a0, 2, 8)
  CHECK(10, a0, 0xB8000003)       /* mpil 0: taken at level 0 */
  la   t0, n1_mil
  lw   a0, 0(t0)
  CHECK(11, a0, 0x3F000000)       /* back in id 2's handler after id 5: mil = 0x3F */
  lw   a0, 4(t0)
  CHECK(12, a0, 2)                /* id 3 pending in id 2's handler with MIE = 1: not taken */
  lw   a0, 8(t0)
  CHECK(13, a0, MAIN_SP)          /* inside: the interrupted code's sp is in mscratch ... */
  csrr a0, mscratch
  la   a1, istack_top
  CHECK_REG(14, a0, a1)           /* ... after: the interrupt stack is back in mscratch */
  li   a1, MAIN_SP
  CHECK_REG(23, sp, a1)
  csrr a0, CSR_MINTSTATUS
  CHECK(15, a0, 0)

  /* ---- N2: mnxti claim inside id 5's handler, with csrrci (MIE stays 0: no preemption) ---- */
  li   t0, 2
  la   t1, phase
  sw   t0, 0(t1)
  li   t5, TRIG(5, 0)
  li   t6, IRQTRIG
  sw   t5, 0(t6)
  li   s7, 4
  WAIT_LOG(16, s7)
  la   t0, n2_res
  lw   a0, 0(t0)
  la   a1, ptab + 4 * 4
  CHECK_REG(17, a0, a1)           /* mnxti: the claimed id's table entry address */
  lw   a0, 4(t0)
  CHECK(18, a0, 0)                /* nothing left: 0 */
  lw   a0, 8(t0)
  CHECK(19, a0, 0xB8000004)       /* mcause after the claim: exccode 4 (mpie 1, mpil 0 kept) */
  lw   a0, 12(t0)
  CHECK(20, a0, 0x9F000000)       /* mil = the claimed level */
  lw   a0, 16(t0)
  CHECK(21, a0, 0x9FC20100)       /* id 4: the claim cleared its edge pending bit */
  la   t0, log
  lw   a0, 12 * 3(t0)
  CHECK(24, a0, 5)                /* only id 5 was taken (id 4 was claimed) */

  /* ---- N3: csrrsi mnxti, MIE with MIE already 1; id 7 swept around the claim. When id 7
     is taken before the mnxti, its handler's MRET leaves mcause.mpil = 0x9F and the mnxti
     finds nothing above it: id 4 is then taken after id 5's handler. Either way every id 4
     interrupt is claimed or taken exactly once (px_iss checks each step) ---- */
  li   t0, 3
  la   t1, phase
  sw   t0, 0(t1)
  li   s6, 0                      /* id 7's trigger delay */
  li   s8, 0                      /* claims */
n3_loop:
  la   t0, n3_delay
  sw   s6, 0(t0)
  la   t0, n2_res
  sw   zero, 0(t0)
  li   t5, TRIG(5, 0)
  li   t6, IRQTRIG
  sw   t5, 0(t6)
  addi s7, s7, 2                  /* at least 5 and 7 */
  li   gp, 25
  li   t3, 400
1:
  la   t4, log_n
  lw   t4, 0(t4)
  bgeu t4, s7, 2f
  addi t3, t3, -1
  bnez t3, 1b
  j    fail_handler
2:
  li   t3, 200                    /* settle: an unclaimed id 4 is taken by now */
3:
  addi t3, t3, -1
  bnez t3, 3b
  la   t4, log_n
  lw   s7, 0(t4)
  la   t0, n2_res
  lw   a0, 0(t0)
  beqz a0, 4f
  la   a1, ptab + 4 * 4
  CHECK_REG(26, a0, a1)
  addi s8, s8, 1
4:
  lw   a0, 4(t0)
  CHECK(27, a0, 0)
  addi s6, s6, 1
  li   t0, 12
  blt  s6, t0, n3_loop
  la   t0, log + 12 * 4           /* N3's entries: count the ids 4 taken */
  la   t4, log_n
  lw   t1, 0(t4)
  addi t1, t1, -4
  li   a0, 0
5:
  lw   t2, 0(t0)
  addi t2, t2, -4
  bnez t2, 6f
  addi a0, a0, 1
6:
  addi t0, t0, 12
  addi t1, t1, -1
  bnez t1, 5b
  add  a0, a0, s8
  CHECK(28, a0, 12)               /* each id 4 claimed or taken once */
  li   gp, 29
  beqz s8, fail_handler           /* at least one claim in the sweep */
  csrr a0, CSR_MINTSTATUS
  CHECK(22, a0, 0)

  PASS

/* ------------------------------------------------------------------ handler */
  .balign 64
  .globl isr_nbase
isr_nbase:
  csrrw sp, CSR_MSCRATCHCSWL, sp  /* interrupt stack, only when level 0 was interrupted */
  addi sp, sp, -32
  sw   t0, 0(sp)
  sw   t1, 4(sp)
  sw   t2, 8(sp)
  sw   a0, 20(sp)
  csrr t0, mcause
  sw   t0, 12(sp)
  csrr t1, mepc
  sw   t1, 16(sp)
  bgez t0, h_fatal              /* no exceptions expected */
  la   t1, log_n                  /* log: id, mintstatus, mcause */
  lw   t2, 0(t1)
  addi a0, t2, 1
  sw   a0, 0(t1)
  li   a0, 12
  mul  t2, t2, a0
  la   a0, log
  add  t2, t2, a0
  andi t0, t0, 0x3F
  sw   t0, 0(t2)
  csrr a0, CSR_MINTSTATUS
  sw   a0, 4(t2)
  lw   a0, 12(sp)
  sw   a0, 8(t2)
  slli t1, t0, 2                  /* clear the edge pending bit */
  li   t2, CLIC_INTIP
  add  t2, t2, t1
  sb   zero, 0(t2)
  la   t1, phase
  lw   t1, 0(t1)
  li   t2, 1
  bne  t1, t2, 1f
  li   t2, 2
  beq  t0, t2, act_n1             /* N1: the outer handler (id 2) */
  j    h_ret
1:
  li   t2, 5
  beq  t0, t2, act_n2             /* N2, N3: the outer handler (id 5) */
  j    h_ret

act_n1:
  li   t1, TRIG(5, 0)
  li   t2, IRQTRIG
  sw   t1, 0(t2)
  csrsi mstatus, 8                /* id 5 (0x9F > 0x3F) preempts here */
  li   t1, 40
2:
  addi t1, t1, -1
  bnez t1, 2b
  la   t2, n1_mil
  csrr t1, CSR_MINTSTATUS
  sw   t1, 0(t2)
  li   t1, TRIG(3, 0)
  li   a0, IRQTRIG
  sw   t1, 0(a0)                  /* id 3 (0x3F, not above mil): pending, not taken */
  li   t1, 40
3:
  addi t1, t1, -1
  bnez t1, 3b
  la   t1, log_n
  lw   t1, 0(t1)
  sw   t1, 4(t2)                  /* entries so far: 2 (ids 2 and 5) */
  csrr t1, mscratch
  sw   t1, 8(t2)                  /* the interrupted code's sp */
  csrci mstatus, 8
  j    h_ret

act_n2:                           /* mil 0x9F, MIE 0 */
  li   t1, TRIG(4, 0)
  li   t2, IRQTRIG
  sw   t1, 0(t2)
  li   t2, CLIC_ENTRY(4)
4:
  lbu  t1, 0(t2)                  /* wait until id 4 is pending */
  beqz t1, 4b
  la   t1, phase
  lw   t1, 0(t1)
  li   t2, 2
  bne  t1, t2, act_n3
  csrrci a0, CSR_MNXTI, 8         /* N2: claim id 4, MIE stays 0 */
  la   t2, n2_res
  sw   a0, 0(t2)
  csrr t1, mcause
  sw   t1, 8(t2)
  csrr t1, CSR_MINTSTATUS
  sw   t1, 12(t2)
  li   t1, CLIC_ENTRY(4)
  lw   t1, 0(t1)
  sw   t1, 16(t2)
  csrrci a0, CSR_MNXTI, 8
  sw   a0, 4(t2)
  j    h_ret
act_n3:
  csrsi mstatus, 8                /* id 4 (0x9F, not above mil): not taken */
  la   t1, n3_delay
  lw   t1, 0(t1)
  li   t2, TRIG(7, 0)
  or   t1, t1, t2
  li   t2, IRQTRIG
  sw   t1, 0(t2)                  /* id 7 (0xFF) after the swept delay */
  nop
  nop
  csrrsi a0, CSR_MNXTI, 8         /* claim id 4 with MIE already 1 (O5) */
  la   t2, n2_res
  sw   a0, 0(t2)
  li   t1, 60
5:
  addi t1, t1, -1                 /* id 7 is taken by now in every mode */
  bnez t1, 5b
  csrrsi a0, CSR_MNXTI, 8
  sw   a0, 4(t2)
  csrci mstatus, 8
  j    h_ret

h_ret:                          /* MIE is 0 here */
  lw   t0, 16(sp)
  csrw mepc, t0
  lw   t0, 12(sp)
  csrw mcause, t0                 /* restores mpil (and so mil at MRET) and MPIE */
  lw   t0, 0(sp)
  lw   t1, 4(sp)
  lw   t2, 8(sp)
  lw   a0, 20(sp)
  addi sp, sp, 32
  csrrw sp, CSR_MSCRATCHCSWL, sp
  mret

h_fatal:
  li   gp, 0x7FD
  j    fail_handler

/* mtvt target (mnxti returns entry addresses; nothing here is vectored) */
  .section .vectab, "ax"
  .balign 64
ptab:
  .rept 16
  .word isr_nbase
  .endr

  .data
  .balign 4
phase:    .word 0
n3_delay: .word 0
log_n:    .word 0
n1_mil:   .word 0, 0, 0
n2_res:   .word 0, 0, 0, 0, 0
log:      .space 12 * 48
  .balign 16
istack:   .space 512
istack_top:

  TRAPS(0)
