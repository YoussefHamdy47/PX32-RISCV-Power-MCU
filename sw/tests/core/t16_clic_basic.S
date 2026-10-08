/* t16_clic_basic: CLIC basics on the core (Phase 2 step 2.2d, DECISIONS.md D-035;
 * PHASE2_CLIC_MATRIX.md §§ 3-4, PHASE2_VERIFICATION.md § 3.2). px-build: irq
 *
 * Built with PX_IRQ_RESUME and checked by px_iss --replay (the boundary of each take depends
 * on memory timing; px_iss models the CLIC from the recorded input changes). The program
 * uses its own NBASE handler (isr_nbase, 64-byte aligned) for CLIC mode: it records mcause,
 * mepc, mstatus, mintstatus of every trap in the frame below, counts interrupts, clears the
 * interrupt's edge pending bit and drops a held level input (IRQCLR), and returns with
 * MRET; an exception (ECALL only) returns after the instruction.
 *
 *   T1  CLINT mode at reset (K-05): mnxti reads 0 and still sets mstatus.MIE (K-37);
 *       mintthresh reads 0; mtvt and mintstatus readable; mie/mip read 0 (K-33)
 *   T2  CLIC mode (K-30, K-31): mtvec reads base | 11, submode 0000; mtvt [31:6] (K-32);
 *       mcause in CLIC format with mpp 11 and the mpie alias (K-34)
 *   T3  draft test plan nomint-01: an interrupt with MIE = 0 is not taken; WFI with MIE = 0
 *       does not hang (wfi-01, K-58); taken once MIE is set
 *   T4  nomint-02: a pending input with clicintie = 0 is not taken; taken when enabled (K-21)
 *   T5  nomint-03: mintthresh = 0xFF masks every level (K-51); lowering it takes the interrupt
 *   T6  direct-01: entry state (K-54): mcause {interrupt, mpp, mpie, mpil = 0, id}, mepc,
 *       mstatus (MIE 0, MPIE 1), mil = the level; MRET restores mil = mpil (K-57); the same
 *       edge interrupt does not retrigger after its pending bit is cleared
 *   T7  selection (K-50): of two pending interrupts the higher level is taken first; of two
 *       at the same level the higher id
 *   T8  level-triggered input (K-20): pending follows the input, a held level stays pending
 *       until the source is dropped; negative polarity (K-22)
 *   T9  synchronous exception in a handler (K-56): to NBASE, mpil = the handler's level, mil
 *       unchanged; MRET back into the handler, which saved and restores its own frame, mepc
 *       and mcause around the ECALL (a nested trap overwrites them)
 *   T10 mscratchcswl at core level (K-41): swaps between level 0 and a handler, not inside a
 *       handler that interrupted level 0 code twice
 *   T11 machine software interrupt (id 0, input tied 0): pending set by a store (K-20, § 4.7)
 *   T12 O5 (D-034, cycle-exact): no take in the cycle after mtvec returns to CLINT mode. The
 *       trigger delay is swept so that in ideal mode the interrupt reaches the core in every
 *       cycle around the mtvec write, among them the cycle right after it; tb_core counts that
 *       cycle (O5 bin) and its monitors fail any take without a request
 *   T13 O5: no take at or below a newly raised mintthresh in the cycle after the csrw (swept
 *       the same way), and a take above it in that cycle without delay
 *   T14 K-27: a store that enables a pending interrupt is seen one cycle after its write
 *       edge (the take in ideal mode is at a fixed distance from the store: CYCLE_CHECK)
 *   T15 an id above 31 (40): the 6-bit exception code reaches mcause
 */
#include "px_test.h"

#define TRIG(id, lat)   (((lat) << 24) | ((id) << 16))
#define TRIG_LEVEL      0x40000000
#define FRM_IRQS     48     /* frame fields beyond crt0's (TF_* < 48) */
#define FRM_CAUSE    52
#define FRM_EPC      56
#define FRM_STATUS   60
#define FRM_INTST    64
#define FRM_EXCS     68
#define FRM_SP       72
#define FRM_SV0      76     /* T9: the handler's frame, mepc and mcause around its ECALL */
#define FRM_SV1      80
#define FRM_SV2      84
#define FRM_SVEPC    88
#define FRM_SVCAUSE  92
#define FRM_CYC      96     /* mcycle at handler entry (T14) */
/* T14: mcycle from the csrr before the enable store to the csrr in the handler, ideal mode */
#define T14_CYCLES   8

