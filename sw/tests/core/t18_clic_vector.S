/* t18_clic_vector: selective hardware vectoring (Phase 2 step 2.2d, DECISIONS.md D-035
 * items 16-19; PHASE2_CLIC_MATRIX.md K-70..K-77, smclicshv). px-build: irq
 *
 * Built with PX_IRQ_RESUME and checked by px_iss --replay. The program runs in CLIC mode
 * with its own NBASE handler (isr_nbase) and a vector table (section .vectab, mtvt) whose
 * entries point at small handlers that share one body (v_common): it counts the takes per
 * id and records mcause, mepc and mintstatus. tb_core measures the latency of each declared
 * trigger in ideal mode (pending flop to the handler's first instruction in EX), the MRET
 * refetch (MRET in EX to the handler in EX: 5) and the fetch-stage state at every vectored
 * take (coverage bins, D-035 item 17).
 *
 *   V1 shv-01: a vectored edge interrupt (id 8) goes to its table entry's handler: latency
 *      6 (D-029 budget); mcause {interrupt, mpp 11, mpie 1, mpil 0, id}, minhv 0; the edge
 *      pending bit is cleared by the take (K-71), so it does not retrigger
 *   V2 a 32-bit first instruction at a halfword offset (exempt_halfword_v9): latency 7, the
 *      one exempt entry (D-029 item 4)
 *   V3 a table word with bit 0 set (id 10): bit 0 is ignored (K-72)
 *   V4 a non-vectored interrupt in the same program goes to NBASE: latency 4
 *   V5 table fetch fault (K-73): with mtvt pointing outside memory the vectored take faults:
 *      instruction access fault at pc = tval = the table address, mcause.minhv = 1, mpil =
 *      the interrupt's level (mil was raised by the take), MPIE = 0. The fault handler's
 *      MRET with minhv = 1 refetches at mepc & ~3 (K-74): first at another unmapped entry
 *      (a second fault with the same state), then at the good entry, which reaches the
 *      handler (interrupted context lost, as the draft says)
 *   V6 no interrupt is taken while the MRET refetch is in progress: a level input above
 *      mil is pending when that MRET sets MIE; it is taken right after the refetch, with
 *      mepc = the handler's first instruction
 *   V7 agent: random vectored edge interrupts (ids 12-15) over a loop of divides,
 *      multiplies, loads, stores and branches, for the fetch-stage coverage bins
 */
#include "px_test.h"

#define TRIG(id, lat)   (((lat) << 24) | ((id) << 16))
#define TRIG_LEVEL      0x40000000
/* frame fields beyond crt0's (TF_* < 48) */
#define F_CAUSE    48     /* last vectored handler: mcause, mepc, mintstatus */
#define F_EPC      52
#define F_INTST    56
#define F_NCAUSE   60     /* last NBASE interrupt: mcause, mepc */
#define F_NEPC     64
#define F_NIRQ     68     /* NBASE interrupts */
#define F_RECOVER  72     /* the next vectored handler returns to F_RESUME (V5) */
#define F_RESUME   76
#define F_FIX1     80     /* table fault handler: next mepc (one use), then F_FIX2 */
#define F_FIX2     84
#define F_LOGP     88     /* exception log pointer: cause, epc, tval per exception */
#define F_VCNT     96     /* + 4 * id: vectored takes per id (ids 0-15) */

#define ARM(val) li t5, val; li t6, IRQTRIG; sw t5, 0(t6)
#define CFG(id, l, attr, ie) li t5, CLIC_WORD(l, attr, ie); li t6, CLIC_ENTRY(id); sw t5, 0(t6)
#define VCNT(reg, id) li t4, TRAP_FRAME; lw reg, (F_VCNT + 4 * (id))(t4)
#define FIELD(reg, f) li t4, TRAP_FRAME; lw reg, f(t4)
/* wait (bounded) until the vectored count of id reaches n; fail as test t otherwise */
#define WAIT_V(t, id, n) \
  li gp, t; li t3, 300; \
  9993: VCNT(t4, id); li t6, n; beq t4, t6, 9994f; \
  addi t3, t3, -1; bnez t3, 9993b; j fail_handler; 9994:
#define WAIT_N(t, n) \
  li gp, t; li t3, 300; \
  9993: FIELD(t4, F_NIRQ); li t6, n; beq t4, t6, 9994f; \
  addi t3, t3, -1; bnez t3, 9993b; j fail_handler; 9994:
