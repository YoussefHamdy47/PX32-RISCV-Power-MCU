// tb_px_div: self-checking unit test for px_div (step 1.7, DECISIONS.md D-023).
//
// Reference model: SystemVerilog integer division written from the RV32M definitions
// (quotient rounds towards zero, remainder has the dividend's sign, divide by zero gives
// quotient all ones and remainder = dividend, -2^31 / -1 gives -2^31 remainder 0).
// Every operation is checked for its result and for its latency: done_o must rise in
// exactly the 17th cycle (cycle 1 = first cycle with valid_i while idle), never earlier.
//   T1 every op on every pair of 14 corner operands (including 0, -1, INT_MIN)
//   T2 result held while accept_i is delayed (0-5 cycles)
//   T3 kill at every cycle position 1..18 (kill_i), and abandonment by valid_i falling;
//      done_o never appears, the divider is idle next cycle, and a new operation started
//      right away has the full latency and the right result
//   T4 back-to-back operations: accept in cycle 17 with valid_i still high starts the
//      next one in the following cycle
//   T5 asynchronous reset in the middle of an operation
//   T6 20,000 random operations (random accept delay, occasional kill)
// Functional coverage: per op, the four sign combinations, divide by zero, overflow
// (DIV/REM), zero result; every kill position; delayed accept; back-to-back.
//
// Run: scripts/run_unit.sh tb_px_div [+vcd]