/* arm the trigger: id, latency (0 = not checked), delay in register dreg */
#define ARM(val) li t5, val; li t6, IRQTRIG; sw t5, 0(t6)
/* configure CLIC entry id: level l (0-15), attribute, enable */
#define CFG(id, l, attr, ie) li t5, CLIC_WORD(l, attr, ie); li t6, CLIC_ENTRY(id); sw t5, 0(t6)
/* wait (bounded) until FRM_IRQS reaches n; fail as test t otherwise */
#define WAIT_N(t, n) \
  li gp, t; li t3, 300; \
  9993: li t4, TRAP_FRAME; lw t4, FRM_IRQS(t4); li t6, n; beq t4, t6, 9994f; \
  addi t3, t3, -1; bnez t3, 9993b; j fail_handler; 9994:
/* wait (bounded) until FRM_IRQS equals register reg; fail as test t otherwise */
#define WAIT_R(t, reg) \
  li gp, t; li t3, 300; \
  9993: li t4, TRAP_FRAME; lw t4, FRM_IRQS(t4); beq t4, reg, 9994f; \
  addi t3, t3, -1; bnez t3, 9993b; j fail_handler; 9994:
/* spin k iterations (lets a request arrive and be taken or not) */
#define SPIN(k) li t3, k; 9995: addi t3, t3, -1; bnez t3, 9995b
#define FIELD(reg, f) li t4, TRAP_FRAME; lw reg, f(t4)

  .text
  .globl test_main
