/* px_test.h: macros for self-checking PX32 core test programs (assembly).
 *
 * Conventions
 *   - gp  (x3)  holds the current test number; t6 (x31) is scratch for CHECK.
 *   - s11 (x27) holds the address the trap handler resumes at. crt0 sets it to
 *     unexpected_trap; a test that expects a trap sets it first (EXPECT_TRAP).
 *   - PASS writes 1 to tohost; a failure writes ((test + 1) << 1) | 1, which is never 1,
 *     so a failure before any test number is set still reports as a failure.
 *   - MARK(id, delta) stores to the timing marker. The testbench checks that this
 *     marker retires exactly `delta` cycles after the previous one (id 0: start only).
 *     Put the value in a register beforehand so no extra instructions are timed:
 *     use MARK_PREP(reg, id, delta) outside the timed region and MARK_REG(reg) inside.
 *   - TRAPS(n) followed by n TRAP(cause, pc, tval) entries declares the traps the
 *     program must raise, in order; the testbench compares them with what it saw.
 */
#ifndef PX_TEST_H
#define PX_TEST_H

#define TOHOST   0x2000FFF0
#define MARKER   0x2000FFE0

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

/* Trap expectations */
#define EXPECT_TRAP(resume_label)  la s11, resume_label
#define NO_TRAP                    la s11, unexpected_trap
#define TRAPS(n)   .pushsection .traptab, "aw"; .word n; .popsection
#define TRAP(cause, pc, tval) \
  .pushsection .traptab, "aw"; .word cause; .word pc; .word tval; .popsection

#endif
