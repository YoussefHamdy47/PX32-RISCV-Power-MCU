// px_clic_fv: formal harness for px_clic (SymbiYosys, tb/formal/px_clic.sby; step 2.2c,
// DECISIONS.md D-034; PHASE2_VERIFICATION.md § 3.1).
//
// Configuration: the contract one, 64 inputs and 4 level bits.
// Environment: every input of px_clic is arbitrary in every cycle (inputs, bus, core
// state, ack and claim in any combination; the core's interface rules of D-034 item 9 are
// not assumed). Reset in the first cycle only.
//
// S and J are symbolic input ids: registers without reset that keep their (arbitrary)
// first value (yosys-slang ignores anyconst, IMPLEMENTATION_GUIDE.md § 3.3), so each
// property written for S holds for every input.
//
// Properties (D-034 item numbers in brackets)
//   P1  [10-12, 14] the registered winner is the maximum of {level, id} over the previous
//       cycle's pending-and-enabled set (computed here by a linear scan over the unit's
//       state), invalid when that set is empty or its maximum is the id acknowledged or
//       claimed in the previous cycle; an invalid winner reads id 0, level 0x0F, shv 0
//   P2  [13] irq_req_o = valid && clic_mode && level > mil && level > mintthresh, from
//       the current inputs
//   P3  [14] the id acknowledged or claimed in cycle T is not presented in cycle T+1
//   P4  [9, 14] at most one service per edge: after a vectored ack or a claim clears the
//       edge-mode pending bit of S (no edge or software set in the same cycle), S is not
//       presented again until an edge of S, a software set of S, or level mode for S
//   P5  [8] edge mode: the pending bit of S changes only by an edge (-> 1), a software
//       write of its byte (-> wdata[0]), or an ack (vectored winner) / claim of S (-> 0),
//       in that priority order
//   P6  [6, K-20] level mode: the pending bit of S is the input after polarity, one cycle
//       later, whatever is written, acknowledged or claimed
//   P7  [1-3, K-24/K-25] entry S's enable, attribute and level bits change only by a store
//       to offset 0x1000 + 4S with the matching byte enable, to the written value; a read of
//       entry S returns its WARL word; any other offset reads 0
//   P8  [1] bus: grant in the request cycle, rvalid exactly one cycle later, err never,
//       rdata 0 outside a read response
// The prove task (k-induction) adds I1: when P4's flag is set the pending bit of S is 0, and
// the unit's previous sample of input S equals the harness's own (the edges of P5 use the latter).
// Tasks: bmc (depth 10), prove (k-induction), cover.

