// tb_smoke: checks the tool flow (compile, run, VCD dump). Not a design test.

`timescale 1ns/1ps

module tb_smoke;
  logic       clk = 1'b0;
  logic [3:0] cnt = 4'd0;

  always #5 clk = ~clk;
  always_ff @(posedge clk) cnt <= cnt + 4'd1;

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_smoke.vcd");
      $dumpvars(0, tb_smoke);
    end
    repeat (20) @(posedge clk);
    #1;
    // 20 rising edges on a 4-bit counter: 20 mod 16 = 4
    if (cnt == 4'd4) $display("PASS tb_smoke (counter = %0d)", cnt);
    else             $display("FAIL tb_smoke (counter = %0d, expected 4)", cnt);
    $finish;
  end
endmodule
