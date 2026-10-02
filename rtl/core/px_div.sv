// px_div: iterative divider for DIV, DIVU, REM, REMU with a fixed 17-cycle schedule
// (Phase 1, step 1.7).
//
// Implements ARCHITECTURE.md § 4.1 ("DIV / REM, radix-4 iterative", interrupt-killable) and
// IMPLEMENTATION_CONTRACTS.md § 3.3 (fixed 17 cycles for every operand, including divide by
// zero and signed overflow; no early completion), as fixed by DECISIONS.md D-023. RV32M
// semantics follow the unprivileged manual release 20240411:
//   divide by zero: quotient all ones (DIV and DIVU), remainder = dividend
//   signed overflow (DIV: -2^31 / -1): quotient -2^31, remainder 0
//   the remainder has the sign of the dividend; the quotient rounds towards zero
//
// Algorithm: restoring division of the operand magnitudes |a| / |d|, 32 quotient bits:
//   cycle 1       magnitudes (one negation each) and the first radix-4 digit, from the top
//                 two bits of |a| (a partial remainder of 0..3): only |d| <= 3 can fit,
//                 which equality tests on the raw divisor decide
//   cycles 2-16   one radix-4 step each: r4 - |d|, r4 - 2|d|, r4 - 3|d| in parallel (3|d|
//                 as a three-operand sum), the largest non-negative one gives the digit
//   cycle 17      the sign fix from registered values (one negation each, in parallel)
//                 and the divide-by-zero mux
// Every cycle has one adder level (a carry-save level for 3|d|) followed by selection.
// The overflow case needs no special logic: |-2^31| / 1 = 2^31, which is -2^31 as a
// 32-bit result.
//
// Interface timing (cycle 1 is the first cycle in which valid_i is high while idle):
//   valid_i   a divide is in EX and may run (the core deasserts it when the instruction
//             is not valid there any more; the divider then abandons the operation)
//   kill_i    abandon the operation (EX flush by an older bus error; Phase 2 adds
//             interrupt entry). Wins over everything; a new operation may start in the
//             next cycle
//   a_i, b_i  sampled in cycle 1 only
//   done_o    high in cycle 17 and after, until accept_i (the instruction leaves EX);
//             result_o is valid while done_o is high
//   accept_i  the result is taken this cycle; the divider is idle in the next cycle, so a
//             back-to-back divide starts one cycle later
// Latency: 17 cycles from cycle 1 to the cycle the result is taken, for every operand.

