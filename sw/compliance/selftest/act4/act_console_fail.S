/* ACT4 runner selftest: prints a failing summary but halts with the pass value (must still fail). */
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  la   a0, msg
1:lbu  a1, 0(a0)
  beqz a1, 2f
  li   a2, 0x100ffff8
  sb   a1, 0(a2)
  addi a0, a0, 1
  j    1b
2:li   x1, 1
  li   t0, 0x100ffff0
  sw   x1, 0(t0)
3:j    3b
  .data
msg: .asciz "RVCP-SUMMARY: TEST FAILED - Test File act_console_fail.S\n"
