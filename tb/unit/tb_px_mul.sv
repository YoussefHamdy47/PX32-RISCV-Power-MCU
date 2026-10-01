// tb_px_mul: self-checking unit test for px_mul (step 1.7, DECISIONS.md D-023).
//
// Reference model: 64-bit integer arithmetic (longint), written from the RV32M definitions
// (MUL low word; MULH signed x signed, MULHSU signed x unsigned, MULHU unsigned x unsigned,
// upper word). Checks:
//   T1 every operation on every pair of 14 corner operands (0, 1, 2, -1, -2, INT_MIN,
//      INT_MIN + 1, INT_MAX, 0xFFFF, 0x10000, 0x8000, 0x7FFF, 0xAAAAAAAA, 0x55555555)
//   T2 single-bit operands: every bit position of a and of b against a fixed partner
//   T3 pipeline: back-to-back issue every cycle (throughput 1), result in the next cycle,
//      held while en_i is low; asynchronous reset clears the register
//   T4 50,000 random operand pairs with random ops
// Functional coverage: for each op, all four operand sign combinations, a zero result, a
// negative result, and the high word nonzero; any hole fails the test.
//
// Run: scripts/run_unit.sh tb_px_mul [+vcd]

`timescale 1ns/1ps

module tb_px_mul;

  localparam int NUM_RANDOM = 50000;

  logic        clk = 1'b0;
  logic        rst_n;
  logic        en;
  logic [1:0]  op;
  logic [31:0] a, b, res;

  px_mul dut (.clk_i(clk), .rst_ni(rst_n), .en_i(en), .op_i(op), .a_i(a), .b_i(b), .result_o(res));

  always #5 clk = ~clk;

  int checks = 0, errors = 0;
  int cov [0:3][0:6];      // op x {++, +-, -+, --, zero result, negative result, high nonzero}

  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("ERROR %0t: %s", $time, msg);
  endtask

  function automatic logic [31:0] model(input logic [1:0] o, input logic [31:0] x, input logic [31:0] y);
    longint          sx, sy, p;
    longint unsigned ux, uy, up;
    sx = longint'($signed(x));
    sy = longint'($signed(y));
    ux = {32'd0, x};
    uy = {32'd0, y};
    case (o)
      2'b00: begin up = ux * uy; return up[31:0]; end            // MUL
      2'b01: begin p = sx * sy;  return p[63:32]; end            // MULH
      2'b10: begin p = sx * longint'(uy); return p[63:32]; end   // MULHSU
      default: begin up = ux * uy; return up[63:32]; end         // MULHU
    endcase
  endfunction

  // Issue one operation (inputs set before the edge), check the result after it.
  task automatic issue_check(input logic [1:0] o, input logic [31:0] x, input logic [31:0] y);
    logic [31:0] exp;
    exp = model(o, x, y);
    op = o; a = x; b = y; en = 1'b1;
    @(posedge clk); #1;
    checks++;
    if (res !== exp)
      fail($sformatf("op %0d a %08h b %08h: %08h, expected %08h", o, x, y, res, exp));
    cov[o][{x[31], y[31]}]++;
    if (exp == 32'd0) cov[o][4]++;
    if (exp[31]) cov[o][5]++;
    if (o != 2'b00 && exp != 32'd0) cov[o][6]++;
    if (o == 2'b00 && model(2'b11, x, y) != 32'd0) cov[o][6]++;
  endtask

  logic [31:0] corner [0:13];

  initial begin
    logic [31:0] exp, held;
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_mul.vcd");
      $dumpvars(0, tb_px_mul);
    end
    for (int o = 0; o < 4; o++) for (int k = 0; k < 7; k++) cov[o][k] = 0;
    corner[0] = 32'h0;        corner[1] = 32'h1;        corner[2] = 32'h2;
    corner[3] = 32'hFFFF_FFFF; corner[4] = 32'hFFFF_FFFE; corner[5] = 32'h8000_0000;
    corner[6] = 32'h8000_0001; corner[7] = 32'h7FFF_FFFF; corner[8] = 32'h0000_FFFF;
    corner[9] = 32'h0001_0000; corner[10] = 32'h0000_8000; corner[11] = 32'h0000_7FFF;
    corner[12] = 32'hAAAA_AAAA; corner[13] = 32'h5555_5555;

    rst_n = 1'b0; en = 1'b0; op = 2'b00; a = 32'd0; b = 32'd0;
    repeat (2) @(posedge clk);
    #1;
    checks++;
    if (res !== 32'd0) fail("reset: result not 0");
    @(negedge clk); rst_n = 1'b1;

    // T1 corners
    for (int o = 0; o < 4; o++)
      for (int i = 0; i < 14; i++)
        for (int j = 0; j < 14; j++)
          issue_check(o, corner[i], corner[j]);
    // explicit spot values (independent of the model)
    issue_check(2'b01, 32'h8000_0000, 32'h8000_0000);
    if (res !== 32'h4000_0000) fail("MULH INT_MIN * INT_MIN");
    issue_check(2'b10, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
    if (res !== 32'hFFFF_FFFF) fail("MULHSU -1 * 0xFFFFFFFF");
    issue_check(2'b11, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
    if (res !== 32'hFFFF_FFFE) fail("MULHU 0xFFFFFFFF^2");
    issue_check(2'b00, 32'h1234_5678, 32'h9ABC_DEF0);
    if (res !== 32'h242D_2080) fail("MUL low word");
    checks += 4;

    // T2 single bits
    for (int o = 0; o < 4; o++)
      for (int k = 0; k < 32; k++) begin
        issue_check(o, 32'd1 << k, 32'hDEAD_BEEF);
        issue_check(o, 32'hCAFE_F00D, 32'd1 << k);
      end

    // T3 pipeline: hold with en low, then reset
    issue_check(2'b01, 32'h7654_3210, 32'hFEDC_BA98);
    held = res;
    en = 1'b0; op = 2'b00; a = 32'd3; b = 32'd5;
    repeat (3) begin
      @(posedge clk); #1;
      checks++;
      if (res !== held) fail("result changed while en_i was low");
    end
    #2 rst_n = 1'b0; #1;
    checks++;
    if (res !== 32'd0) fail("asynchronous reset did not clear the result");
    @(negedge clk); rst_n = 1'b1;

    // T4 random, back to back every cycle
    for (int i = 0; i < NUM_RANDOM; i++) begin
      logic [31:0] x, y;
      x = $urandom; y = $urandom;
      if (($urandom % 8) == 0) x = corner[$urandom % 14];
      if (($urandom % 8) == 0) y = corner[$urandom % 14];
      issue_check($urandom % 4, x, y);
    end

    begin
      int holes;
      holes = 0;
      for (int o = 0; o < 4; o++)
        for (int k = 0; k < 7; k++)
          if (cov[o][k] == 0) begin
            holes++;
            $display("hole: op %0d bin %0d", o, k);
          end
      if (holes != 0) fail($sformatf("%0d coverage holes", holes));
    end

    if (errors == 0)
      $display("PASS tb_px_mul (%0d checks, %0d random operations, full functional coverage)", checks, NUM_RANDOM);
    else begin
      $display("FAIL tb_px_mul (%0d errors, %0d checks)", errors, checks);
      $fatal(1, "tb_px_mul failed");
    end
    $finish;
  end

endmodule
