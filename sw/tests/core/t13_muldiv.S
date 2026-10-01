/* t13_muldiv: RV32M in the pipeline (step 1.7, D-023).
 *   A. every MUL/DIV instruction on every pair of 7 corner operands (0, 1, -1, INT_MIN,
 *      INT_MAX, 7, -7), including divide by zero and signed overflow. The expected values
 *      of this block were computed once from the manual's definitions with Python integers
 *      (not by the reference model or the RTL); tb_core also compares every result with
 *      the reference model
 *   B. rd = x0, rd = rs1, rd = rs2, rs1 = rs2
 *   C. forwarding into MUL/DIV (ALU result, load-use, CSR result, MUL result) and out of
 *      them (ALU, branch, store data, JALR base, CSR operand, next MUL/DIV)
 *   D. cancellation: MUL/DIV behind an older faulting load/store (killed, re-executed once
 *      after the handler: minstret), on the wrong path of taken branch/JAL/JALR/MRET and
 *      behind a trapping instruction
 *   E. compressed neighbours at halfword offsets
 *   F. timing: MUL independent/dependent/back-to-back, DIV (every operand class) with an
 *      independent and a dependent successor, back-to-back DIV, MUL feeding DIV; measured
 *      with mcycle (CYCLE_CHECK: exact with ideal memories, lower bound otherwise) and
 *      timing markers (ideal memories)
 * The traps are listed at the end. */
#include "px_test.h"

#define FAULT_ADDR 0x30000000

  .data
  .balign 4
mbuf: .word 0x00000064, 0xFFFFFFF9, 0, 0

  .text
  .globl test_main