`timescale 1ns/1ps

module px_clic_fv (
  input logic        clk_i,
  input logic [63:0] irq_i,
  input logic        req_i,
  input logic [15:0] addr_i,
  input logic        we_i,
  input logic [3:0]  be_i,
  input logic [31:0] wdata_i,
  input logic [7:0]  mil_i,
  input logic [7:0]  mintthresh_i,
  input logic        clic_mode_i,
  input logic        ack_i,
  input logic [5:0]  ack_id_i,
  input logic        claim_i,
  input logic [5:0]  claim_id_i
);

  localparam int N = 64;

  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = !init;

  logic        gnt, rvalid, err, irq_req, irq_valid, irq_shv;
  logic [31:0] rdata;
  logic [5:0]  irq_id;
  logic [7:0]  irq_level;

  px_clic #(.NUM_IRQ(64), .LVL_BITS(4)) dut (
    .clk_i, .rst_ni, .irq_i,
    .req_i, .gnt_o(gnt), .addr_i, .we_i, .be_i, .wdata_i,
    .rvalid_o(rvalid), .rdata_o(rdata), .err_o(err),
    .mil_i, .mintthresh_i, .clic_mode_i,
    .ack_i, .ack_id_i, .claim_i, .claim_id_i,
    .irq_req_o(irq_req), .irq_valid_o(irq_valid), .irq_id_o(irq_id),
    .irq_level_o(irq_level), .irq_shv_o(irq_shv)
  );

  // symbolic ids
  logic [5:0] S, J;
  always_ff @(posedge clk_i) begin
    S <= S;
    J <= J;
  end

  // ------------------------------------------------------------------ views of the unit's state
  logic [N-1:0] cand;
  assign cand = dut.pend_q & dut.ie_q;

  function automatic logic [3:0] lvl_of(input logic [N*4-1:0] v, input logic [5:0] i);
    lvl_of = v[i*4 +: 4];
  endfunction

  // linear-scan maximum of {level, id} over the candidates (ties: the later, higher id)
  logic       m_found;
  logic [5:0] m_id;
  always_comb begin
    m_found = 1'b0;
    m_id    = 6'd0;
    for (int i = 0; i < N; i++)
      if (cand[i] && (!m_found || lvl_of(dut.lvl_q, 6'(i)) >= lvl_of(dut.lvl_q, m_id))) begin
        m_found = 1'b1;
        m_id    = 6'(i);
      end
  end

  // offset decode written here (entries at 0x1000-0x10FF)
  logic       a_entry;
  logic [5:0] a_idx;
  assign a_entry = (addr_i >= 16'h1000) && (addr_i < 16'h1100);
  assign a_idx   = addr_i[7:2];

  // events for S in this cycle
  logic s_edge_mode, s_neg, s_edge_ev, s_sw, s_clr, s_set;
  assign s_edge_mode = dut.edge_q[S];
  assign s_neg       = dut.neg_q[S];
  // the harness keeps its own sample of the raw input (reset 0, like the unit's), so the
  // edge is defined independently of the unit's previous-sample flop
  logic h_prev;
  always_ff @(posedge clk_i) h_prev <= rst_ni ? irq_i[S] : 1'b0;
  assign s_edge_ev   = s_neg ? (!irq_i[S] && h_prev) : (irq_i[S] && !h_prev);
  assign s_sw        = req_i && we_i && a_entry && a_idx == S && be_i[0];
  assign s_clr       = (ack_i && ack_id_i == S && irq_shv) || (claim_i && claim_id_i == S);
  assign s_set       = s_edge_ev || (s_sw && wdata_i[0]);

  logic [31:0] s_word;
  assign s_word = {lvl_of(dut.lvl_q, S), 4'hF, 2'b11, 3'b000, dut.neg_q[S], dut.edge_q[S], dut.shv_q[S],
                   7'd0, dut.ie_q[S], 7'd0, dut.pend_q[S]};

  // ------------------------------------------------------------------ previous cycle
  logic        p_valid;
  logic        p_found, p_inv;
  logic [5:0]  p_mid;
  logic [3:0]  p_mlvl;
  logic        p_mshv;
  logic        p_ack, p_claim;
  logic [5:0]  p_ack_id, p_claim_id;
  logic        p_req, p_we, p_entry;
  logic [5:0]  p_idx;
  logic [3:0]  p_be;
  logic [31:0] p_wdata, p_s_word;
  logic        p_s_edge_mode, p_s_neg, p_s_edge_ev, p_s_sw, p_s_clr, p_s_pend, p_s_irq;
  logic        p_s_ie, p_s_shv, p_s_edge, p_s_negq;
  logic [3:0]  p_s_lvl;
  // P4 flag: S cleared by service and not set since
  logic        f_cleared;

  always_ff @(posedge clk_i) begin
    p_valid       <= rst_ni;
    p_found       <= m_found;
    p_inv         <= (ack_i && ack_id_i == m_id) || (claim_i && claim_id_i == m_id);
    p_mid         <= m_id;
    p_mlvl        <= lvl_of(dut.lvl_q, m_id);
    p_mshv        <= dut.shv_q[m_id];
    p_ack         <= ack_i;
    p_ack_id      <= ack_id_i;
    p_claim       <= claim_i;
    p_claim_id    <= claim_id_i;
    p_req         <= req_i;
    p_we          <= we_i;
    p_entry       <= a_entry;
    p_idx         <= a_idx;
    p_be          <= be_i;
    p_wdata       <= wdata_i;
    p_s_word      <= s_word;
    p_s_edge_mode <= s_edge_mode;
    p_s_neg       <= s_neg;
    p_s_edge_ev   <= s_edge_ev;
    p_s_sw        <= s_sw;
    p_s_clr       <= s_clr;
    p_s_pend      <= dut.pend_q[S];
    p_s_irq       <= irq_i[S];
    p_s_ie        <= dut.ie_q[S];
    p_s_shv       <= dut.shv_q[S];
    p_s_edge      <= dut.edge_q[S];
    p_s_negq      <= dut.neg_q[S];
    p_s_lvl       <= lvl_of(dut.lvl_q, S);
    if (!rst_ni)                                  f_cleared <= 1'b0;
    else if (!s_edge_mode || s_set)               f_cleared <= 1'b0;
    else if (s_clr)                               f_cleared <= 1'b1;
  end

  // ------------------------------------------------------------------ properties
  always_comb begin
    if (rst_ni && p_valid) begin
      // P1
      assert (irq_valid == (p_found && !p_inv));
      if (irq_valid) assert (irq_id == p_mid && irq_level == {p_mlvl, 4'hF} && irq_shv == p_mshv);
      else           assert (irq_id == 6'd0 && irq_level == 8'h0F && !irq_shv);
      // P3
      if (p_ack)   assert (!(irq_valid && irq_id == p_ack_id));
      if (p_claim) assert (!(irq_valid && irq_id == p_claim_id));
      // P4
      if (f_cleared) assert (!(irq_valid && irq_id == S));
      // P5
      if (p_s_edge_mode) begin
        if (p_s_edge_ev)      assert (dut.pend_q[S]);
        else if (p_s_sw)      assert (dut.pend_q[S] == p_wdata[0]);
        else if (p_s_clr)     assert (!dut.pend_q[S]);
        else                  assert (dut.pend_q[S] == p_s_pend);
      end
      // P6
      if (!p_s_edge_mode) assert (dut.pend_q[S] == (p_s_irq ^ p_s_neg));
      // P7: configuration of entry S
      if (p_req && p_we && p_entry && p_idx == S) begin
        assert (dut.ie_q[S] == (p_be[1] ? p_wdata[8] : p_s_ie));
        assert (dut.shv_q[S] == (p_be[2] ? p_wdata[16] : p_s_shv));
        assert (dut.edge_q[S] == (p_be[2] ? p_wdata[17] : p_s_edge));
        assert (dut.neg_q[S] == (p_be[2] ? p_wdata[18] : p_s_negq));
        assert (lvl_of(dut.lvl_q, S) == (p_be[3] ? p_wdata[31:28] : p_s_lvl));
      end else begin
        assert (dut.ie_q[S] == p_s_ie && dut.shv_q[S] == p_s_shv && dut.edge_q[S] == p_s_edge &&
                dut.neg_q[S] == p_s_negq && lvl_of(dut.lvl_q, S) == p_s_lvl);
      end
      // P7: reads; P8
      assert (rvalid == p_req);
      if (p_req && !p_we && p_entry && p_idx == S) assert (rdata == p_s_word);
      if (!(p_req && !p_we && p_entry))            assert (rdata == 32'd0);
    end
    if (rst_ni) begin
      // P2
      assert (irq_req == (irq_valid && clic_mode_i && irq_level > mil_i && irq_level > mintthresh_i));
      // P8
      assert (gnt == req_i);
      assert (!err);
`ifdef INDUCTION
      // I1
      if (f_cleared) assert (!dut.pend_q[S]);
      assert (dut.prev_q[S] == h_prev);
      assert (dut.win_valid_q || (dut.win_id_q == 6'd0 && dut.win_lvl_q == 4'd0 && !dut.win_shv_q));