test_main:
  li   t0, TRAP_FRAME
  sw   zero, FRM_IRQS(t0)
  sw   zero, FRM_EXCS(t0)

  /* ---- T1: CLINT mode at reset ---- */
  li   gp, 1
  csrr a0, CSR_MNXTI
  CHECK(1, a0, 0)
  csrrsi a0, CSR_MNXTI, 8         /* reads 0, sets MIE (K-37) */
  CHECK(2, a0, 0)
  csrr a0, mstatus
  CHECK(3, a0, 0x1808)
  csrci mstatus, 8
  csrwi CSR_MINTTHRESH, 0x1F
  csrr a0, CSR_MINTTHRESH
  CHECK(4, a0, 0)                 /* new CLIC CSRs read 0 in CLINT mode */
  csrwi CSR_MINTTHRESH, 0
  li   a1, 0x00008FFF
  csrw CSR_MTVT, a1
  csrr a0, CSR_MTVT
  CHECK(5, a0, 0x00008FC0)
  csrr a0, CSR_MINTSTATUS
  CHECK(6, a0, 0)
  csrr a0, mie
  CHECK(7, a0, 0)
  csrr a0, mip
  CHECK(8, a0, 0)

  /* ---- T2: enter CLIC mode ---- */
  la   t0, isr_nbase
  ori  t0, t0, 0x3F               /* mode 11 with submode bits: submode reads 0000 */
  csrw mtvec, t0
  csrr a0, mtvec
  la   a1, isr_nbase
  ori  a1, a1, 3
  CHECK_REG(9, a0, a1)
  li   a1, 0x08550025             /* mcause: mpie 1, mpil 0x55, code 37 */
  csrw mcause, a1
  csrr a0, mcause
  CHECK(10, a0, 0x38550025)       /* mpp reads 11 */
  csrr a0, mstatus
  CHECK(11, a0, 0x1880)           /* the mpie alias wrote MPIE */
  csrw mcause, zero
  csrr a0, mstatus
  CHECK(12, a0, 0x1800)
  /* every interrupt used here: edge, positive, non-vectored, disabled */
  CFG(2, 3, CLIC_ATTR_EDGE, 0)
  CFG(3, 3, CLIC_ATTR_EDGE, 0)
  CFG(4, 9, CLIC_ATTR_EDGE, 0)
  CFG(5, 9, CLIC_ATTR_EDGE, 0)
  CFG(6, 5, 0, 0)                 /* level-triggered, positive */
  CFG(7, 5, CLIC_ATTR_NEG, 0)     /* level-triggered, negative: pending while input low */

  /* ---- T3: nomint-01 and wfi-01: MIE = 0 ---- */
  CFG(2, 3, CLIC_ATTR_EDGE, 1)
  ARM(TRIG(2, 0))
  SPIN(20)
  wfi                             /* a NOP: must not hang with MIE = 0 (K-58) */
  FIELD(a0, FRM_IRQS)
  CHECK(13, a0, 0)
  csrsi mstatus, 8
  WAIT_N(14, 1)
  FIELD(a0, FRM_CAUSE)
  CHECK(15, a0, 0xB8000002)       /* interrupt, mpp 11, mpie 1, mpil 0, id 2 */
  FIELD(a0, FRM_INTST)
  CHECK(16, a0, 0x3F000000)       /* mil = level 3 -> 0x3F in the handler */
  csrr a0, CSR_MINTSTATUS
  CHECK(17, a0, 0)                /* MRET restored mil = mpil = 0 */
  csrci mstatus, 8

  /* ---- T4: nomint-02: not enabled ---- */
  ARM(TRIG(3, 0))                 /* id 3 pending, disabled */
  csrsi mstatus, 8
  SPIN(20)
  FIELD(a0, FRM_IRQS)
  CHECK(18, a0, 1)
  li   t0, CLIC_ENTRY(3)          /* enable (the ie byte only: a word store would also */
  li   t1, 1                      /* clear the pending byte): taken now */
  sb   t1, 1(t0)
  WAIT_N(19, 2)
  FIELD(a0, FRM_CAUSE)
  CHECK(20, a0, 0xB8000003)

  /* ---- T5: nomint-03: mintthresh max ---- */
  csrwi CSR_MINTTHRESH, 0x1F
  li   a1, 0xFF
  csrw CSR_MINTTHRESH, a1
  ARM(TRIG(2, 0))
  SPIN(20)
  FIELD(a0, FRM_IRQS)
  CHECK(21, a0, 2)
  csrw CSR_MINTTHRESH, zero       /* level 0x3F > 0: taken */
  WAIT_N(22, 3)

  /* ---- T6: direct-01: entry state, no retrigger ---- */
  ARM(TRIG(2, 4))                 /* non-vectored latency 4 in ideal mode */
t6_wait:
  WAIT_N(23, 4)
  FIELD(a0, FRM_STATUS)
  CHECK(24, a0, 0x1880)           /* in the handler: MIE 0, MPIE 1 */
  FIELD(a0, FRM_EPC)
  la   a1, t6_wait
  bltu a0, a1, 1f                 /* mepc lies in the wait loop */
  la   a1, t6_end
  bltu a0, a1, 2f
1:
  li   gp, 25
  j    fail_handler
2:
  SPIN(30)
  FIELD(a0, FRM_IRQS)
  CHECK(26, a0, 4)                /* cleared by the handler: no retrigger */