test_main:
  .option norvc
  la   s0, mbuf
  li   s2, FAULT_ADDR

  /* ---------------- A. corner operands (generated block) ---------------- */
  /* mul */
  li   a0, 0x00000000
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(100, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(101, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(102, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(103, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(104, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(105, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(106, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(107, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(108, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(109, a2, 0xFFFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(110, a2, 0x80000000)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(111, a2, 0x7FFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(112, a2, 0x00000007)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(113, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(114, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(115, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(116, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(117, a2, 0x80000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(118, a2, 0x80000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(119, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(120, a2, 0x00000007)
  li   a0, 0x80000000
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(121, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(122, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(123, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(124, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(125, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(126, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(127, a2, 0x80000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(128, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(129, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(130, a2, 0x80000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(131, a2, 0x80000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(132, a2, 0x00000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(133, a2, 0x7FFFFFF9)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(134, a2, 0x80000007)
  li   a0, 0x00000007
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(135, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(136, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(137, a2, 0xFFFFFFF9)
  li   a0, 0x00000007
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(138, a2, 0x80000000)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(139, a2, 0x7FFFFFF9)
  li   a0, 0x00000007
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(140, a2, 0x00000031)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(141, a2, 0xFFFFFFCF)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  mul a2, a0, a1
  CHECK(142, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  mul a2, a0, a1
  CHECK(143, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  mul a2, a0, a1
  CHECK(144, a2, 0x00000007)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  mul a2, a0, a1
  CHECK(145, a2, 0x80000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  mul a2, a0, a1
  CHECK(146, a2, 0x80000007)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  mul a2, a0, a1
  CHECK(147, a2, 0xFFFFFFCF)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  mul a2, a0, a1
  CHECK(148, a2, 0x00000031)
  /* mulh */
  li   a0, 0x00000000
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(149, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(150, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(151, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(152, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(153, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(154, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(155, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(156, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(157, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(158, a2, 0xFFFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(159, a2, 0xFFFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(160, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(161, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(162, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(163, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(164, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(165, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(166, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(167, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(168, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(169, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(170, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(171, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(172, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(173, a2, 0x40000000)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(174, a2, 0xC0000000)
  li   a0, 0x80000000
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(175, a2, 0xFFFFFFFC)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(176, a2, 0x00000003)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(177, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(178, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(179, a2, 0xFFFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(180, a2, 0xC0000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(181, a2, 0x3FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(182, a2, 0x00000003)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(183, a2, 0xFFFFFFFC)
  li   a0, 0x00000007
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(184, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(185, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(186, a2, 0xFFFFFFFF)
  li   a0, 0x00000007
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(187, a2, 0xFFFFFFFC)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(188, a2, 0x00000003)
  li   a0, 0x00000007
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(189, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(190, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  mulh a2, a0, a1
  CHECK(191, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  mulh a2, a0, a1
  CHECK(192, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  mulh a2, a0, a1
  CHECK(193, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  mulh a2, a0, a1
  CHECK(194, a2, 0x00000003)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  mulh a2, a0, a1
  CHECK(195, a2, 0xFFFFFFFC)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  mulh a2, a0, a1
  CHECK(196, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  mulh a2, a0, a1
  CHECK(197, a2, 0x00000000)
  /* mulhsu */
  li   a0, 0x00000000
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(198, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(199, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(200, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(201, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(202, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(203, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(204, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(205, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(206, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(207, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(208, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(209, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(210, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(211, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(212, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(213, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(214, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(215, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(216, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(217, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(218, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(219, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(220, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(221, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(222, a2, 0xC0000000)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(223, a2, 0xC0000000)
  li   a0, 0x80000000
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(224, a2, 0xFFFFFFFC)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(225, a2, 0x80000003)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(226, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(227, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(228, a2, 0x7FFFFFFE)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(229, a2, 0x3FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(230, a2, 0x3FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(231, a2, 0x00000003)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(232, a2, 0x7FFFFFFB)
  li   a0, 0x00000007
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(233, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(234, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(235, a2, 0x00000006)
  li   a0, 0x00000007
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(236, a2, 0x00000003)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(237, a2, 0x00000003)
  li   a0, 0x00000007
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(238, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(239, a2, 0x00000006)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  mulhsu a2, a0, a1
  CHECK(240, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  mulhsu a2, a0, a1
  CHECK(241, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  mulhsu a2, a0, a1
  CHECK(242, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  mulhsu a2, a0, a1
  CHECK(243, a2, 0xFFFFFFFC)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  mulhsu a2, a0, a1
  CHECK(244, a2, 0xFFFFFFFC)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  mulhsu a2, a0, a1
  CHECK(245, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  mulhsu a2, a0, a1
  CHECK(246, a2, 0xFFFFFFF9)
  /* mulhu */
  li   a0, 0x00000000
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(247, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(248, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(249, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(250, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(251, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(252, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(253, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(254, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(255, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(256, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(257, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(258, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(259, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(260, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(261, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(262, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(263, a2, 0xFFFFFFFE)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(264, a2, 0x7FFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(265, a2, 0x7FFFFFFE)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(266, a2, 0x00000006)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(267, a2, 0xFFFFFFF8)
  li   a0, 0x80000000
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(268, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(269, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(270, a2, 0x7FFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(271, a2, 0x40000000)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(272, a2, 0x3FFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(273, a2, 0x00000003)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(274, a2, 0x7FFFFFFC)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(275, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(276, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(277, a2, 0x7FFFFFFE)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(278, a2, 0x3FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(279, a2, 0x3FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(280, a2, 0x00000003)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(281, a2, 0x7FFFFFFB)
  li   a0, 0x00000007
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(282, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(283, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(284, a2, 0x00000006)
  li   a0, 0x00000007
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(285, a2, 0x00000003)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(286, a2, 0x00000003)
  li   a0, 0x00000007
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(287, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(288, a2, 0x00000006)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  mulhu a2, a0, a1
  CHECK(289, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  mulhu a2, a0, a1
  CHECK(290, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  mulhu a2, a0, a1
  CHECK(291, a2, 0xFFFFFFF8)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  mulhu a2, a0, a1
  CHECK(292, a2, 0x7FFFFFFC)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  mulhu a2, a0, a1
  CHECK(293, a2, 0x7FFFFFFB)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  mulhu a2, a0, a1
  CHECK(294, a2, 0x00000006)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  mulhu a2, a0, a1
  CHECK(295, a2, 0xFFFFFFF2)
  /* div */
  li   a0, 0x00000000
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(296, a2, 0xFFFFFFFF)
  li   a0, 0x00000000
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(297, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(298, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(299, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(300, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(301, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(302, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(303, a2, 0xFFFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(304, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(305, a2, 0xFFFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(306, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(307, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(308, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(309, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(310, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(311, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(312, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(313, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(314, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(315, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(316, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(317, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(318, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(319, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(320, a2, 0x00000001)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(321, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(322, a2, 0xEDB6DB6E)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(323, a2, 0x12492492)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(324, a2, 0xFFFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(325, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(326, a2, 0x80000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(327, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(328, a2, 0x00000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(329, a2, 0x12492492)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(330, a2, 0xEDB6DB6E)
  li   a0, 0x00000007
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(331, a2, 0xFFFFFFFF)
  li   a0, 0x00000007
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(332, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(333, a2, 0xFFFFFFF9)
  li   a0, 0x00000007
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(334, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(335, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(336, a2, 0x00000001)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(337, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  div a2, a0, a1
  CHECK(338, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  div a2, a0, a1
  CHECK(339, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  div a2, a0, a1
  CHECK(340, a2, 0x00000007)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  div a2, a0, a1
  CHECK(341, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  div a2, a0, a1
  CHECK(342, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  div a2, a0, a1
  CHECK(343, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  div a2, a0, a1
  CHECK(344, a2, 0x00000001)
  /* divu */
  li   a0, 0x00000000
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(345, a2, 0xFFFFFFFF)
  li   a0, 0x00000000
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(346, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(347, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(348, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(349, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(350, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(351, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(352, a2, 0xFFFFFFFF)
  li   a0, 0x00000001
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(353, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(354, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(355, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(356, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(357, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(358, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(359, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(360, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(361, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(362, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(363, a2, 0x00000002)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(364, a2, 0x24924924)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(365, a2, 0x00000001)
  li   a0, 0x80000000
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(366, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(367, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(368, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(369, a2, 0x00000001)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(370, a2, 0x00000001)
  li   a0, 0x80000000
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(371, a2, 0x12492492)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(372, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(373, a2, 0xFFFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(374, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(375, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(376, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(377, a2, 0x00000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(378, a2, 0x12492492)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(379, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(380, a2, 0xFFFFFFFF)
  li   a0, 0x00000007
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(381, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(382, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(383, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(384, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(385, a2, 0x00000001)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(386, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  divu a2, a0, a1
  CHECK(387, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  divu a2, a0, a1
  CHECK(388, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  divu a2, a0, a1
  CHECK(389, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  divu a2, a0, a1
  CHECK(390, a2, 0x00000001)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  divu a2, a0, a1
  CHECK(391, a2, 0x00000001)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  divu a2, a0, a1
  CHECK(392, a2, 0x24924923)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  divu a2, a0, a1
  CHECK(393, a2, 0x00000001)
  /* rem */
  li   a0, 0x00000000
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(394, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(395, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(396, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(397, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(398, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(399, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(400, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(401, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(402, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(403, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(404, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(405, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(406, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(407, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(408, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(409, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(410, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(411, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(412, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(413, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(414, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(415, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(416, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(417, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(418, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(419, a2, 0xFFFFFFFF)
  li   a0, 0x80000000
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(420, a2, 0xFFFFFFFE)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(421, a2, 0xFFFFFFFE)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(422, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(423, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(424, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(425, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(426, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(427, a2, 0x00000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(428, a2, 0x00000001)
  li   a0, 0x00000007
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(429, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(430, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(431, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(432, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(433, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(434, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(435, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  rem a2, a0, a1
  CHECK(436, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  rem a2, a0, a1
  CHECK(437, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  rem a2, a0, a1
  CHECK(438, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  rem a2, a0, a1
  CHECK(439, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  rem a2, a0, a1
  CHECK(440, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  rem a2, a0, a1
  CHECK(441, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  rem a2, a0, a1
  CHECK(442, a2, 0x00000000)
  /* remu */
  li   a0, 0x00000000
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(443, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(444, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(445, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(446, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(447, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(448, a2, 0x00000000)
  li   a0, 0x00000000
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(449, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(450, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(451, a2, 0x00000000)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(452, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(453, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(454, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(455, a2, 0x00000001)
  li   a0, 0x00000001
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(456, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(457, a2, 0xFFFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(458, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(459, a2, 0x00000000)
  li   a0, 0xFFFFFFFF
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(460, a2, 0x7FFFFFFF)
  li   a0, 0xFFFFFFFF
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(461, a2, 0x00000001)
  li   a0, 0xFFFFFFFF
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(462, a2, 0x00000003)
  li   a0, 0xFFFFFFFF
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(463, a2, 0x00000006)
  li   a0, 0x80000000
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(464, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(465, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(466, a2, 0x80000000)
  li   a0, 0x80000000
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(467, a2, 0x00000000)
  li   a0, 0x80000000
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(468, a2, 0x00000001)
  li   a0, 0x80000000
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(469, a2, 0x00000002)
  li   a0, 0x80000000
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(470, a2, 0x80000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(471, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(472, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(473, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(474, a2, 0x7FFFFFFF)
  li   a0, 0x7FFFFFFF
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(475, a2, 0x00000000)
  li   a0, 0x7FFFFFFF
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(476, a2, 0x00000001)
  li   a0, 0x7FFFFFFF
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(477, a2, 0x7FFFFFFF)
  li   a0, 0x00000007
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(478, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(479, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(480, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(481, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(482, a2, 0x00000007)
  li   a0, 0x00000007
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(483, a2, 0x00000000)
  li   a0, 0x00000007
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(484, a2, 0x00000007)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000000
  remu a2, a0, a1
  CHECK(485, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000001
  remu a2, a0, a1
  CHECK(486, a2, 0x00000000)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFFF
  remu a2, a0, a1
  CHECK(487, a2, 0xFFFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x80000000
  remu a2, a0, a1
  CHECK(488, a2, 0x7FFFFFF9)
  li   a0, 0xFFFFFFF9
  li   a1, 0x7FFFFFFF
  remu a2, a0, a1
  CHECK(489, a2, 0x7FFFFFFA)
  li   a0, 0xFFFFFFF9
  li   a1, 0x00000007
  remu a2, a0, a1
  CHECK(490, a2, 0x00000004)
  li   a0, 0xFFFFFFF9
  li   a1, 0xFFFFFFF9
  remu a2, a0, a1
  CHECK(491, a2, 0x00000000)

  /* ---------------- B. register aliasing ---------------- */
  li   a0, 6
  li   a1, 7
  mul  x0, a0, a1                      /* rd = x0: nothing written */
  div  x0, a0, a1
  CHECK(10, x0, 0)
  mul  a0, a0, a1                      /* rd = rs1 */
  CHECK(11, a0, 42)
  li   a0, 100
  rem  a1, a0, a1                      /* rd = rs2 */
  CHECK(12, a1, 2)
  li   a2, -5
  mul  a3, a2, a2                      /* rs1 = rs2 */
  CHECK(13, a3, 25)
  div  a3, a2, a2
  CHECK(14, a3, 1)
  mulhu a3, a2, a2
  CHECK(15, a3, 0xFFFFFFF6)
  divu a2, a2, a2                      /* rd = rs1 = rs2 */
  CHECK(16, a2, 1)

  /* ---------------- C. forwarding ---------------- */
  li   a0, 1000
  addi a1, x0, 3
  mul  a2, a0, a1                      /* ALU result from the previous instruction */
  CHECK(20, a2, 3000)
  addi a3, x0, 9
  div  a2, a3, a1
  CHECK(21, a2, 3)
  lw   a4, 0(s0)                       /* 100 */
  mul  a2, a4, a1                      /* load-use into MUL */
  CHECK(22, a2, 300)
  lw   a4, 4(s0)                       /* -7 */
  div  a2, a4, a1                      /* load-use into DIV: -7 / 3 = -2 */
  CHECK(23, a2, -2)
  csrwi mtval, 21
  csrr a5, mtval
  div  a2, a5, a1                      /* CSR result into DIV */
  CHECK(24, a2, 7)
  mul  a2, a1, a1
  mul  a3, a2, a1                      /* MUL result into MUL (one stall) */
  CHECK(25, a3, 27)
  mul  a2, a1, a1
  div  a3, a2, a1                      /* MUL result into DIV */
  CHECK(26, a3, 3)
  div  a2, a0, a1
  mul  a3, a2, a1                      /* DIV result into MUL (forwarded from WB) */
  CHECK(27, a3, 999)
  div  a2, a0, a1
  div  a3, a2, a1                      /* DIV result into DIV */
  CHECK(28, a3, 111)
  mul  a2, a1, a1
  addi a3, a2, 1                       /* MUL result into the ALU */
  CHECK(30, a3, 10)
  li   a4, 9
  mul  a2, a1, a1
  bne  a2, a4, 1f                      /* ... into a branch */
  j    2f
1:
  CHECK(31, x0, 1)
2:
  li   a4, 333
  div  a2, a0, a1
  bne  a2, a4, 3f                      /* DIV result into a branch */
  j    4f
3:
  CHECK(32, x0, 1)
4:
  mul  a2, a1, a1
  sw   a2, 8(s0)                       /* ... into store data */
  div  a3, a0, a1
  sw   a3, 12(s0)
  lw   a4, 8(s0)
  CHECK(33, a4, 9)
  lw   a4, 12(s0)
  CHECK(34, a4, 333)
  la   a4, 5f
  li   a5, 1
  mul  a6, a4, a5
  jalr x0, 0(a6)                       /* MUL result as a JALR base */
  j    fail_handler
5:
  la   a4, 6f
  div  a6, a4, a5
  jalr x0, 0(a6)                       /* DIV result as a JALR base */
  j    fail_handler
6:
  mul  a2, a1, a1
  csrw mtval, a2                       /* MUL result as a CSR operand */
  csrr a3, mtval
  CHECK(35, a3, 9)
  div  a2, a0, a1
  csrw mtval, a2                       /* DIV result as a CSR operand */
  csrr a3, mtval
  CHECK(36, a3, 333)

  /* ---------------- D. cancellation ---------------- */
  li   a0, 1000
  li   a1, 3
  csrr s4, minstret
t_dk1:
  lw   a3, 0(s2)                       /* bus error: the DIV behind it is killed, */
  div  a2, a0, a1                      /* then executed once after the handler */
  csrr s5, minstret
  CHECK(40, a2, 333)
  sub  s5, s5, s4
  CHECK(41, s5, 35)                    /* csrr + 33 handler + DIV; not the load */
  csrr s4, minstret
t_dk2:
  sw   a3, 0(s2)
  remu a2, a0, a1
  csrr s5, minstret
  CHECK(42, a2, 1)
  sub  s5, s5, s4
  CHECK(43, s5, 35)
t_dk3:
  lw   a3, 0(s2)
  mul  a2, a0, a1
  CHECK(44, a2, 3000)
  li   a2, 0x55
  EXPECT_TRAP(7f)
t_dk4:
  lw   a3, 0(s2)                       /* the killed DIV must write nothing */
  div  a2, a0, a1
7:
  CHECK(45, a2, 0x55)
  EXPECT_TRAP(8f)
t_dk5:
  sw   a3, 0(s2)
  mul  a2, a0, a1
8:
  CHECK(46, a2, 0x55)
  li   a2, 0x66
  beq  x0, x0, 1f                      /* wrong path of a taken branch */
  div  a2, a0, a1
  mul  a2, a0, a1
1:
  jal  x0, 2f                          /* ... of a JAL */
  div  a2, a0, a1
2:
  la   a4, 3f
  jalr x0, 0(a4)                       /* ... of a JALR */
  mul  a2, a0, a1
3:
  la   a4, 4f
  csrw mepc, a4
  mret                                 /* ... of an MRET */
  div  a2, a0, a1
  mul  a2, a0, a1
4:
  EXPECT_TRAP(5f)
t_dk6:
  ecall                                /* behind a trapping instruction */
  div  a2, a0, a1
  mul  a2, a0, a1
5:
  CHECK(47, a2, 0x66)

  /* ---------------- E. compressed neighbours ---------------- */
  .option push
  .option rvc
  c.li a0, 12
  c.li a1, 5
  c.nop
  mul  a2, a0, a1                      /* 32-bit at a halfword offset */
  c.mv a3, a2                          /* 16-bit consumer of a MUL */
  div  a4, a3, a1
  c.addi a4, 1                         /* 16-bit consumer of a DIV */
  c.nop
  .option pop
  CHECK(60, a2, 60)
  CHECK(61, a3, 60)
  CHECK(62, a4, 13)

  /* ---------------- F. timing ---------------- */
  li   a0, 1000
  li   a1, 3
  li   a5, 0
  li   s1, 0x80000000
  li   s3, -1
  csrr s6, mcycle                      /* F1 MUL, independent successor: 1 + 1 */
  mul  a2, a1, a1
  addi a3, a1, 1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 3)
  csrr s6, mcycle                      /* F2 MUL, dependent successor: +1 stall */
  mul  a2, a1, a1
  addi a3, a2, 1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 4)
  csrr s6, mcycle                      /* F3 three independent MULs: throughput 1 */
  mul  a2, a1, a1
  mul  a3, a0, a1
  mul  a4, a1, a0
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 4)
  csrr s6, mcycle                      /* F4 MUL into MUL */
  mul  a2, a1, a1
  mul  a3, a2, a1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 4)
  csrr s6, mcycle                      /* F5 DIV: 17 cycles in EX */
  div  a2, a0, a1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 18)
  csrr s6, mcycle                      /* F6 DIV, dependent successor: no extra stall */
  div  a2, a0, a1
  addi a3, a2, 1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 19)
  csrr s6, mcycle                      /* F7 divide by zero: same schedule */
  div  a2, a0, a5
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 18)
  csrr s6, mcycle                      /* F8 signed overflow: same schedule */
  rem  a2, s1, s3
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 18)
  csrr s6, mcycle                      /* F9 DIVU of the largest operands */
  divu a2, s3, a1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 18)
  csrr s6, mcycle                      /* F10 back-to-back DIVs */
  div  a2, a0, a1
  remu a3, a0, a1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 35)
  csrr s6, mcycle                      /* F11 MUL into DIV: 1 + stall 1 + 17 */
  mul  a2, a1, a1
  div  a3, a2, a1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 20)
  csrr s6, mcycle                      /* F12 DIV into MUL: 17 + 1 */
  div  a2, a0, a1
  mul  a3, a2, a1
  csrr s7, mcycle
  sub  s8, s7, s6
  CYCLE_CHECK(s8, 19)
  csrr s4, minstret                    /* each counts once in minstret */
  div  a2, a0, a1
  mul  a3, a2, a1
  csrr s5, minstret
  sub  s5, s5, s4
  CHECK(70, s5, 3)
  /* the same rows with timing markers (store retirements, ideal memories) */
  MARK_BASE
  MARK_PREP(s9, 1, 0)
  MARK_PREP(s10, 2, 18)
  MARK_PREP(s11, 3, 4)
  MARK_PREP(t0, 4, 3)
  MARK_PREP(t1, 5, 19)
  MARK_REG(s9)
  div  a2, a0, a1                      /* DIV: 17 + marker */
  MARK_REG(s10)
  mul  a2, a1, a1                      /* MUL, dependent successor */
  addi a3, a2, 1
  MARK_REG(s11)
  mul  a2, a1, a1                      /* MUL, independent successor */
  addi a3, a1, 1
  MARK_REG(t0)
  div  a2, a0, a1                      /* DIV, dependent successor */
  addi a3, a2, 1
  MARK_REG(t1)
  PASS

  TRAPS(6)
  TRAP(CAUSE_LACCESS, t_dk1, FAULT_ADDR)
  TRAP(CAUSE_SACCESS, t_dk2, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, t_dk3, FAULT_ADDR)
  TRAP(CAUSE_LACCESS, t_dk4, FAULT_ADDR)
  TRAP(CAUSE_SACCESS, t_dk5, FAULT_ADDR)
  TRAP(CAUSE_ECALL_M, t_dk6, 0)
