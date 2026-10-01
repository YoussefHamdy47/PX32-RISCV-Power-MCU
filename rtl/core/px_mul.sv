// px_mul: two-stage multiplier for MUL, MULH, MULHSU, MULHU (Phase 1, step 1.7).
//
// Implements ARCHITECTURE.md § 4.1 ("multiplier stage 1" in EX, "stage 2" in MEM/WB;
// MUL 1 throughput, 2 latency) as fixed by DECISIONS.md D-023. RV32M semantics follow the
// unprivileged manual release 20240411 (IMPLEMENTATION_CONTRACTS.md § 1).
//
// Stage 1 (EX, combinational into the internal pipeline register):
//   Both operands are extended to 33 bits: rs1 signed for MULH/MULHSU, rs2 signed for
//   MULH, zero-extended otherwise. rs2 is split into a zero-extended 16-bit low part and
//   a 17-bit signed high part, and two 33 x 17 signed partial products are formed:
//   p_lo = a33 * b[15:0], p_hi = a33 * b33[32:16]. The product is p_hi * 2^16 + p_lo.
// Stage 2 (WB, combinational from the register):
//   one 64-bit addition and the high/low word select. The low 64 bits of the 66-bit
//   product are exact (modular arithmetic), which is all RV32M needs.
//
// Interface timing
//   en_i loads the stage-1 register (the core's EX/WB register moves and the instruction
//   in EX is a multiply). result_o is valid in the following cycle(s) while the register
//   holds that multiply; the core writes it at retirement. No reset is needed for the data
//   register (its value is only used while the core marks WB as holding a multiply), but it
//   is reset anyway so that no X reaches the WB write mux.
//
// Latency: 2 cycles (result usable by the instruction two behind the MUL); throughput 1.

`timescale 1ns/1ps

module px_mul (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        en_i,
  input  logic [1:0]  op_i,        // funct3[1:0]: 00 MUL, 01 MULH, 10 MULHSU, 11 MULHU
  input  logic [31:0] a_i,         // rs1
  input  logic [31:0] b_i,         // rs2
  output logic [31:0] result_o
);

  // Operand extension
  logic        a_signed, b_signed;
  assign a_signed = (op_i == 2'b01) || (op_i == 2'b10);    // MULH, MULHSU
  assign b_signed = (op_i == 2'b01);                        // MULH

  logic signed [32:0] a33, b33;
  assign a33 = {a_signed && a_i[31], a_i};
  assign b33 = {b_signed && b_i[31], b_i};

  logic signed [16:0] b_hi, b_lo;
  assign b_hi = b33[32:16];
  assign b_lo = {1'b0, b33[15:0]};

  // Stage 1: two 33 x 17 partial products
  logic signed [49:0] p_lo_d;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [49:0] p_hi_d;
  /* verilator lint_on UNUSEDSIGNAL */
  assign p_lo_d = a33 * b_lo;
  assign p_hi_d = a33 * b_hi;

  // p_hi bits 49:48 only reach product bits 65:64, which RV32M never uses.
  logic signed [49:0] p_lo_q;
  logic        [47:0] p_hi_q;
  logic               high_q;           // return the upper word

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p_lo_q <= '0;
      p_hi_q <= '0;
      high_q <= 1'b0;
    end else if (en_i) begin
      p_lo_q <= p_lo_d;
      p_hi_q <= p_hi_d[47:0];
      high_q <= (op_i != 2'b00);
    end
  end

  // Stage 2: final addition and word select (low 64 bits of the 66-bit product)
  logic [63:0] lo_ext, hi_shift, product;
  assign lo_ext   = {{14{p_lo_q[49]}}, p_lo_q};
  assign hi_shift = {p_hi_q, 16'd0};
  assign product  = hi_shift + lo_ext;
  assign result_o = high_q ? product[63:32] : product[31:0];

endmodule