t6_end:

  /* ---- T7: selection ---- */
  csrci mstatus, 8
  CFG(4, 9, CLIC_ATTR_EDGE, 1)
  CFG(5, 9, CLIC_ATTR_EDGE, 1)
  ARM(TRIG(2, 0))                 /* level 0x3F */
  SPIN(8)
  ARM(TRIG(4, 0))                 /* level 0x9F */
  SPIN(8)
  ARM(TRIG(5, 0))                 /* level 0x9F, higher id */
  SPIN(8)
  la   t0, sel_log
  li   t1, TRAP_FRAME
  sw   t0, FRM_SP(t1)             /* the handler logs each id in order */
  csrsi mstatus, 8
  WAIT_N(27, 7)
  la   t0, sel_log
  lw   a0, 0(t0)
  CHECK(28, a0, 5)                /* same level: highest id first */
  lw   a0, 4(t0)
  CHECK(29, a0, 4)
  lw   a0, 8(t0)
  CHECK(30, a0, 2)                /* lower level last */
  li   t1, TRAP_FRAME
  sw   zero, FRM_SP(t1)

  /* ---- T8: level-triggered inputs, both polarities ---- */
  li   t0, CLIC_ENTRY(6)
  lw   a0, 0(t0)
  CHECK(31, a0, 0x5FC00000)       /* level 5, mode 11, positive level, disabled, not pending */
  ARM(TRIG(6, 0) | TRIG_LEVEL)    /* input 6 held high */
  SPIN(6)
  li   t0, CLIC_ENTRY(6)
  lw   a0, 0(t0)
  CHECK(32, a0, 0x5FC00001)       /* pending follows the input */
  sb   zero, 0(t0)                /* a write cannot clear a level pending bit */
  lw   a0, 0(t0)
  CHECK(33, a0, 0x5FC00001)
  CFG(6, 5, 0, 1)                 /* enable: taken; the handler drops the input (IRQCLR) */
  WAIT_N(34, 8)
  SPIN(4)
  li   t0, CLIC_ENTRY(6)
  lw   a0, 0(t0)
  CHECK(35, a0, 0x5FC00100)       /* input dropped: not pending */
  FIELD(a0, FRM_IRQS)
  CHECK(36, a0, 8)
  li   t0, CLIC_ENTRY(7)
  lw   a0, 0(t0)
  CHECK(37, a0, 0x5FC40001)       /* negative polarity: input low -> pending */
  CFG(7, 5, CLIC_ATTR_NEG, 1)     /* enabled: taken; the input stays low, so the handler */
  WAIT_N(38, 9)                   /* disables id 7 (else it is taken again at every MRET) */
  FIELD(a0, FRM_CAUSE)
  CHECK(54, a0, 0xB8000007)
  li   t0, CLIC_ENTRY(7)
  lw   a0, 0(t0)
  CHECK(55, a0, 0x5FC40001)       /* still pending (input low), now disabled */

  /* ---- T9: exception in a handler (horizontal, level kept) ---- */
  li   t1, TRAP_FRAME
  li   t0, 1
  sw   t0, FRM_EXCS(t1)           /* the next interrupt handler executes an ECALL */
  ARM(TRIG(4, 0))
  WAIT_N(39, 10)
  FIELD(a0, FRM_CAUSE)            /* the handler stored the ECALL's mcause last */
  CHECK(40, a0, 0x309F000B)       /* exception, mpp 11, mpie 0, mpil = 0x9F, code 11 */
  FIELD(a0, FRM_INTST)
  CHECK(41, a0, 0x9F000000)       /* mil unchanged in the exception handler */
  csrr a0, CSR_MINTSTATUS
  CHECK(42, a0, 0)

  /* ---- T10: mscratchcswl ---- */
  li   s2, 0x5555AAAA
  csrr s3, mscratch
  mv   a0, s2
  csrrw a0, CSR_MSCRATCHCSWL, a0  /* level 0, mpil 0: no swap (both 0) */
  CHECK_REG(43, a0, s2)
  csrr a0, mscratch
  CHECK_REG(44, a0, s3)
  li   t1, TRAP_FRAME
  li   t0, 2
  sw   t0, FRM_EXCS(t1)           /* the next handler swaps with mscratchcswl and back */
  ARM(TRIG(4, 0))
  WAIT_N(45, 11)
  FIELD(a0, FRM_EXCS)
  CHECK(46, a0, 0x5A)             /* the handler saw the swap (mil != 0, mpil = 0) */
  csrr a0, mscratch
  CHECK_REG(47, a0, s3)

  /* ---- T11: machine software interrupt, id 0 ---- */
  CFG(0, 15, CLIC_ATTR_EDGE, 1)
  li   t0, CLIC_ENTRY(0)
  li   t1, 1
  sb   t1, 0(t0)                  /* software sets the pending bit */
  WAIT_N(48, 12)
  FIELD(a0, FRM_CAUSE)
  CHECK(49, a0, 0xB8000000)       /* id 0 */
  li   t0, CLIC_ENTRY(0)
  sb   zero, 1(t0)

  /* ---- T12: O5, no take in the cycle after mtvec returns to CLINT mode ---- */
  csrsi mstatus, 8
  li   s6, 0                      /* trigger delay, swept */
