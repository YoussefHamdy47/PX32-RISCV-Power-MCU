// tb_px_alu: self-checking unit test for px_alu.
//
// Checks every defined operation and the three compare flags against an independent
// reference model:
//   1. all pairs from a table of corner values, for every operation
//   2. every shift amount 0..31, with junk in b_i[31:5]
//   3. random operands (fixed seed, reproducible)
//   4. undefined op codes return 0
// The shift reference is written bit by bit so it does not reuse the RTL's operators.
//
// Run: scripts/run_unit.sh tb_px_alu   (add +vcd for a waveform in sim/tb_px_alu.vcd)

`timescale 1ns/1ps

module tb_px_alu;

  import px_pkg::*;

  localparam int NUM_RANDOM = 20000;
  localparam int NUM_OPS    = 10;

  alu_op_e     op;
  logic [31:0] a, b;
  logic [31:0] res;
  logic        eq, lt, ltu;

  int checks = 0;
  int errors = 0;

  px_alu dut (
    .op_i    (op),
    .a_i     (a),
    .b_i     (b),
    .result_o(res),
    .eq_o    (eq),
    .lt_o    (lt),
    .ltu_o   (ltu)
  );

  // Filled element by element in init_tables(): Icarus 12 does not support
  // whole-array assignment patterns.
  alu_op_e     ops     [NUM_OPS];
  logic [31:0] corners [16];

  task automatic init_tables();
    ops[0] = ALU_ADD;  ops[1] = ALU_SUB;  ops[2] = ALU_SLL; ops[3] = ALU_SLT;
    ops[4] = ALU_SLTU; ops[5] = ALU_XOR;  ops[6] = ALU_SRL; ops[7] = ALU_SRA;
    ops[8] = ALU_OR;   ops[9] = ALU_AND;

    corners[0]  = 32'h0000_0000; corners[1]  = 32'h0000_0001;
    corners[2]  = 32'h0000_0002; corners[3]  = 32'h0000_001F;
    corners[4]  = 32'h0000_0020; corners[5]  = 32'h7FFF_FFFE;
    corners[6]  = 32'h7FFF_FFFF; corners[7]  = 32'h8000_0000;
    corners[8]  = 32'h8000_0001; corners[9]  = 32'hFFFF_FFFE;
    corners[10] = 32'hFFFF_FFFF; corners[11] = 32'h5555_5555;
    corners[12] = 32'hAAAA_AAAA; corners[13] = 32'h0000_FFFF;
    corners[14] = 32'hFFFF_0000; corners[15] = 32'h1234_5678;
  endtask

  // ---------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] ref_shift(input logic [31:0] x, input logic [4:0] s,
                                            input bit left, input bit arith);
    logic [31:0] r;
    r = x;
    for (int i = 0; i < s; i++) begin
      if (left) r = {r[30:0], 1'b0};
      else      r = {(arith ? r[31] : 1'b0), r[31:1]};
    end
    return r;
  endfunction

  function automatic logic [31:0] ref_result(input alu_op_e o, input logic [31:0] x,
                                             input logic [31:0] y);
    case (o)
      ALU_ADD:  return x + y;
      ALU_SUB:  return x - y;
      ALU_SLL:  return ref_shift(x, y[4:0], 1'b1, 1'b0);
      ALU_SLT:  return ($signed(x) < $signed(y)) ? 32'd1 : 32'd0;
      ALU_SLTU: return (x < y) ? 32'd1 : 32'd0;
      ALU_XOR:  return x ^ y;
      ALU_SRL:  return ref_shift(x, y[4:0], 1'b0, 1'b0);
      ALU_SRA:  return ref_shift(x, y[4:0], 1'b0, 1'b1);
      ALU_OR:   return x | y;
      ALU_AND:  return x & y;
      default:  return 32'd0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Apply one vector and compare result + flags
  // ---------------------------------------------------------------------------
  task automatic check(input alu_op_e o, input logic [31:0] x, input logic [31:0] y);
    logic [31:0] exp_res;
    logic        exp_eq, exp_lt, exp_ltu;
    op = o; a = x; b = y;
    #1;
    exp_res = ref_result(o, x, y);
    exp_eq  = (x == y);
    exp_lt  = ($signed(x) < $signed(y));
    exp_ltu = (x < y);
    checks++;
    if (res !== exp_res || eq !== exp_eq || lt !== exp_lt || ltu !== exp_ltu) begin
      errors++;
      if (errors <= 20)
        $display("ERROR op=%0d a=%08h b=%08h : res=%08h exp=%08h  eq/lt/ltu=%b%b%b exp=%b%b%b",
                 o, x, y, res, exp_res, eq, lt, ltu, exp_eq, exp_lt, exp_ltu);
    end
    sample_coverage(o, x, y);
  endtask

  // ---------------------------------------------------------------------------
  // Functional coverage (hand-written bins: Icarus has no covergroups).
  // Every bin must be hit, otherwise the test fails: a passing run with a hole in
  // the stimulus would prove nothing about that case.
  // ---------------------------------------------------------------------------
  bit cov_sign    [NUM_OPS][4];  // operand sign combination {a[31], b[31]} per op
  bit cov_zero    [NUM_OPS];     // result == 0 per op
  bit cov_nonzero [NUM_OPS];     // result != 0 per op
  bit cov_msb     [NUM_OPS];     // result[31] == 1 per op (not reachable for SLT/SLTU)
  bit cov_flags   [5];           // eq | lt&ltu | lt&!ltu | !lt&ltu | !lt&!ltu&!eq
  bit cov_shamt   [3][32];       // SLL/SRL/SRA x every shift amount
  bit cov_bit0    [32];          // each result bit seen as 0 ...
  bit cov_bit1    [32];          // ... and as 1
  bit cov_add_ovf, cov_add_carry, cov_sub_ovf, cov_sub_borrow, cov_undef;

  task automatic sample_coverage(input alu_op_e o, input logic [31:0] x, input logic [31:0] y);
    int k;
    k = int'(o);
    if (k >= NUM_OPS) begin
      cov_undef = 1'b1;
    end else begin
      sample_defined(k, o, x, y);
    end
  endtask

  task automatic sample_defined(input int k, input alu_op_e o, input logic [31:0] x,
                                input logic [31:0] y);
    logic [32:0] s33;
    logic [31:0] d;
    cov_sign[k][{x[31], y[31]}] = 1'b1;
    if (res == 32'd0) cov_zero[k]    = 1'b1;
    else              cov_nonzero[k] = 1'b1;
    if (res[31])      cov_msb[k]     = 1'b1;
    for (int i = 0; i < 32; i++) begin
      if (res[i]) cov_bit1[i] = 1'b1;
      else        cov_bit0[i] = 1'b1;
    end

    if (eq)              cov_flags[0] = 1'b1;
    else if (lt && ltu)  cov_flags[1] = 1'b1;
    else if (lt)         cov_flags[2] = 1'b1;
    else if (ltu)        cov_flags[3] = 1'b1;
    else                 cov_flags[4] = 1'b1;

    case (o)
      ALU_SLL: cov_shamt[0][y[4:0]] = 1'b1;
      ALU_SRL: cov_shamt[1][y[4:0]] = 1'b1;
      ALU_SRA: cov_shamt[2][y[4:0]] = 1'b1;
      ALU_ADD: begin
        s33 = {1'b0, x} + {1'b0, y};
        if (s33[32]) cov_add_carry = 1'b1;
        if (x[31] == y[31] && s33[31] != x[31]) cov_add_ovf = 1'b1;
      end
      ALU_SUB: begin
        d = x - y;
        if (x < y) cov_sub_borrow = 1'b1;
        if (x[31] != y[31] && d[31] != x[31]) cov_sub_ovf = 1'b1;
      end
      default: ;
    endcase
  endtask

  // Returns the number of unhit bins and prints each one.
  function automatic int report_coverage();
    int total, missing;
    total = 0; missing = 0;
    for (int k = 0; k < NUM_OPS; k++) begin
      for (int s = 0; s < 4; s++) begin
        total++; if (!cov_sign[k][s]) begin missing++; $display("  hole: op %0d sign combo %0d", k, s); end
      end
      total++; if (!cov_zero[k])    begin missing++; $display("  hole: op %0d result zero", k);    end
      total++; if (!cov_nonzero[k]) begin missing++; $display("  hole: op %0d result nonzero", k); end
      if (ops[k] != ALU_SLT && ops[k] != ALU_SLTU) begin
        total++; if (!cov_msb[k])   begin missing++; $display("  hole: op %0d result[31]=1", k);  end
      end
    end
    for (int f = 0; f < 5; f++) begin
      total++; if (!cov_flags[f]) begin missing++; $display("  hole: flag combo %0d", f); end
    end
    for (int t = 0; t < 3; t++)
      for (int s = 0; s < 32; s++) begin
        total++; if (!cov_shamt[t][s]) begin missing++; $display("  hole: shift type %0d amount %0d", t, s); end
      end
    for (int i = 0; i < 32; i++) begin
      total++; if (!cov_bit0[i]) begin missing++; $display("  hole: result bit %0d never 0", i); end
      total++; if (!cov_bit1[i]) begin missing++; $display("  hole: result bit %0d never 1", i); end
    end
    total++; if (!cov_add_ovf)    begin missing++; $display("  hole: ADD signed overflow");  end
    total++; if (!cov_add_carry)  begin missing++; $display("  hole: ADD carry out");        end
    total++; if (!cov_sub_ovf)    begin missing++; $display("  hole: SUB signed overflow");  end
    total++; if (!cov_sub_borrow) begin missing++; $display("  hole: SUB borrow");           end
    total++; if (!cov_undef)      begin missing++; $display("  hole: undefined op code");    end
    $display("coverage: %0d/%0d bins hit", total - missing, total);
    return missing;
  endfunction

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
    int seed;
    int holes;
    seed = 32'h005E_EDA1;
    init_tables();

    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_alu.vcd");
      $dumpvars(0, tb_px_alu);
    end

    // 1. Corner-value pairs for every operation
    for (int k = 0; k < NUM_OPS; k++)
      for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++)
          check(ops[k], corners[i], corners[j]);

    // 2. Every shift amount, with junk in the upper bits of b
    for (int s = 0; s < 32; s++)
      for (int i = 0; i < 16; i++) begin
        check(ALU_SLL, corners[i], 32'hFFFF_FFE0 | s);
        check(ALU_SRL, corners[i], 32'hA5A5_A5A0 & 32'hFFFF_FFE0 | s);
        check(ALU_SRA, corners[i], 32'h8000_0000 | s);
      end

    // 3. Random operands
    for (int n = 0; n < NUM_RANDOM; n++)
      check(ops[n % NUM_OPS], $random(seed), $random(seed));

    // 4. Undefined op codes
    for (int u = NUM_OPS; u < 32; u++)
      check(alu_op_e'(u), 32'hDEAD_BEEF, 32'h1234_5678);

    holes = report_coverage();

    if (errors == 0 && holes == 0)
      $display("PASS tb_px_alu (%0d checks, full functional coverage)", checks);
    else
      $display("FAIL tb_px_alu (%0d errors / %0d checks, %0d coverage holes)", errors, checks, holes);
    $finish;
  end

endmodule