`timescale 1ns/1ps

module tb_px_div;

  localparam int NUM_RANDOM = 20000;
  localparam int LATENCY    = 17;

  logic        clk = 1'b0;
  logic        rst_n;
  logic        valid, kill, accept;
  logic [1:0]  op;
  logic [31:0] a, b, res;
  logic        done, busy;

  px_div dut (
    .clk_i(clk), .rst_ni(rst_n), .valid_i(valid), .kill_i(kill), .accept_i(accept),
    .op_i(op), .a_i(a), .b_i(b), .done_o(done), .result_o(res), .busy_o(busy)
  );

  always #5 clk = ~clk;

  int checks = 0, errors = 0;
  int cov_sign [0:3][0:3];
  int cov_div0 [0:3], cov_ovf [0:3], cov_zero [0:3];
  int cov_kill [1:18];
  int cov_delay, cov_b2b, cov_abandon;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("ERROR %0t: %s", $time, msg);
  endtask

  function automatic logic [31:0] model(input logic [1:0] o, input logic [31:0] x, input logic [31:0] y);
    int sx, sy;
    sx = $signed(x);
    sy = $signed(y);
    case (o)
      2'b00: begin                                            // DIV
        if (y == 32'd0) return 32'hFFFF_FFFF;
        if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) return 32'h8000_0000;
        return sx / sy;
      end
      2'b01: return (y == 32'd0) ? 32'hFFFF_FFFF : x / y;     // DIVU
      2'b10: begin                                            // REM
        if (y == 32'd0) return x;
        if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) return 32'd0;
        return sx % sy;
      end
      default: return (y == 32'd0) ? x : x % y;              // REMU
    endcase
  endfunction

  task automatic idle();
    valid = 1'b0; kill = 1'b0; accept = 1'b0;
  endtask

  // Run one operation from cycle 1. Inputs change 1 time unit after an edge.
  // delay: extra cycles before accept. keep_valid: leave valid_i high after accept
  // (back-to-back: the caller sets the next operands).
  task automatic run_op(input logic [1:0] o, input logic [31:0] x, input logic [31:0] y,
                        input int delay, input bit keep_valid);
    logic [31:0] exp;
    exp = model(o, x, y);
    op = o; a = x; b = y; valid = 1'b1; kill = 1'b0; accept = 1'b0;
    for (int c = 1; c < LATENCY; c++) begin
      #3;
      if (done) fail($sformatf("op %0d %08h / %08h: done in cycle %0d, before cycle 17", o, x, y, c));
      @(posedge clk); #1;
      // operands may change after cycle 1: the divider must have sampled them
      a = $urandom; b = $urandom;
    end
    // cycle 17 (and any delay cycles)
    for (int d = 0; d <= delay; d++) begin
      #3;
      checks++;
      if (!done) fail($sformatf("op %0d %08h / %08h: no done in cycle %0d", o, x, y, LATENCY + d));
      if (res !== exp)
        fail($sformatf("op %0d %08h / %08h: result %08h, expected %08h (cycle %0d)", o, x, y, res, exp, LATENCY + d));
      if (d == delay) accept = 1'b1;
      @(posedge clk); #1;
    end
    accept = 1'b0;
    if (!keep_valid) valid = 1'b0;
    if (delay > 0) cov_delay++;
    cov_sign[o][{x[31], y[31]}]++;
    if (y == 32'd0) cov_div0[o]++;
    if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) cov_ovf[o]++;
    if (exp == 32'd0) cov_zero[o]++;
  endtask

  // Kill (or abandon by valid_i falling) in cycle k of an operation.
  task automatic killed_op(input int k, input bit by_valid);
    op = $urandom % 4; a = $urandom; b = $urandom; valid = 1'b1; kill = 1'b0; accept = 1'b0;
    for (int c = 1; c < k; c++) begin
      @(posedge clk); #1;
    end
    if (by_valid) valid = 1'b0; else kill = 1'b1;
    #3;
    @(posedge clk); #1;
    kill = 1'b0; valid = 1'b0;
    #3;
    checks++;
    if (busy || done) fail($sformatf("divider still busy after a kill in cycle %0d", k));
    if (by_valid) cov_abandon++; else cov_kill[k]++;
  endtask

  logic [31:0] corner [0:13];

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_div.vcd");
      $dumpvars(0, tb_px_div);
    end
    for (int o = 0; o < 4; o++) begin
      for (int s = 0; s < 4; s++) cov_sign[o][s] = 0;
      cov_div0[o] = 0; cov_ovf[o] = 0; cov_zero[o] = 0;
    end
    for (int k = 1; k <= 18; k++) cov_kill[k] = 0;
    cov_delay = 0; cov_b2b = 0; cov_abandon = 0;
    corner[0] = 32'h0;        corner[1] = 32'h1;        corner[2] = 32'h2;
    corner[3] = 32'hFFFF_FFFF; corner[4] = 32'hFFFF_FFFE; corner[5] = 32'h8000_0000;
    corner[6] = 32'h8000_0001; corner[7] = 32'h7FFF_FFFF; corner[8] = 32'h0000_0007;
    corner[9] = 32'hFFFF_FFF9; corner[10] = 32'h0001_0000; corner[11] = 32'h0000_0003;
    corner[12] = 32'hAAAA_AAAA; corner[13] = 32'h5555_5555;

    rst_n = 1'b0; idle(); op = 2'b00; a = 32'd0; b = 32'd0;
    repeat (2) @(posedge clk);
    #1;
    checks++;
    if (busy || done) fail("busy or done in reset");
    @(negedge clk); rst_n = 1'b1;
    @(posedge clk); #1;

    // T1 corners
    for (int o = 0; o < 4; o++)
      for (int i = 0; i < 14; i++)
        for (int j = 0; j < 14; j++)
          run_op(o, corner[i], corner[j], 0, 1'b0);
    // explicit spot values
    run_op(2'b00, 32'hFFFF_FFF9, 32'h0000_0002, 0, 1'b0);   // -7 / 2 = -3
    run_op(2'b10, 32'hFFFF_FFF9, 32'h0000_0002, 0, 1'b0);   // -7 % 2 = -1
    run_op(2'b01, 32'hFFFF_FFFF, 32'h0000_0010, 0, 1'b0);   // DIVU: 0x0FFFFFFF
    run_op(2'b00, 32'h8000_0000, 32'hFFFF_FFFF, 0, 1'b0);   // overflow

    // T2 delayed accept
    for (int d = 1; d <= 5; d++) run_op($urandom % 4, $urandom, $urandom | 1, d, 1'b0);

    // T3 kill at every position, then a full operation right after
    for (int k = 1; k <= 18; k++) begin
      killed_op(k, 1'b0);
      run_op($urandom % 4, $urandom, $urandom, 0, 1'b0);
    end
    for (int k = 1; k <= 17; k += 4) begin
      killed_op(k, 1'b1);
      run_op($urandom % 4, $urandom, $urandom, 0, 1'b0);
    end

    // T4 back-to-back
    for (int i = 0; i < 8; i++) begin
      run_op($urandom % 4, $urandom, $urandom, 0, 1'b1);
      cov_b2b++;
    end
    idle();
    @(posedge clk); #1;

    // T5 reset in the middle of an operation
    op = 2'b00; a = 32'd100; b = 32'd7; valid = 1'b1;
    repeat (6) @(posedge clk);
    #2 rst_n = 1'b0; #1;
    checks++;
    if (busy || done) fail("asynchronous reset did not stop the divider");
    valid = 1'b0;
    @(negedge clk); rst_n = 1'b1;
    @(posedge clk); #1;
    run_op(2'b00, 32'd100, 32'd7, 0, 1'b0);

    // T6 random
    for (int i = 0; i < NUM_RANDOM; i++) begin
      logic [31:0] x, y;
      x = $urandom; y = $urandom;
      case ($urandom % 8)
        0: y = $urandom % 16;                  // small divisors, including 0
        1: x = corner[$urandom % 14];
        2: y = corner[$urandom % 14];
        3: y = y >> ($urandom % 32);           // divisor magnitudes across the range
        default: ;
      endcase
      if (($urandom % 50) == 0) begin
        killed_op(1 + $urandom % 18, 1'b0);
      end
      run_op($urandom % 4, x, y, ($urandom % 10 == 0) ? 1 + $urandom % 3 : 0, 1'b0);
    end

    begin
      int holes;
      holes = 0;
      for (int o = 0; o < 4; o++) begin
        for (int s = 0; s < 4; s++) if (cov_sign[o][s] == 0) begin holes++; $display("hole: op %0d signs %0d", o, s); end
        if (cov_div0[o] == 0) begin holes++; $display("hole: op %0d divide by zero", o); end
        if (cov_ovf[o] == 0)  begin holes++; $display("hole: op %0d overflow operands", o); end
        if (cov_zero[o] == 0) begin holes++; $display("hole: op %0d zero result", o); end
      end
      for (int k = 1; k <= 18; k++) if (cov_kill[k] == 0) begin holes++; $display("hole: kill in cycle %0d", k); end
      if (cov_delay == 0)   begin holes++; $display("hole: delayed accept"); end
      if (cov_b2b == 0)     begin holes++; $display("hole: back-to-back"); end
      if (cov_abandon == 0) begin holes++; $display("hole: abandon by valid"); end
      if (holes != 0) fail($sformatf("%0d coverage holes", holes));
    end

    if (errors == 0)
      $display("PASS tb_px_div (%0d checks, every result at exactly 17 cycles, kill at every cycle, %0d random operations, full functional coverage)",
               checks, NUM_RANDOM);
    else begin
      $display("FAIL tb_px_div (%0d errors, %0d checks)", errors, checks);
      $fatal(1, "tb_px_div failed");
    end
    $finish;
  end

endmodule
