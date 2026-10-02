// px_div_fv: formal harness for px_div (SymbiYosys, tb/formal/px_div.sby).
//
// Environment: arbitrary valid_i, kill_i, op_i, a_i and b_i in every cycle; accept_i only
// while done_o is high (as the core drives it), otherwise arbitrary. A reference of the
// interface timing (the "spec" registers below, written from the px_div header, not from
// its counter) tracks when an operation starts, how many cycles it has run and which
// operands it sampled in its first cycle.
//
// Properties
//   Q1  done_o exactly in the 17th cycle of an uninterrupted operation and after it until
//       accept_i (never early, never for an abandoned operation)
//   Q2  result_o equals the RV32M result of the operands sampled in cycle 1 (division
//       rounding towards zero, remainder with the dividend's sign, divide by zero gives
//       all ones / the dividend, -2^31 / -1 gives -2^31 / 0), for all 2^64 operand pairs
//       of every op, whenever done_o is high
//   Q3  busy_o follows the reference: idle in the cycle after kill_i, after valid_i falls
//       and after accept_i
// Scope: bounded model checking from reset (depth in px_div.sby), so operations that
// start in the first few cycles. Tasks (px_div.sby):
//   timing   Q1 and Q3 with fully symbolic operands (Q2 not checked)
//   small    Q1-Q3 with operands that are sign-extended 8-bit values (every sign, zero,
//            and every quotient/remainder of that range)
//   special  Q1-Q3 with a fully symbolic dividend and the divisor one of 0, 1, -1, 2, -2
//            (divide by zero, -2^31 / -1 and the magnitude/sign paths at full width)
//   full     Q1-Q3 with fully symbolic operands (may not finish: 32-bit division is hard
//            for the SMT solver)
//   bounds   Q4 with fully symbolic operands: the remainder is smaller than the divisor
//            in magnitude and has the dividend's sign (or is 0); no reference division
//   step     Q5 by k-induction (unbounded, every reachable state): each radix-4 step of
//            cycles 2-16 keeps 0 <= remainder < |d| and selects the largest digit k with
//            k|d| <= r4, the new remainder being r4 - k|d|. With the first digit (also
//            asserted) this is the textbook restoring-division induction, so the magnitude
//            quotient and remainder are exact for all operands; the composition over the
//            16 steps is argued, not machine-checked
//   relation Q6 with fully symbolic operands: dividend = quotient * divisor + remainder in
//            66-bit signed arithmetic (inconclusive: no result at step 17 within 15 minutes)