t12_loop:
  la   s8, isr_nbase              /* mtvec values: CLINT (Direct) and CLIC */
  ori  s9, s8, 3
  FIELD(s7, FRM_IRQS)
  li   t5, TRIG(2, 0)             /* id 2: level 0x3F, edge, enabled */
  or   t5, t5, s6
  li   t6, IRQTRIG
  sw   t5, 0(t6)
  nop
  nop
  csrw mtvec, s8                  /* CLINT mode: a later request is never taken */
  .rept 12
  nop
  .endr
  csrw mtvec, s9                  /* CLIC mode again: a pending id 2 is taken now */
  addi s7, s7, 1
  WAIT_R(50, s7)
  addi s6, s6, 1
  li   t0, 10
  blt  s6, t0, t12_loop

  /* ---- T13: O5, mintthresh raised: no take at or below it in the next cycle, a take
     above it without delay ---- */
  li   s6, 0
t13a_loop:                        /* id 2 (0x3F) against mintthresh 0xFF: masked */
  FIELD(s7, FRM_IRQS)
  li   a1, 0xFF
  li   t5, TRIG(2, 0)
  or   t5, t5, s6
  li   t6, IRQTRIG
  sw   t5, 0(t6)
  nop
  nop
  csrw CSR_MINTTHRESH, a1
  .rept 12
  nop
  .endr
  csrw CSR_MINTTHRESH, zero       /* lowered: a pending id 2 is taken now */
  addi s7, s7, 1
  WAIT_R(51, s7)
  addi s6, s6, 1
  li   t0, 10
  blt  s6, t0, t13a_loop
  li   s6, 0
t13b_loop:                        /* id 4 (0x9F) against mintthresh 0x3F: taken at once */
  FIELD(s7, FRM_IRQS)
  li   a1, 0x3F
  li   t5, TRIG(4, 0)
  or   t5, t5, s6
  li   t6, IRQTRIG
  sw   t5, 0(t6)
  nop
  nop
  csrw CSR_MINTTHRESH, a1
  .rept 12
  nop
  .endr
  addi s7, s7, 1
  WAIT_R(52, s7)
  csrw CSR_MINTTHRESH, zero
  addi s6, s6, 1
  li   t0, 10
  blt  s6, t0, t13b_loop

  /* ---- T14: K-27, an enable store is seen one cycle after its write edge ---- */
  csrci mstatus, 8
  CFG(3, 3, CLIC_ATTR_EDGE, 0)
  ARM(TRIG(3, 0))
  SPIN(6)                         /* pending, disabled */
  FIELD(s7, FRM_IRQS)
  csrsi mstatus, 8
  li   t5, 1
  li   t6, CLIC_ENTRY(3)
  csrr s4, mcycle
  sb   t5, 1(t6)                  /* enable store; the take kills the instructions behind it */
  .rept 8
  nop
  .endr
  addi s7, s7, 1
  WAIT_R(53, s7)
  FIELD(a0, FRM_CYC)
  sub  a0, a0, s4                 /* mcycle of the handler's third instruction - the store's */
  CYCLE_CHECK(a0, T14_CYCLES)

  /* ---- T15: id 40 ---- */
  CFG(40, 2, CLIC_ATTR_EDGE, 1)
  FIELD(s7, FRM_IRQS)
  ARM(TRIG(40, 0))
  addi s7, s7, 1
  WAIT_R(56, s7)
  FIELD(a0, FRM_CAUSE)
  CHECK(57, a0, 0xB8000028)       /* interrupt, mpp 11, mpie 1, mpil 0, code 40 */

  PASS

/* ------------------------------------------------------------------ handler */
  .balign 64
  .globl isr_nbase
