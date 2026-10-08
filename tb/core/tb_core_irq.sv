// tb_core_irq: tb_core on the CLIC programs (tb/core/programs/list_irq.txt: t16_clic_basic,
// t17_clic_nest, t18_clic_vector; step 2.2d, DECISIONS.md D-035). They run in their own bench
// so that it runs next to tb_core in the regression. The take-point bins belong to t20 in
// tb_core; the vectored-entry and O5 bins are required here. See tb_core.sv.

`timescale 1ns/1ps

module tb_core_irq;
  tb_core #(.LIST("tb/core/programs/list_irq.txt"), .NAME("tb_core_irq"), .TAKE_COV(0)) u_tb ();
endmodule
