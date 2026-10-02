/* t10_csr: Zicsr instructions and the CSR map (step 1.6, D-022).
 *   A. fixed and identification registers, reset-visible values
 *   B. all six instruction forms, old value returned, new value written
 *   C. read/write suppression decided by the encoding: CSRRS/CSRRC with rs1 = x0 and the
 *      immediate forms with zimm = 0 do not write (legal on read-only CSRs); a nonzero rs1
 *      field writes even when the register holds 0; CSRRW/CSRRWI always write, also with
 *      rd = x0 (csrrw x0, cycle, x0 traps)
 *   D. unimplemented CSRs trap, rd unchanged, mtval = instruction bits
 *   E. WARL/read-only fields: mstatus, mtvec, mepc, mcause, misa, mie, mip, mstatush,
 *      hardware performance monitor, PMP
 *   F. dependencies: operands forwarded from ALU, load (load-use) and CSR results; CSR
 *      results forwarded to ALU, branch, store data and the next CSR; a write is seen by
 *      the next instruction
 *   G. cancellation: CSR writes on the wrong path of a taken branch/JAL/JALR, behind a
 *      trapping instruction and behind an older load/store bus error have no effect
 * The traps are listed at the end; the testbench also compares every retirement with the
 * reference model. */
#include "px_test.h"

#define FAULT_ADDR 0x30000000

  .data
  .balign 4
cbuf: .word 0x13572468, 0, 0, 0

  .text
  .globl test_main
test_main:
  .option norvc
  la   s0, cbuf
  li   s2, FAULT_ADDR

  /* ---------------- A. fixed registers ---------------- */
  csrr a0, misa
  CHECK(1, a0, 0x40001104)
  csrr a0, mvendorid
  CHECK(2, a0, 0)
  csrr a0, marchid
  CHECK(3, a0, 0)
  csrr a0, mimpid
  CHECK(4, a0, 0)
  csrr a0, mhartid
  CHECK(5, a0, 0)
  csrr a0, 0xF15                       /* mconfigptr */
  CHECK(6, a0, 0)
  csrr a0, mstatus
  CHECK(7, a0, 0x1800)                 /* MPP = M, MIE = MPIE = 0 */
  csrr a0, 0x310                       /* mstatush */
  CHECK(8, a0, 0)
  csrr a0, mie
  CHECK(9, a0, 0)
  csrr a0, mip
  CHECK(10, a0, 0)
  csrr a0, mtvec
  la   a1, trap_entry
  CHECK_REG(11, a0, a1)
  csrr a0, mscratch
  CHECK(12, a0, TRAP_FRAME)
  csrr a0, mtval
  CHECK(13, a0, 0)
  csrr a0, mcause
  CHECK(14, a0, 0)

  /* ---------------- B. six forms on mtval ---------------- */
  li   a1, 0x0F0F0F0F
  csrrw a0, mtval, a1                  /* operand forwarded from the addi of li */
  CHECK(20, a0, 0)
  li   a2, 0xF0000000
  csrrs a0, mtval, a2
  CHECK(21, a0, 0x0F0F0F0F)
  li   a3, 0x0000000F
  csrrc a0, mtval, a3
  CHECK(22, a0, 0xFF0F0F0F)
  csrrwi a0, mtval, 21
  CHECK(23, a0, 0xFF0F0F00)
  csrrsi a0, mtval, 10
  CHECK(24, a0, 21)
  csrrci a0, mtval, 1
  CHECK(25, a0, 31)
  csrr a0, mtval
  CHECK(26, a0, 30)
  csrrci a0, mtval, 31                 /* clear all of zimm's bits */
  CHECK(27, a0, 30)
  csrr a0, mtval
  CHECK(28, a0, 0)
  li   a1, 0xCAFEF00D                  /* rd = x0: CSRRW still writes */
  csrrw x0, mtval, a1
  csrr a0, mtval
  CHECK(29, a0, 0xCAFEF00D)
  csrrwi x0, mtval, 7
  csrr a0, mtval
  CHECK(30, a0, 7)

  /* ---------------- C. suppression by encoding ---------------- */
  li   a0, 0x55
  csrrs a0, mhartid, x0                /* no write: legal on a read-only CSR */
  CHECK(40, a0, 0)
  li   a0, 0x55
  csrrc a0, mvendorid, x0
  CHECK(41, a0, 0)
  li   a0, 0x55
  csrrsi a0, marchid, 0
  CHECK(42, a0, 0)
  li   a0, 0x55
  csrrci a0, mimpid, 0
  CHECK(43, a0, 0)
  li   a0, 0x55
  li   a1, 0                           /* rs1 = a1 holds 0, but the field is nonzero */
t_rs_ro:
  csrrs a0, mhartid, a1                /* write attempt: illegal, a0 unchanged */
  CHECK(44, a0, 0x55)
  CHECK_TRAP(45, TF_CAUSE, CAUSE_ILLEGAL)
  la   a2, t_rs_ro
  li   t5, TRAP_FRAME
  lw   t5, TF_EPC(t5)
  CHECK_REG(46, t5, a2)
