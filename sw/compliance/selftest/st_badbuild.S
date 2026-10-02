/* Runner selftest: does not assemble (expected: fail). */
  .section .text.init
  .globl _start
_start:
  this_is_not_an_instruction x1, x2