isr_nbase:
  csrrw sp, mscratch, sp          /* sp = frame */
  sw   t0, TF_T0(sp)
  csrr t0, mcycle                 /* T14 */
  sw   t0, FRM_CYC(sp)
  sw   t1, TF_T1(sp)
  sw   t2, TF_T2(sp)
  csrr t0, mcause
  sw   t0, FRM_CAUSE(sp)
  csrr t1, mepc
  sw   t1, FRM_EPC(sp)
  csrr t2, mstatus
  sw   t2, FRM_STATUS(sp)
  csrr t2, CSR_MINTSTATUS
  sw   t2, FRM_INTST(sp)
  bgez t0, h_exc
  lw   t2, FRM_IRQS(sp)
  addi t2, t2, 1
  sw   t2, FRM_IRQS(sp)
  andi t0, t0, 0x3F               /* id */
  lw   t2, FRM_SP(sp)             /* selection log pointer (T7) */
  beqz t2, 1f
  sw   t0, 0(t2)
  addi t2, t2, 4
  sw   t2, FRM_SP(sp)
1:
  slli t1, t0, 2                  /* clear the edge pending bit */
  li   t2, CLIC_INTIP
  add  t2, t2, t1
  sb   zero, 0(t2)
  li   t2, IRQCLR                 /* drop a held level input */
  sw   t0, 0(t2)
  li   t1, 7                      /* id 7 (negative level, input low): disable it */
  bne  t0, t1, 3f
  li   t2, CLIC_ENTRY(7)
  sb   zero, 1(t2)
3:
  lw   t2, FRM_EXCS(sp)
  li   t1, 1
  bne  t2, t1, 2f
  sw   zero, FRM_EXCS(sp)         /* T9: an ECALL inside the handler */
  lw   t1, TF_T0(sp)              /* the nested entry reuses the frame: keep ours */
  sw   t1, FRM_SV0(sp)
  lw   t1, TF_T1(sp)
  sw   t1, FRM_SV1(sp)
  lw   t1, TF_T2(sp)
  sw   t1, FRM_SV2(sp)
  csrr t1, mepc
  sw   t1, FRM_SVEPC(sp)
  csrr t1, mcause
  sw   t1, FRM_SVCAUSE(sp)
  csrrw sp, mscratch, sp          /* mscratch = frame again for the nested entry */
h_t9_ecall:
  ecall
  csrrw sp, mscratch, sp
  lw   t1, FRM_SVEPC(sp)
  csrw mepc, t1
  lw   t1, FRM_SVCAUSE(sp)        /* CLIC format: restores mpil 0 and MPIE 1 (alias) */
  csrw mcause, t1
  lw   t1, FRM_SV0(sp)
  sw   t1, TF_T0(sp)
  lw   t1, FRM_SV1(sp)
  sw   t1, TF_T1(sp)
  lw   t1, FRM_SV2(sp)
  sw   t1, TF_T2(sp)
  j    h_ret
2:
  li   t1, 2
  bne  t2, t1, h_ret
  li   t1, 0x12345678             /* T10: mil != 0, mpil = 0: the swap happens */
  csrrw t1, CSR_MSCRATCHCSWL, t1  /* t1 = the interrupted code's mscratch */
  csrrw t1, CSR_MSCRATCHCSWL, t1  /* swap back: t1 = 0x12345678 */
  li   t2, 0x12345678
  bne  t1, t2, h_ret
  li   t2, 0x5A
  sw   t2, FRM_EXCS(sp)
h_ret:
  lw   t0, TF_T0(sp)
  lw   t1, TF_T1(sp)
  lw   t2, TF_T2(sp)
  csrrw sp, mscratch, sp
  mret
h_exc:                          /* ECALL (T9): mepc + 4; the trap state stays recorded */
  addi t1, t1, 4
  csrw mepc, t1
  j    h_ret

  .data
  .balign 4
sel_log: .word 0, 0, 0, 0

  TRAPS(1)
  TRAP(CAUSE_ECALL_M, h_t9_ecall, 0)
