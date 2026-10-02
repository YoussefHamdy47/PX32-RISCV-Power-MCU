/* px_test.h: macros for self-checking PX32 core test programs (assembly).
 *
 * Conventions
 *   - gp  (x3)  holds the current test number; t6 (x31) is scratch for CHECK, t5 (x30)
 *     for the trap and cycle-check macros.
 *   - PASS writes 1 to tohost; a failure writes ((test + 1) << 1) | 1, which is never 1,
 *     so a failure before any test number is set still reports as a failure.
 *   - Traps go to the crt0 handler, which records mcause/mepc/mtval/mstatus in the trap
 *     frame (TF_*) and resumes at an armed recovery address (EXPECT_TRAP, one use), or
 *     else after the trapping instruction. An instruction access fault needs an armed
 *     recovery address; without one the test fails as test 2047. mscratch holds the frame
 *     address: a test that changes mscratch must restore it before the next trap.
 *   - MARK(id, delta) stores to the timing marker. The testbench checks that this
 *     marker retires exactly `delta` cycles after the previous one (id 0: start only).
 *     Put the value in a register beforehand so no extra instructions are timed:
 *     use MARK_PREP(reg, id, delta) outside the timed region and MARK_REG(reg) inside.
 *   - CYCLE_CHECK(reg, n): reg holds a value measured with mcycle; the testbench checks
 *     it equals n in ideal-memory mode and is at least n in the stall modes.
 *   - TRAPS(n) followed by n TRAP(cause, pc, tval) entries declares the traps the
 *     program must raise, in order; the testbench compares them with what it saw.
 */
#ifndef PX_TEST_H
#define PX_TEST_H

#define TOHOST   0x2000FFF0
#define MARKER   0x2000FFE0
#define CYCEXP   0x2000FFE4               /* CYCCHK = CYCEXP + 4 */

/* Trap handler frame (harness region of DTCM) */
#define TRAP_FRAME 0x2000FF00
#define TF_T0       0
#define TF_T1       4
#define TF_T2       8
#define TF_CAUSE   12
#define TF_EPC     16
#define TF_TVAL    20
#define TF_COUNT   24
#define TF_RESUME  28
#define TF_MSTATUS 32

#define CAUSE_IACCESS 1
#define CAUSE_ILLEGAL 2
#define CAUSE_BREAK   3
#define CAUSE_LMISAL  4
#define CAUSE_LACCESS 5
#define CAUSE_SMISAL  6
#define CAUSE_SACCESS 7
#define CAUSE_ECALL_M 11

/* Compare a register with a constant; on mismatch fail with test number n. */
#define CHECK(n, reg, val) \
  li gp, n; li t6, val; beq reg, t6, 9990f; j fail_handler; 9990:

/* Same, comparing two registers. */
#define CHECK_REG(n, reg, other) \
  li gp, n; beq reg, other, 9991f; j fail_handler; 9991:

#define PASS  j pass_handler

/* Timing markers */
#define MARK_PREP(reg, id, delta)  li reg, (((delta) << 8) | (id))
#define MARK_REG(reg)              sw reg, 0(tp)
/* tp (x4) must hold MARKER when MARK_REG is used: MARK_BASE sets it. */
#define MARK_BASE                  li tp, MARKER

/* mcycle-based checks (see above) */
#define CYCLE_CHECK(reg, n) \
  li t5, CYCEXP; li t6, n; sw t6, 0(t5); sw reg, 4(t5)

/* Trap recovery: arm a one-use recovery address, or disarm it */
#define EXPECT_TRAP(resume_label)  la t6, resume_label; li t5, TRAP_FRAME; sw t6, TF_RESUME(t5)
#define NO_TRAP                    li t5, TRAP_FRAME; sw zero, TF_RESUME(t5)

/* Check a field of the last recorded trap (TF_CAUSE, TF_EPC, TF_TVAL, TF_COUNT, ...) */
#define CHECK_TRAP(n, field, val) \
  li t5, TRAP_FRAME; lw t5, field(t5); CHECK(n, t5, val)

/* Same, with an address (label expression) as the expected value */
#define CHECK_TRAP_AT(n, field, sym) \
  li t5, TRAP_FRAME; lw t5, field(t5); li gp, n; la t6, sym; beq t5, t6, 9992f; \
  j fail_handler; 9992:

/* Trap expectations */
#define TRAPS(n)   .pushsection .traptab, "aw"; .word n; .popsection
#define TRAP(cause, pc, tval) \
  .pushsection .traptab, "aw"; .word cause; .word pc; .word tval; .popsection

#endif
