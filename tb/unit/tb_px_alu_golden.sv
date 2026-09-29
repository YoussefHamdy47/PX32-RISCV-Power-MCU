// tb_px_alu_golden: px_alu against vectors from an independent Python model.
//
// tb_px_alu checks the RTL against a SystemVerilog reference model. This bench adds a
// second, independently written model (scripts/gen_alu_vectors.py) so that a mistake
// shared between the RTL and the SV reference (same author, same language) is caught.
//
// Vector format: see scripts/gen_alu_vectors.py.

`timescale 1ns/1ps

module tb_px_alu_golden;

  import px_pkg::*;

  localparam int    MAX_VECTORS = 10000;  // must equal the count written by gen_alu_vectors.py
  localparam string VEC_FILE    = "tb/unit/vectors/alu_vectors.hex";

  logic [111:0] mem [0:MAX_VECTORS];

  alu_op_e     op;
  logic [31:0] a, b;
  logic [31:0] res;
  logic        eq, lt, ltu;

  px_alu dut (
    .op_i    (op),
    .a_i     (a),
    .b_i     (b),
    .result_o(res),
    .eq_o    (eq),
    .lt_o    (lt),
    .ltu_o   (ltu)
  );

  initial begin
    int          count;
    int          errors;
    logic [31:0] exp_res;
    logic [2:0]  exp_flags;

    errors = 0;
    mem[0] = 'x;
    $readmemh(VEC_FILE, mem);
    if ($isunknown(mem[0])) begin
      $display("FAIL tb_px_alu_golden (could not read %s)", VEC_FILE);
      $finish;
    end
    count = int'(mem[0][31:0]);
    if (count != MAX_VECTORS) begin
      $display("FAIL tb_px_alu_golden (bad vector count %0d)", count);
      $finish;
    end

    for (int n = 1; n <= count; n++) begin
      op        = alu_op_e'(mem[n][108:104]);
      a         = mem[n][103:72];
      b         = mem[n][71:40];
      exp_res   = mem[n][39:8];
      exp_flags = mem[n][2:0];
      #1;
      if (res !== exp_res || {eq, lt, ltu} !== exp_flags) begin
        errors++;
        if (errors <= 20)
          $display("ERROR vector %0d op=%0d a=%08h b=%08h : res=%08h exp=%08h flags=%b exp=%b",
                   n, op, a, b, res, exp_res, {eq, lt, ltu}, exp_flags);
      end
    end

    if (errors == 0) $display("PASS tb_px_alu_golden (%0d vectors)", count);
    else             $display("FAIL tb_px_alu_golden (%0d errors / %0d vectors)", errors, count);
    $finish;
  end

endmodule
