/* Runner selftest: no tohost symbol at all (expected: fail before simulation). */
  .section .text.init
  .globl _start
_start:
  j _start
