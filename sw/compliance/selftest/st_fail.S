/* Runner selftest: test case 3 fails (expected: fail, tohost 7). */
#include "riscv_test.h"
#include "test_macros.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
  TEST_CASE( 2, a0, 5, li a0, 5 )
  TEST_CASE( 3, a0, 5, li a0, 6 )
  TEST_PASSFAIL
RVTEST_CODE_END
  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