`endif
    end
  end

  // ------------------------------------------------------------------ covers
  logic [N-1:0] at_max;
  always_comb begin
    for (int i = 0; i < N; i++) at_max[i] = cand[i] && lvl_of(dut.lvl_q, 6'(i)) == lvl_of(dut.lvl_q, m_id);
  end
  logic p_tie, p_f_cleared;
  always_ff @(posedge clk_i) begin
    p_tie       <= m_found && (at_max & ~(N'(1) << m_id)) != '0;
    p_f_cleared <= f_cleared;
  end

  always_comb begin
    if (rst_ni && p_valid) begin
      cover (p_tie && irq_valid);                                  // tie resolved to the higher id
      cover (p_ack && irq_valid && irq_id != p_ack_id);            // another winner right after an ack
      cover (p_claim && irq_valid && irq_id != p_claim_id && irq_req);
      cover (p_found && p_inv && !irq_valid);                      // invalidation
      cover (p_s_edge_mode && p_s_edge_ev && p_s_clr);             // edge in the clear cycle
      cover (p_s_edge_mode && p_s_sw && p_wdata[0] && p_s_clr);    // software set with a clear
      cover (p_f_cleared && !f_cleared && cand[S]);                // cleared by service, then pending again
      cover (irq_req && irq_level == mil_i + 8'd1);                // threshold boundary
      cover (!p_s_edge_mode && p_s_neg && dut.pend_q[S] && !p_s_irq);
      cover (p_req && !p_we && p_entry && p_idx == S && rdata != 32'h0FC0_0000);
    end
  end

endmodule
