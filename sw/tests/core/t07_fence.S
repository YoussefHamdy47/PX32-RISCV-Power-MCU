/* t07_fence: FENCE.I makes a store to instruction memory visible to fetch (the
 * instruction right after the FENCE.I is patched), FENCE and WFI execute as NOPs,
 * and FENCE with reserved fields behaves as an ordinary FENCE. */
#include "px_test.h"

  .text
  .globl test_main
test_main:
  .option norvc
  /* Patch the instruction at `patch` from "addi a2, x0, 1" to "addi a2, x0, 42". */
  la   a0, patch
  li   a1, 0x02A00613                /* addi a2, x0, 42 */
  sw   a1, 0(a0)
  fence.i
patch:
  addi a2, x0, 1
  CHECK(1, a2, 42)
  /* Patch it again, further ahead than the prefetch buffer reaches */
  la   a0, patch2
  li   a1, 0x06300613                /* addi a2, x0, 99 */
  sw   a1, 0(a0)
  fence.i
  nop
  nop
  nop
  nop
patch2:
  addi a2, x0, 1
  CHECK(2, a2, 99)
  /* FENCE and WFI are NOPs here */
  li   a3, 7
  fence
  fence rw, rw
  wfi
  addi a3, a3, 1
  CHECK(3, a3, 8)
  /* FENCE with nonzero rd/rs1 and a reserved fm value: ordinary fence */
  .word 0x7FF5850F
  addi a3, a3, 1
  CHECK(4, a3, 9)
  PASS
