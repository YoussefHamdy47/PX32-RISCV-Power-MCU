/* t08_timing: cycle-exact checks of ARCHITECTURE.md § 4.1 with single-cycle memories.
 * Each block is bracketed by timing markers; the testbench checks that the end marker
 * retires exactly DELTA cycles after the start marker. DELTA counts every instruction
 * between the markers plus the end marker itself, plus any penalty:
 *   ALU op 1, load 1 (+1 if the next instruction uses it), taken branch / JALR /
 *   FENCE.I 3, not-taken branch 1, JAL 2, 32-bit branch target at a halfword offset +1. */
#include "px_test.h"

#define BLOCK(id, delta)  MARK_PREP(s0, 0, 0); MARK_PREP(s1, id, delta); MARK_REG(s0)
#define END               MARK_REG(s1)

  .data
  .balign 4
tv:   .word 5, 6

  .text
  .globl test_main
test_main:
  .option norvc
  MARK_BASE
  la   a1, tv
  la   a5, 7f

  /* 1. three independent ALU ops: 3 + end marker */
  BLOCK(1, 4)
  add  a2, a3, a4
  add  a3, a4, a2
  add  a4, a2, a3
  END
  /* 2. dependent ALU chain, fully forwarded: no stall */
  BLOCK(2, 4)
  addi a0, x0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  END
  /* 3. load, result unused next: 2 + end */
  BLOCK(3, 3)
  lw   a0, 0(a1)
  addi a2, a3, 1
  END
  /* 4. load-use stall: 1 + 1 stall + 1 + end */
  BLOCK(4, 4)
  lw   a0, 0(a1)
  addi a2, a0, 1
  END
  /* 5. load into store data: load-use stall */
  BLOCK(5, 4)
  lw   a0, 0(a1)
  sw   a0, 4(a1)
  END
  /* 6. two stores back to back */
  BLOCK(6, 3)
  sw   a2, 4(a1)
  sw   a2, 4(a1)
  END
  /* 7. not-taken branch: 1 + end */
  BLOCK(7, 2)
  bne  x0, x0, 6f                 /* local target: a far global target would be relaxed */
  END                             /* by the assembler into a taken branch over a jal */
  j    8f
6:
  j    fail_handler
8:
  /* 8. taken branch: 3 + end */
  BLOCK(8, 4)
  beq  x0, x0, 1f
  nop
  nop
1:
  END
  /* 9. JAL: 2 + end */
  BLOCK(9, 3)
  jal  x0, 2f
  nop
2:
  END
  /* 10. JALR: 3 + end (a5 = label 7) */
  BLOCK(10, 4)
  jalr x0, 0(a5)
  nop
7:
  END
  /* 11. FENCE.I: 3 + end */
  BLOCK(11, 4)
  fence.i
  END
  /* 12. branch after a load that feeds it: load-use stall, then taken branch */
  BLOCK(12, 6)
  lw   a0, 0(a1)
  bne  a0, x0, 3f
  nop
3:
  END

  .option rvc
  /* 13. compressed ALU ops: 1 each */
  .balign 4
  BLOCK(13, 4)
  c.addi a0, 1
  c.addi a0, 1
  c.addi a0, 1
  END
  /* 14. 32-bit ops straddling word boundaries after a c.nop: no penalty */
  .balign 4
  BLOCK(14, 5)
  c.nop
  .option push
  .option norvc
  add  a2, a3, a4
  add  a3, a4, a2
  add  a4, a2, a3
  .option pop
  END
  /* 15. taken branch to a 32-bit instruction at a halfword offset: 3 + 1 + end */
  .balign 4
  BLOCK(15, 5)
  .option push
  .option norvc
  beq  x0, x0, 4f
  .option pop
  .balign 4
  c.nop
4:
  .option push
  .option norvc
  END
  .option pop
  /* 16. taken branch to a 16-bit instruction at a halfword offset: no extra cycle */
  .balign 4
  BLOCK(16, 5)
  .option push
  .option norvc
  beq  x0, x0, 5f
  .option pop
  .balign 4
  c.nop
5:
  c.addi a0, 1
  .option push
  .option norvc
  END
  .option pop
  PASS
