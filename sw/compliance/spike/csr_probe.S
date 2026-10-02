/* csr_probe.S: D-022 CSR choices and platform behaviour probed on PX32 and on Spike (step 1.9).
 *
 * Not self-checking: scripts/compliance/run_trace_compare.py runs it on tb_compliance and on
 * Spike and compares the two traces. Every access below either reads a value into a register
 * (compared on retirement) or traps (cause, epc and tval compared). The expected outcome is a
 * list of classified differences (DECISIONS.md D-026), not a match: the probe exists to show
 * each difference between PX32's D-022 choices and Spike's fixed behaviour on its own, one
 * section per choice, so that every classification in D-026 rests on an observed result.
 * Built once per section with -DONLY=<n> (the section alone) and once without (all sections).
 *
 * The trap handler skips the trapping instruction (2 or 4 bytes) and returns. a0 holds the
 * section number. Built with sw/compliance/riscv-tests/link.ld (tohost section). */

  .section .text.init, "ax"
  .option norvc
  .globl _start
_start:
  la   t0, handler
  csrw mtvec, t0
  li   a0, 0
  j    sections

  .balign 64
handler:
  csrr t5, mepc
  lhu  t6, 0(t5)
  andi t6, t6, 3
  addi t5, t5, 2
  addi t6, t6, -3
  bnez t6, 1f
  addi t5, t5, 2
1:
  csrw mepc, t5
  mret

#if defined(ONLY)
#define SEC(n) (ONLY == (n))
#else
#define SEC(n) 1
#endif

sections:
  /* 1: reads of every D-022 CSR (identification, status, trap, counters, hpm; PMP in 15) */
#if SEC(1)
  li   a0, 1
  csrr s0, mstatus
  csrr s0, misa
  csrr s0, mie
  csrr s0, mip
  csrr s0, mtvec
  csrr s0, mscratch
  csrr s0, mepc
  csrr s0, mcause
  csrr s0, mtval
  csrr s0, mstatush
  csrr s0, mvendorid
  csrr s0, mimpid
  csrr s0, mhartid
  csrr s0, 0xF15                  /* mconfigptr */
  csrr s0, minstret
  csrr s0, minstreth
  csrr s0, 0xB03                  /* mhpmcounter3 */
  csrr s0, 0xB9F                  /* mhpmcounter31h */
  csrr s0, 0x323                  /* mhpmevent3 */
  csrr s0, 0x33F                  /* mhpmevent31 */
#endif

  /* 2: marchid (D-022: 0) */
#if SEC(2)
  li   a0, 2
  csrr s0, marchid
#endif

  /* 3: WARL writes: mstatus, mstatush, mepc, mtval, mscratch, hpm, counters, mcause */
#if SEC(3)
  li   a0, 3
  li   s1, -1
  csrrw s0, mstatus, s1
  csrr s0, mstatus
  csrrw s0, mstatus, zero
  csrrw s0, mstatush, s1
  csrr s0, mstatush
  csrrw s0, mepc, s1
  csrr s0, mepc
  csrrw s0, mtval, s1
  csrrw s0, mscratch, s1
  csrrw s0, 0xB03, s1
  csrrw s0, 0xB9F, s1
  csrrw s0, 0x323, s1
  csrr s0, 0xB03
  li   s1, 100
  csrw minstret, s1
  csrr s0, minstret
  csrw minstreth, s1
  csrr s0, minstreth
  csrw minstreth, zero
  li   s1, 0x8000000B
  csrw mcause, s1
  csrr s0, mcause
#endif

  /* 4: misa writes (D-022: writes ignored) */
#if SEC(4)
  li   a0, 4
  csrrw s0, misa, zero
  csrr s0, misa
  li   s1, 0x40001104
  csrw misa, s1
  csrr s0, misa
#endif

  /* 5: mie writes (D-022: read-only 0 before the CLIC) */
#if SEC(5)
  li   a0, 5
  li   s1, -1
  csrrw s0, mie, s1
  csrr s0, mie
  csrrw s0, mie, zero
#endif

  /* 6: mtvec MODE (D-022: Direct only) */
#if SEC(6)
  li   a0, 6
  la   s1, handler
  ori  s2, s1, 1
  csrrw s0, mtvec, s2
  csrrw s0, mtvec, s1
  ori  s2, s1, 2
  csrrw s0, mtvec, s2
  csrrw s0, mtvec, s1
#endif

  /* 7: CSRs PX32 does not implement (D-022/D-025: illegal) */