`timescale 1ns/1ps

module px_div (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        valid_i,
  input  logic        kill_i,
  input  logic        accept_i,
  input  logic [1:0]  op_i,        // funct3[1:0]: 00 DIV, 01 DIVU, 10 REM, 11 REMU
  input  logic [31:0] a_i,         // dividend (rs1)
  input  logic [31:0] b_i,         // divisor (rs2)
  output logic        done_o,
  output logic [31:0] result_o,
  output logic        busy_o       // an operation is in progress (cycles 2..17)
);

  localparam logic [4:0] LAST = 5'd16;   // counter value in cycle 17

  logic        active_q;
  logic [4:0]  cnt_q;                    // cycle number - 1 while active (1..16)
  logic [31:0] rem_q;                    // partial remainder (< |d|)
  logic [31:0] dq_q;                     // remaining dividend bits (top), quotient (bottom)
  logic [31:0] d_q, a_q;                 // |d|; original dividend (for divide by zero)
  logic        signed_q, is_rem_q, a_neg_q, b_neg_q, div0_q;

  // ---------------------------------------------------------------------------
  // Cycle 1: magnitudes and the first digit
  // ---------------------------------------------------------------------------
  logic        op_signed, a_neg, b_neg;
  logic [31:0] ua, ub;
  assign op_signed = !op_i[0];
  assign a_neg     = op_signed && a_i[31];
  assign b_neg     = op_signed && b_i[31];
  assign ua        = a_neg ? (32'd0 - a_i) : a_i;
  assign ub        = b_neg ? (32'd0 - b_i) : b_i;

  // First digit: partial remainder r0 = |a| bits 31:30 (0..3). |d| = 0 (overridden by the
  // divide-by-zero result), 1, 2 or 3 can fit; decided by equality tests on b_i.
  logic [1:0] r0, dig0, rem0;
  logic       ub_is0, ub_is1, ub_is2, ub_is3;
  assign r0     = ua[31:30];
  logic r0_hi, r0_lo;                    // bit selects outside always_comb (guide § 3.3)
  assign r0_hi  = r0[1];
  assign r0_lo  = r0[0];
  assign ub_is0 = (b_i == 32'd0);
  assign ub_is1 = (b_i == 32'd1) || (b_neg && b_i == 32'hFFFF_FFFF);
  assign ub_is2 = (b_i == 32'd2) || (b_neg && b_i == 32'hFFFF_FFFE);
  assign ub_is3 = (b_i == 32'd3) || (b_neg && b_i == 32'hFFFF_FFFD);
  always_comb begin
    dig0 = 2'd0;
    rem0 = r0;
    if (ub_is0)      begin dig0 = 2'd3; rem0 = r0; end
    else if (ub_is1) begin dig0 = r0;   rem0 = 2'd0; end
    else if (ub_is2) begin dig0 = {1'b0, r0_hi}; rem0 = {1'b0, r0_lo}; end
    else if (ub_is3) begin dig0 = (r0 == 2'd3) ? 2'd1 : 2'd0; rem0 = (r0 == 2'd3) ? 2'd0 : r0; end
  end

  // ---------------------------------------------------------------------------
  // Cycles 2..16: one radix-4 step (candidates in parallel)
  // The subtractions are wider than their results: the top bit is the borrow, and the bits
  // between it and bit 31 are zero whenever the value is selected.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  logic [35:0] r4, t1, t2, t3;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0]  dig;
  logic [31:0] r4_rem;
  assign r4  = {2'b00, rem_q, dq_q[31:30]};
  assign t1  = r4 - {4'd0, d_q};
  assign t2  = r4 - {3'd0, d_q, 1'b0};
  assign t3  = r4 - {4'd0, d_q} - {3'd0, d_q, 1'b0};
  assign dig = !t3[35] ? 2'd3 : !t2[35] ? 2'd2 : !t1[35] ? 2'd1 : 2'd0;
  assign r4_rem = (dig == 2'd3) ? t3[31:0] : (dig == 2'd2) ? t2[31:0] :
                  (dig == 2'd1) ? t1[31:0] : r4[31:0];

  // ---------------------------------------------------------------------------
  // Cycle 17: signs and special cases (all quotient bits are in dq_q, the remainder in
  // rem_q)
  // ---------------------------------------------------------------------------
  logic        q_neg, r_neg;
  logic [31:0] quo, rem;
  assign q_neg    = signed_q && (a_neg_q != b_neg_q) && !div0_q;
  assign r_neg    = signed_q && a_neg_q;
  assign quo      = div0_q ? 32'hFFFF_FFFF : (q_neg ? (32'd0 - dq_q) : dq_q);
  assign rem      = div0_q ? a_q : (r_neg ? (32'd0 - rem_q) : rem_q);
  assign result_o = is_rem_q ? rem : quo;

  assign done_o = active_q && (cnt_q == LAST);
  assign busy_o = active_q;

  // ---------------------------------------------------------------------------
  // Sequencing
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= 1'b0;
      cnt_q    <= 5'd0;
      rem_q    <= 32'd0; dq_q <= 32'd0; d_q <= 32'd0; a_q <= 32'd0;
      signed_q <= 1'b0;  is_rem_q <= 1'b0; a_neg_q <= 1'b0; b_neg_q <= 1'b0; div0_q <= 1'b0;
    end else if (kill_i || !valid_i) begin
      active_q <= 1'b0;                     // abandon; nothing is written anywhere
    end else if (!active_q) begin
      // cycle 1: start
      active_q <= 1'b1;
      cnt_q    <= 5'd1;
      rem_q    <= {30'd0, rem0};
      dq_q     <= {ua[29:0], dig0};
      d_q      <= ub;
      a_q      <= a_i;
      signed_q <= op_signed;
      is_rem_q <= op_i[1];
      a_neg_q  <= a_neg;
      b_neg_q  <= b_neg;
      div0_q   <= ub_is0;
    end else if (cnt_q != LAST) begin
      // cycles 2..16: radix-4 step
      rem_q <= r4_rem;
      dq_q  <= {dq_q[29:0], dig};
      cnt_q <= cnt_q + 5'd1;
    end else if (accept_i) begin
      active_q <= 1'b0;                     // cycle 17 (or later): result taken
    end
  end

endmodule
