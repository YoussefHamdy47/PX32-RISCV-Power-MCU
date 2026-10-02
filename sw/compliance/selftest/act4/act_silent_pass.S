/* ACT4 runner selftest: halts with the pass value without printing the summary line
 * (a test whose body did not run to its summary must not count as a pass). */
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   x1, 1
  li   t0, 0x100ffff0
  sw   x1, 0(t0)
1:j    1b