t_rc_ro:
  csrrc a0, mhartid, a1
t_rsi_ro:
  csrrsi a0, marchid, 1
t_rci_ro:
  csrrci a0, 0xF15, 4
t_rw_ro:
  csrrw x0, mhartid, x0                /* CSRRW always writes, rd = x0 or not */
t_rwi_ro:
  csrrwi x0, mimpid, 0
t_unimp:
  csrrw x0, 0xC00, x0                  /* 0xC0001073, canonical UNIMP: must trap */
  CHECK(47, a0, 0x55)
  CHECK_TRAP(48, TF_TVAL, 0xC0001073)

  /* ---------------- D. unimplemented CSRs ---------------- */
  li   a0, 0x66
t_cycle:
  csrr a0, 0xC00                       /* cycle (Zicntr not implemented) */
t_time:
  csrr a0, 0xC01
t_instret:
  csrr a0, 0xC02
t_fflags:
  csrr a0, 0x001
t_mcntinh:
  csrr a0, 0x320                       /* mcountinhibit */
t_mcnten:
  csrr a0, 0x306                       /* mcounteren: no U-mode */
t_satp:
  csrr a0, 0x180
t_tselect:
  csrr a0, 0x7A0
t_dcsr:
  csrr a0, 0x7B0
t_b01:
  csrr a0, 0xB01                       /* hole between mcycle and minstret */
t_menvcfg:
  csrrs a0, 0x30A, x0
t_mtinst:
  csrrw x0, 0x34A, a1                  /* no read, but the CSR does not exist */
  CHECK(50, a0, 0x66)
  CHECK_TRAP(51, TF_TVAL, 0x34A59073)

  /* ---------------- E. WARL and read-only fields ---------------- */
  li   a1, -1
  csrw mstatus, a1
  csrr a0, mstatus
  CHECK(60, a0, 0x1888)                /* MIE, MPIE, MPP = M; nothing else */
  csrc mstatus, a1
  csrr a0, mstatus
  CHECK(61, a0, 0x1800)
  csrsi mstatus, 8
  csrr a0, mstatus
  CHECK(62, a0, 0x1808)
  csrci mstatus, 8
  csrw misa, x0
  csrr a0, misa
  CHECK(63, a0, 0x40001104)
  csrw mie, a1
  csrr a0, mie
  CHECK(64, a0, 0)
  csrs mip, a1                         /* writes to mip are ignored, not illegal */
  csrr a0, mip
  CHECK(65, a0, 0)
  csrw 0x310, a1
  csrr a0, 0x310
  CHECK(66, a0, 0)
  csrr s1, mtvec                       /* no trap may occur while mtvec is changed */
  csrw mtvec, a1
  csrr a0, mtvec
  CHECK(67, a0, 0xFFFFFFFC)            /* BASE only: MODE reads Direct */
  addi a2, s1, 1                       /* MODE = vectored: not implemented */
  csrw mtvec, a2
  csrr a0, mtvec
  CHECK_REG(68, a0, s1)
  addi a2, s1, 3                       /* MODE = 3 (CLIC in Phase 2) */
  csrw mtvec, a2
  csrr a0, mtvec
  CHECK_REG(69, a0, s1)
  li   a2, 0x12345679
  csrw mepc, a2
  csrr a0, mepc
  CHECK(70, a0, 0x12345678)            /* bit 0 always zero */
  li   a2, 0x1234567B
  csrw mepc, a2
  csrr a0, mepc
  CHECK(71, a0, 0x1234567A)            /* bit 1 kept: IALIGN = 16 */
  csrw mcause, a1
  csrr a0, mcause
  CHECK(72, a0, 0x8000001F)
  csrw mtval, a1
  csrr a0, mtval
  CHECK(73, a0, 0xFFFFFFFF)
  csrw 0xB03, a1                       /* mhpmcounter3 */
  csrr a0, 0xB03
  CHECK(74, a0, 0)
  csrw 0xB9F, a1                       /* mhpmcounter31h */
  csrr a0, 0xB9F
  CHECK(75, a0, 0)
  csrw 0x323, a1                       /* mhpmevent3 */
  csrr a0, 0x33F                       /* mhpmevent31 */
  CHECK(76, a0, 0)
  csrw 0x3A0, a1                       /* pmpcfg0 */
  csrr a0, 0x3A0
  CHECK(77, a0, 0)
  csrw 0x3EF, a1                       /* pmpaddr63 */
  csrr a0, 0x3EF
  CHECK(78, a0, 0)

  /* ---------------- F. dependencies ---------------- */
  li   a1, 0x1234
  csrw mtval, a1
  csrr a2, mtval                       /* write seen by the next instruction */
  CHECK(80, a2, 0x1234)
  csrrw a2, mtval, a1                  /* back-to-back accesses to one CSR */
  csrrw a3, mtval, a2
  csrr a4, mtval
  CHECK(81, a3, 0x1234)
  CHECK(82, a4, 0x1234)
  csrr a2, mtval
  addi a3, a2, 1                       /* CSR result forwarded to the ALU */
  CHECK(83, a3, 0x1235)
  lw   a5, 0(s0)                       /* load-use into the CSR operand */
  csrrw a2, mtval, a5
  csrr a3, mtval
  CHECK(84, a3, 0x13572468)
  csrr a2, mtval                       /* CSR result forwarded into a branch */
  bne  a2, a5, 1f
  j    2f