#if SEC(7)
  li   a0, 7
  csrr s0, 0xC00                  /* cycle */
  csrr s0, 0xC01                  /* time */
  csrr s0, 0xC02                  /* instret */
  csrr s0, 0xC80                  /* cycleh */
  csrr s0, 0xC03                  /* hpmcounter3 */
  csrr s0, 0x001                  /* fflags */
  csrr s0, 0x003                  /* fcsr */
  csrr s0, 0x180                  /* satp */
  csrr s0, 0x100                  /* sstatus */
  csrr s0, 0x302                  /* medeleg */
  csrr s0, 0x303                  /* mideleg */
  csrr s0, 0x34A                  /* mtinst */
  csrr s0, 0x34B                  /* mtval2 */
  csrr s0, 0x7B0                  /* dcsr */
  csrr s0, 0x7B1                  /* dpc */
  csrr s0, 0x7C0                  /* custom */
  csrr s0, 0x800                  /* custom */
  csrr s0, 0xFFF
#endif

  /* 8: mcountinhibit (D-022: illegal) */
#if SEC(8)
  li   a0, 8
  csrr s0, 0x320
#endif

  /* 9: mcounteren, menvcfg(h), mseccfg (D-022: illegal) */
#if SEC(9)
  li   a0, 9
  csrr s0, 0x306
  csrr s0, 0x30A
  csrr s0, 0x31A
  csrr s0, 0x747
#endif

  /* 10: trigger CSRs (D-022: illegal; Sdtrig is Phase 7) */
#if SEC(10)
  li   a0, 10
  csrr s0, 0x7A0                  /* tselect */
  csrr s0, 0x7A1                  /* tdata1 */
  csrr s0, 0x7A4                  /* tinfo */
  csrr s0, 0x7A5                  /* tcontrol */
  csrr s0, 0x7A8                  /* mcontext */
#endif

  /* 11: writes to read-only CSRs, unimplemented counters as rd = x0 writes */
#if SEC(11)
  li   a0, 11
  csrrw zero, mvendorid, zero
  csrrs s0, mhartid, s1
  csrrwi s0, 0xF15, 0
  csrrw zero, 0xC00, zero         /* unimp */
#endif

  /* 12: exceptions: ECALL, EBREAK, C.EBREAK, illegal 32/16-bit, misaligned, access faults */
#if SEC(12)
  li   a0, 12
  ecall
  ebreak
  .option rvc
  c.ebreak
  .half 0x0000
  .option norvc
  .word 0xFFFFFFFF
  la   s1, data
  lw   s0, 1(s1)
  lh   s0, 3(s1)
  sw   s0, 2(s1)
  sh   s0, 1(s1)
  li   s1, 0x30000000
  lw   s0, 0(s1)
  sw   s0, 4(s1)
  lb   s0, 3(s1)
  li   s1, 0x10100000           /* first byte after the 1 MB memory */
  lw   s0, 0(s1)
  wfi
#endif

  /* 13: the low 4 KB (Spike's debug module) */
#if SEC(13)
  li   a0, 13
  li   s1, 0
  lw   s0, 0(s1)
  li   s1, 0x800
  lw   s0, 0(s1)
  li   s1, 0x1000
  lw   s0, 0(s1)
#endif

  /* 14: MRET with MPP and MPIE, read back */
#if SEC(14)
  li   a0, 14
  la   s1, 1f
  csrw mepc, s1
  li   s1, 0x80
  csrs mstatus, s1
  mret
  nop
1:
  csrr s0, mstatus
  csrr s0, mepc
#endif

  /* 15: PMP CSRs (D-022: read-only 0, zero PMP entries until step 2.6) */
#if SEC(15)
  li   a0, 15
  li   s1, -1
  csrr s0, 0x3A0                  /* pmpcfg0 */
  csrr s0, 0x3AF                  /* pmpcfg15 */
  csrr s0, 0x3B0                  /* pmpaddr0 */
  csrr s0, 0x3EF                  /* pmpaddr63 */
  csrrw s0, 0x3A0, s1
  csrrw s0, 0x3EF, s1
#endif

  /* 16: mip writes (D-022: read-only 0; Spike without CLINT/PLIC has no pending source) */
#if SEC(16)
  li   a0, 16
  li   s1, -1
  csrrw s0, mip, s1
  csrr s0, mip
  csrrs s0, mip, s1
  csrrc s0, mip, s1
#endif

  /* 17: mcause with an illegal value (WLRL: PX32 keeps bit 31 and the code bits [4:0]) */
#if SEC(17)
  li   a0, 17
  li   s1, 0x7FFFFFFF
  csrw mcause, s1
  csrr s0, mcause
#endif

finish:
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
2: j 2b

  .data
  .balign 16
data:
  .word 0x11223344, 0x55667788

  .section .tohost, "aw", @progbits
  .balign 64
  .globl tohost
tohost: .dword 0
  .balign 64
  .globl fromhost
fromhost: .dword 0
