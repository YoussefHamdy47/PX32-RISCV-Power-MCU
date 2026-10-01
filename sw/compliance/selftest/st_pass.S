/* Runner selftest: a passing test in the riscv-tests p environment (expected: pass). */
#include "riscv_test.h"
#include "test_macros.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
  TEST_CASE( 2, a0, 5, li a0, 5 )
  TEST_PASSFAIL
RVTEST_CODE_END
  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