1:
  CHECK(85, x0, 1)
2:
  csrr a2, mtval                       /* ... into store data */
  sw   a2, 4(s0)
  lw   a3, 4(s0)
  CHECK(86, a3, 0x13572468)
  csrr a2, mcause                      /* ... into the next CSR's operand */
  csrrw a3, mtval, a2
  csrr a4, mtval
  CHECK(87, a4, 0x8000001F)
  csrrwi a2, mtval, 9
  addi a2, s0, 8
  csrrw a3, mscratch, a2               /* mscratch: restored right after */
  csrrw a4, mscratch, a3
  CHECK_REG(88, a4, a2)
  csrr a0, mscratch
  CHECK(89, a0, TRAP_FRAME)

  /* ---------------- G. cancellation ---------------- */
  la   s3, bad_vector
  csrr s1, mtvec
  li   a1, 0x0BAD
  csrw mtval, x0
  beq  x0, x0, 1f                      /* wrong path of a taken branch */
  csrw mtval, a1
  csrw mtvec, s3
1:
  jal  x0, 2f                          /* wrong path of a JAL */
  csrw mtval, a1
  csrw mtvec, s3
2:
  la   a2, 3f
  jalr x0, 0(a2)                       /* wrong path of a JALR */
  csrw mtval, a1
  csrw mtvec, s3
3:
  csrr a0, mtval
  CHECK(90, a0, 0)
  csrr a0, mtvec
  CHECK_REG(91, a0, s1)
  EXPECT_TRAP(4f)
t_g_ecall:
  ecall                                /* flushed behind a trapping instruction */
  csrw mtvec, s3
  csrw minstret, x0
4:
  csrr a0, mtvec
  CHECK_REG(92, a0, s1)
  csrr a0, minstret
  li   a1, 100
  bltu a1, a0, 5f                      /* minstret was not cleared */
  CHECK(93, x0, 1)
5:
  EXPECT_TRAP(6f)
t_g_lacc:
  lw   a0, 0(s2)                       /* older load bus error in WB */
  csrw mtvec, s3
  csrw minstret, x0
6:
  csrr a0, mtvec
  CHECK_REG(94, a0, s1)
  EXPECT_TRAP(7f)
t_g_sacc:
  sw   a0, 0(s2)                       /* older store bus error in WB */
  csrw mtvec, s3
7:
  csrr a0, mtvec
  CHECK_REG(95, a0, s1)
  csrr a0, minstret
  li   a1, 100
  bltu a1, a0, 8f
  CHECK(96, x0, 1)
8:
  CHECK_TRAP(97, TF_COUNT, 22)
  PASS

  .balign 4
bad_vector:                            /* reached only if a cancelled mtvec write landed */
  li   gp, 99
  j    fail_handler

  TRAPS(22)
  TRAP(CAUSE_ILLEGAL, t_rs_ro,  0xF145A573)
  TRAP(CAUSE_ILLEGAL, t_rc_ro,  0xF145B573)
  TRAP(CAUSE_ILLEGAL, t_rsi_ro, 0xF120E573)
  TRAP(CAUSE_ILLEGAL, t_rci_ro, 0xF1527573)
  TRAP(CAUSE_ILLEGAL, t_rw_ro,  0xF1401073)
  TRAP(CAUSE_ILLEGAL, t_rwi_ro, 0xF1305073)
  TRAP(CAUSE_ILLEGAL, t_unimp,  0xC0001073)
  TRAP(CAUSE_ILLEGAL, t_cycle,  0xC0002573)
  TRAP(CAUSE_ILLEGAL, t_time,   0xC0102573)
  TRAP(CAUSE_ILLEGAL, t_instret, 0xC0202573)
  TRAP(CAUSE_ILLEGAL, t_fflags, 0x00102573)
  TRAP(CAUSE_ILLEGAL, t_mcntinh, 0x32002573)
  TRAP(CAUSE_ILLEGAL, t_mcnten, 0x30602573)
  TRAP(CAUSE_ILLEGAL, t_satp,   0x18002573)
  TRAP(CAUSE_ILLEGAL, t_tselect, 0x7A002573)
  TRAP(CAUSE_ILLEGAL, t_dcsr,   0x7B002573)
  TRAP(CAUSE_ILLEGAL, t_b01,    0xB0102573)
  TRAP(CAUSE_ILLEGAL, t_menvcfg, 0x30A02573)
  TRAP(CAUSE_ILLEGAL, t_mtinst, 0x34A59073)
  TRAP(CAUSE_ECALL_M, t_g_ecall, 0)
  TRAP(CAUSE_LACCESS, t_g_lacc, FAULT_ADDR)
  TRAP(CAUSE_SACCESS, t_g_sacc, FAULT_ADDR)