`timescale 1ns/1ps

module px_div_fv (
  input logic        clk_i,
  input logic        valid_i,
  input logic        kill_i,
  input logic        accept_choice,
  input logic [1:0]  op_i,
  input logic [31:0] a_i,
  input logic [31:0] b_i
);

  // reset in the first cycle only
  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = !init;

  logic        done, busy, accept_i;
  logic [31:0] result;
  assign accept_i = accept_choice && done;

  px_div dut (
    .clk_i, .rst_ni, .valid_i, .kill_i, .accept_i, .op_i, .a_i, .b_i,
    .done_o(done), .result_o(result), .busy_o(busy)
  );

  // ------------------------------------------------------------------ reference
  logic        s_active;
  logic [4:0]  s_cycle;          // cycle number of the running operation (1..17)
  logic [1:0]  s_op;
  logic [31:0] s_a, s_b;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      s_active <= 1'b0;
      s_cycle  <= 5'd0;
    end else if (kill_i || !valid_i) begin
      s_active <= 1'b0;
    end else if (!s_active) begin
      s_active <= 1'b1;
      s_cycle  <= 5'd2;
      s_op <= op_i; s_a <= a_i; s_b <= b_i;
    end else if (s_cycle != 5'd17) begin
      s_cycle <= s_cycle + 5'd1;
    end else if (accept_i) begin
      s_active <= 1'b0;
    end
  end

  // RV32M reference result
  logic [31:0] q_s, r_s, q_u, r_u, expect_res;
  logic        ovf;
  assign ovf = (s_a == 32'h8000_0000) && (s_b == 32'hFFFF_FFFF);
  // Signed division in signed-only expressions: an unsigned operand anywhere in the same
  // expression (e.g. a ternary with an unsigned constant) would make it unsigned.
  logic signed [31:0] sa, sb, sq, sr;
  assign sa  = s_a;
  assign sb  = s_b;
  assign sq  = sa / sb;
  assign sr  = sa % sb;
  assign q_s = (s_b == 32'd0) ? 32'hFFFF_FFFF : ovf ? 32'h8000_0000 : sq;
  assign r_s = (s_b == 32'd0) ? s_a : ovf ? 32'd0 : sr;
  assign q_u = (s_b == 32'd0) ? 32'hFFFF_FFFF : s_a / s_b;
  assign r_u = (s_b == 32'd0) ? s_a : s_a % s_b;
  always_comb begin
    case (s_op)
      2'b00:   expect_res = q_s;
      2'b01:   expect_res = q_u;
      2'b10:   expect_res = r_s;
      default: expect_res = r_u;
    endcase
  end

  // ------------------------------------------------------------------ properties
`ifndef STEP   // Q1/Q3 relate the divider to the reference: proven by BMC, not inductive
  always_comb if (rst_ni) assert (done == (s_active && s_cycle == 5'd17));   // Q1
`endif
`ifndef TIMING_ONLY
  always_comb if (rst_ni && done) assert (result == expect_res);             // Q2
`endif

  // Operand restrictions per task (applied to the operands sampled in cycle 1)
  logic starting;
  assign starting = rst_ni && valid_i && !kill_i && !s_active;
`ifdef SMALL_OPERANDS
  always_comb if (starting) assume (a_i == {{24{a_i[7]}}, a_i[7:0]} && b_i == {{24{b_i[7]}}, b_i[7:0]});
`endif
`ifdef SPECIAL_DIVISOR
  always_comb if (starting) assume (b_i == 32'd0 || b_i == 32'd1 || b_i == 32'hFFFF_FFFF ||
                                    b_i == 32'd2 || b_i == 32'hFFFF_FFFE);
`endif
`ifndef STEP
  always_comb if (rst_ni) assert (busy == s_active);                         // Q3
`endif

`ifdef BOUNDS
  // Q4: remainder magnitude and sign (read from the divider's quotient/remainder muxes)
  logic signed [32:0] r33, b33, a33;
  logic [32:0] r_mag, b_mag;
  assign r33   = {dut.signed_q && dut.rem[31], dut.rem};
  assign b33   = {dut.signed_q && s_b[31], s_b};
  assign a33   = {dut.signed_q && s_a[31], s_a};
  assign r_mag = r33[32] ? -r33 : r33;
  assign b_mag = b33[32] ? -b33 : b33;
  always_comb if (rst_ni && done && s_b != 32'd0) begin
    assert (r_mag < b_mag);
    assert (dut.rem == 32'd0 || r33[32] == a33[32]);
  end
`endif

`ifdef STEP
  // Q5: local radix-4 step and the first digit
  logic [35:0] d1, d2, d3;
  assign d1 = {4'd0, dut.d_q};
  assign d2 = {3'd0, dut.d_q, 1'b0};
  assign d3 = d1 + d2;
  always_comb if (rst_ni && dut.active_q && dut.d_q != 32'd0) begin
    assert (dut.rem_q < dut.d_q);
    if (dut.cnt_q != 5'd16) begin
      assert (dut.r4_rem < dut.d_q);
      case (dut.dig)
        2'd0: assert (dut.r4 < d1 && dut.r4_rem == dut.r4[31:0]);
        2'd1: assert (dut.r4 >= d1 && dut.r4 < d2 && {4'd0, dut.r4_rem} == dut.r4 - d1);
        2'd2: assert (dut.r4 >= d2 && dut.r4 < d3 && {4'd0, dut.r4_rem} == dut.r4 - d2);
        default: assert (dut.r4 >= d3 && {4'd0, dut.r4_rem} == dut.r4 - d3);
      endcase
    end
  end
  // first digit: r0 = 2-bit top of |a|; digit and remainder as in restoring division
  logic [3:0] r0x;
  assign r0x = {2'd0, dut.r0};
  always_comb if (rst_ni && !dut.active_q && valid_i && !kill_i && !dut.ub_is0) begin
    assert ({2'd0, dut.rem0} < dut.ub || dut.ub > 32'd3);
    if (dut.ub <= 32'd3)
      assert (r0x == dut.dig0 * dut.ub[3:0] + {2'd0, dut.rem0});
    else
      assert (dut.dig0 == 2'd0 && dut.rem0 == dut.r0);
  end
  // (d_q is written only in cycle 1, so it stays the divisor magnitude while active)
`endif

`ifdef RELATION
  // Q6: a = q * b + r (66-bit signed), outside divide by zero
  logic signed [65:0] q66, b66, r66, a66;
  assign q66 = dut.signed_q ? {{34{dut.quo[31]}}, dut.quo} : {34'd0, dut.quo};
  assign r66 = dut.signed_q ? {{34{dut.rem[31]}}, dut.rem} : {34'd0, dut.rem};
  assign b66 = dut.signed_q ? {{34{s_b[31]}}, s_b} : {34'd0, s_b};
  assign a66 = dut.signed_q ? {{34{s_a[31]}}, s_a} : {34'd0, s_a};
  always_comb if (rst_ni && done && s_b != 32'd0 && !ovf)
    assert (a66 == q66 * b66 + r66);
`endif

  // Reachability: a result, a result held for a cycle, a kill of a running operation
  always_comb cover (rst_ni && done && s_op == 2'b10 && s_a[31] && !s_b[31]);
  always_comb cover (rst_ni && done && !accept_i);
  always_comb cover (rst_ni && s_active && s_cycle == 5'd9 && kill_i);

endmodule
