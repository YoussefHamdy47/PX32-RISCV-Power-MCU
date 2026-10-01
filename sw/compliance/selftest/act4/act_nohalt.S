/* ACT4 runner selftest: never halts (must fail by the bench's cycle limit). */
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
1:j    1b
