/* Runner selftest: never writes tohost although it keeps retiring (expected: fail by
 * the bench's cycle limit). */
#include "riscv_test.h"
#include "test_macros.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
1: j 1b
  TEST_PASSFAIL
RVTEST_CODE_END
  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
