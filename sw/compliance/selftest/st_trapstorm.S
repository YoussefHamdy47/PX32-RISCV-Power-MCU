/* Runner selftest: mtvec points at an illegal instruction, so every trap traps again and
 * nothing retires (expected: fail by the bench's deadlock detection). */
#include "riscv_test.h"
#include "test_macros.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
  la t0, bad
  csrw mtvec, t0
  .word 0
  TEST_PASSFAIL
  .balign 4
bad:
  .word 0
RVTEST_CODE_END
  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