/* 24 plain instructions: a declared-latency take lands on one of them in ideal mode */
#define SLED .rept 24; addi x0, x0, 0; .endr

  .text
  .globl test_main
test_main:
  li   t0, TRAP_FRAME
  la   t1, exc_log
  sw   t1, F_LOGP(t0)
  sw   zero, F_NIRQ(t0)
  sw   zero, F_RECOVER(t0)
  addi t1, t0, F_VCNT
  addi t2, t1, 64
1:
  sw   zero, 0(t1)
  addi t1, t1, 4
  bltu t1, t2, 1b

  /* CLIC mode, table at vectab */
  la   t0, isr_nbase
  ori  t0, t0, 3
  csrw mtvec, t0
  la   t0, vectab
  csrw CSR_MTVT, t0
  csrr a0, CSR_MTVT
  CHECK_REG(1, a0, t0)
  CFG(7, 3, CLIC_ATTR_EDGE, 1)                       /* non-vectored */
  CFG(8, 5, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  CFG(9, 5, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  CFG(10, 5, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  CFG(11, 9, 0, 1)                                   /* level-triggered, non-vectored */
  li   t0, CLIC_ENTRY(8)
  lw   a0, 0(t0)
  CHECK(2, a0, 0x5FC30100)                           /* level 5, mode 11, edge, shv, enabled */
  csrsi mstatus, 8

  /* ---- V1: vectored entry, latency 6 ---- */
  ARM(TRIG(8, 6) | 4)
  SLED
  WAIT_V(3, 8, 1)
  FIELD(a0, F_CAUSE)
  CHECK(4, a0, 0xB8000008)                           /* interrupt, mpp 11, mpie 1, mpil 0, minhv 0 */
  FIELD(a0, F_INTST)
  CHECK(5, a0, 0x5F000000)                           /* mil = the level in the handler */
  csrr a0, CSR_MINTSTATUS
  CHECK(6, a0, 0)                                    /* MRET restored mil = mpil = 0 */
  li   t0, CLIC_ENTRY(8)
  lw   a0, 0(t0)
  CHECK(7, a0, 0x5FC30100)                           /* the take cleared the edge pending bit */
  .rept 20
  addi x0, x0, 0
  .endr
  VCNT(a0, 8)
  CHECK(8, a0, 1)                                    /* no retrigger */

  /* ---- V2: handler at a halfword offset, latency 7 ---- */
  ARM(TRIG(9, 7) | 4)
  SLED
  WAIT_V(9, 9, 1)
  FIELD(a0, F_CAUSE)
  CHECK(10, a0, 0xB8000009)

  /* ---- V3: table word with bit 0 set ---- */
  ARM(TRIG(10, 6) | 4)
  SLED
  WAIT_V(11, 10, 1)

  /* ---- V4: non-vectored in the same program, latency 4 ---- */
  ARM(TRIG(7, 4) | 4)
  SLED
  WAIT_N(12, 1)
  FIELD(a0, F_NCAUSE)
  CHECK(13, a0, 0xB8000007)

  /* ---- V5/V6: table fetch fault, MRET refetch (fault, then good), refetch deferral ---- */
  li   t0, TRAP_FRAME
  li   t1, 0x44                   /* first refetch: another unmapped entry */
  sw   t1, F_FIX1(t0)
  la   t1, vectab + 4 * 8         /* then the good entry of id 8 */
  sw   t1, F_FIX2(t0)
  la   t1, v5_resume
  sw   t1, F_RESUME(t0)
  li   t1, 1
  sw   t1, F_RECOVER(t0)
  csrw CSR_MTVT, zero             /* entry of id 8 at 0x20: unmapped, the fetch faults */
  ARM(TRIG(8, 0) | 4)
  li   gp, 14
  li   t3, 400
1:
  addi t3, t3, -1                 /* the take happens here; the context is lost */
  bnez t3, 1b
  j    fail_handler
v5_resume:
  la   t0, vectab
  csrw CSR_MTVT, t0
  la   t0, exc_log
  lw   a0, 0(t0)
  CHECK(15, a0, 0x705F0001)       /* exception 1, minhv 1, mpp 11, mpie 0, mpil 0x5F */
  lw   a0, 4(t0)
  CHECK(16, a0, 0x20)             /* mepc = the table address */
  lw   a0, 8(t0)
  CHECK(17, a0, 0x20)             /* mtval = the table address */
  lw   a0, 12(t0)
  CHECK(18, a0, 0x5F000000)       /* mil unchanged by the fault (the take raised it) */
  lw   a0, 16(t0)
  CHECK(19, a0, 0x705F0001)       /* the refetch fault: same state */
  lw   a0, 20(t0)
  CHECK(20, a0, 0x44)
  lw   a0, 24(t0)
  CHECK(21, a0, 0x44)
  lw   a0, 28(t0)
  CHECK(22, a0, 0x5F000000)       /* MRET restored mil = mpil = 0x5F before the refetch */
  VCNT(a0, 8)
  CHECK(23, a0, 2)                /* the good refetch reached the handler */
  FIELD(a0, F_NCAUSE)
  CHECK(24, a0, 0xB85F000B)       /* V6: id 11, mpie 1, mpil 0x5F (the refetch's level) */
  FIELD(a0, F_NEPC)
  la   a1, isr_v8
  CHECK_REG(25, a0, a1)           /* taken right after the refetch: mepc = the handler */
  FIELD(a0, F_CAUSE)
  CHECK(26, a0, 0xB85F000B)       /* the handler ran after id 11's MRET */
  csrr a0, CSR_MINTSTATUS
  CHECK(27, a0, 0)
  csrr a0, mstatus
  andi a0, a0, 8
  CHECK(28, a0, 8)

  /* ---- V7: random vectored interrupts over a mixed loop ---- */
  CFG(12, 3, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  CFG(13, 4, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  CFG(14, 3, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  CFG(15, 6, CLIC_ATTR_EDGE | CLIC_ATTR_SHV, 1)
  li   t0, 0x80000000 | (10 << 12) | (4 << 6) | 12   /* ids 12-15, an event every ~1024
                                  cycles: a handler costs ~300 cycles in the long-latency
                                  mode, and more frequent events keep killing the divide */
  li   t1, AGENT
  sw   t0, 0(t1)
  la   s2, buf
  li   s3, 200
  li   s4, 0x12345
  li   s5, 7
v7_loop:
  div  s6, s4, s5
  sw   s6, 0(s2)
  mul  s7, s6, s5
  lw   s8, 0(s2)
  add  s4, s4, s8
  c.addi s5, 1
  andi t0, s3, 3
  beqz t0, 1f
  xor  s4, s4, s7
1:
  lh   s9, 2(s2)
  c.add s4, s9
  addi s3, s3, -1
  bnez s3, v7_loop
  li   t1, AGENT
  sw   zero, 0(t1)
  .rept 40
  addi x0, x0, 0
  .endr
  VCNT(a0, 12)
  VCNT(a1, 13)
  add  a0, a0, a1
  VCNT(a1, 14)
  add  a0, a0, a1
  VCNT(a1, 15)
  add  a0, a0, a1
  li   gp, 29
  beqz a0, fail_handler           /* the agent's interrupts were taken */

  PASS

/* ------------------------------------------------------------------ vector table */
  .section .vectab, "ax"
  .balign 64
  .globl vectab
vectab:
  .word isr_bad, isr_bad, isr_bad, isr_bad, isr_bad, isr_bad, isr_bad, isr_bad
  .word isr_v8
  .word exempt_halfword_v9
  .word isr_v10 + 1               /* bit 0 set: ignored (K-72) */
  .word isr_bad
  .word isr_vgen, isr_vgen, isr_vgen, isr_vgen

/* ------------------------------------------------------------------ handlers */
  .text
  .balign 4
  .globl isr_v8
isr_v8:
  csrrw sp, mscratch, sp
  sw   t0, TF_T0(sp)
  li   t0, 8
  j    v_common

  .balign 4
  c.nop                           /* the next handler starts at a halfword offset */
  .globl exempt_halfword_v9
exempt_halfword_v9:
  csrrw sp, mscratch, sp          /* 32-bit first instruction (D-029 negative test) */
  sw   t0, TF_T0(sp)
  li   t0, 9
  j    v_common

  .balign 4
  .globl isr_v10
isr_v10:
  csrrw sp, mscratch, sp
  sw   t0, TF_T0(sp)
  li   t0, 10
  j    v_common

  .balign 4
  .globl isr_vgen
isr_vgen:
  csrrw sp, mscratch, sp
  sw   t0, TF_T0(sp)
  csrr t0, mcause
  andi t0, t0, 0x3F
  j    v_common

  .balign 4
  .globl isr_bad
isr_bad:
  li   gp, 0x7FE
  j    fail_handler

v_common:                         /* t0 = id; sp = frame */
  sw   t1, TF_T1(sp)
  sw   t2, TF_T2(sp)
  slli t1, t0, 2
  add  t1, t1, sp
  lw   t2, F_VCNT(t1)
  addi t2, t2, 1
  sw   t2, F_VCNT(t1)
  csrr t1, mcause
  sw   t1, F_CAUSE(sp)
  csrr t1, mepc
  sw   t1, F_EPC(sp)
  csrr t1, CSR_MINTSTATUS
  sw   t1, F_INTST(sp)
  lw   t1, F_RECOVER(sp)
  beqz t1, v_ret
  sw   zero, F_RECOVER(sp)        /* V5: the interrupted context is lost: resume the test */
  lw   t1, F_RESUME(sp)
  csrw mepc, t1
  li   t1, 0x08000000             /* mcause: minhv 0, mpil 0, mpie 1 (MIE after MRET) */
  csrw mcause, t1
v_ret:
  lw   t0, TF_T0(sp)
  lw   t1, TF_T1(sp)
  lw   t2, TF_T2(sp)
  csrrw sp, mscratch, sp
  mret

  .balign 64
  .globl isr_nbase
isr_nbase:
  csrrw sp, mscratch, sp
  sw   t0, TF_T0(sp)
  sw   t1, TF_T1(sp)
  sw   t2, TF_T2(sp)
  csrr t0, mcause
  bgez t0, n_exc
  sw   t0, F_NCAUSE(sp)           /* non-vectored interrupt */
  csrr t1, mepc
  sw   t1, F_NEPC(sp)
  lw   t1, F_NIRQ(sp)
  addi t1, t1, 1
  sw   t1, F_NIRQ(sp)
  andi t0, t0, 0x3F
  slli t1, t0, 2                  /* clear the edge pending bit */
  li   t2, CLIC_INTIP
  add  t2, t2, t1
  sb   zero, 0(t2)
  li   t2, IRQCLR                 /* drop a held level input */
  sw   t0, 0(t2)
  j    n_ret
n_exc:                            /* only table fetch faults are expected */
  lw   t1, F_LOGP(sp)
  sw   t0, 0(t1)
  csrr t2, mepc
  sw   t2, 4(t1)
  csrr t2, mtval
  sw   t2, 8(t1)
  csrr t2, CSR_MINTSTATUS
  sw   t2, 12(t1)
  addi t1, t1, 16
  sw   t1, F_LOGP(sp)
  li   t1, 0x40000000             /* minhv */
  and  t1, t0, t1
  beqz t1, n_fatal
  andi t0, t0, 0x3F
  li   t1, CAUSE_IACCESS
  bne  t0, t1, n_fatal
  lw   t1, F_FIX1(sp)
  beqz t1, 1f
  sw   zero, F_FIX1(sp)
  csrw mepc, t1                   /* refetch at another unmapped entry: faults again */
  j    n_ret
1:
  lw   t1, F_FIX2(sp)
  csrw mepc, t1                   /* refetch at the good entry */
  li   t1, 0x80
  csrs mstatus, t1                /* V6: MPIE = 1, so the MRET enables interrupts ... */
  li   t1, TRIG(11, 0) | TRIG_LEVEL
  li   t2, IRQTRIG
  sw   t1, 0(t2)                  /* ... with id 11 (level 0x9F > mil 0x5F) pending */
  li   t2, CLIC_ENTRY(11)
2:
  lbu  t1, 0(t2)
  beqz t1, 2b
n_ret:
  lw   t0, TF_T0(sp)
  lw   t1, TF_T1(sp)
  lw   t2, TF_T2(sp)
  csrrw sp, mscratch, sp
  mret
n_fatal:
  li   gp, 0x7FD
  j    fail_handler

  .data
  .balign 4
buf:     .word 0x00C0FFEE, 0
exc_log: .space 64

  TRAPS(2)
  TRAP(CAUSE_IACCESS, 0x20, 0x20)
  TRAP(CAUSE_IACCESS, 0x44, 0x44)
