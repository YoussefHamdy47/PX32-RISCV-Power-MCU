// px_clic: core-local interrupt controller, M-mode CLIC unit (Phase 2 step 2.2c).
//
// Implements the PX32 profile of the pinned CLIC draft 0.9 (clic.adoc at
// 514ddb112c8f9418ca6850d90292d4c1f9807049; IMPLEMENTATION_CONTRACTS.md § 1): smclic with
// smclicshv, 64 inputs, 4 level bits and no priority bits (D-027, PHASE2_CLIC_MATRIX.md),
// PHASE2_ARCHITECTURE.md §§ 4.2-4.3 and 9.3. Platform choices and the deviations from
// § 4.3 (current-state qualification, selective invalidation, no mie_i/priv_i, the new
// irq_valid_o) are recorded in DECISIONS.md D-034; its item numbers are cited below.
//
// Matrix rows implemented here: K-20 (clicintip), K-21 (clicintie), K-22 (clicintattr),
// K-23 (clicintctl), K-24 (inputs 64-4095 read 0), K-25 (reserved space), K-26 (access
// sizes), K-27 (evaluation timing), K-28 (input sampling), K-50 (selection), K-51
// (threshold), K-60 (no disabled level), K-71 (edge clear on vectored entry, the ack) and
// the claim side of K-35. Not implemented: K-03 smclicconfig (offset 0x0000 reads 0),
// K-04 ssclic/suclic, K-13 clicinttrig (0x0040-0x00BC read 0), K-16 VERSION.
//
// Parameters: NUM_IRQ inputs (a power of two, 2 to 1024; ids are $clog2(NUM_IRQ) bits) and
// LVL_BITS implemented level bits of clicintctl (1 to 8). Only the contract configuration,
// NUM_IRQ = 64 and LVL_BITS = 4, is verified (tb_px_clic, tb/formal/px_clic.sby).
//
// Memory-mapped port (D-034 items 1-5): one-cycle OBI slave. gnt_o = req_i; rvalid_o one
// cycle after every granted request; rdata_o is registered (read value in a read response,
// 0 otherwise); err_o is always 0. addr_i is the offset in the unit's 64 KiB window; all of
// bits 15:2 are decoded and bits 1:0 are not used (word address, byte enables):
//   0x1000 + 4i (i < NUM_IRQ)  byte 0 clicintip[i]   bit 0 pending; 7:1 read 0
//                              byte 1 clicintie[i]   bit 0 enable; 7:1 read 0
//                              byte 2 clicintattr[i] 7:6 mode reads 11; 5:3 read 0;
//                                                    2 negative polarity, 1 edge, 0 shv
//                              byte 3 clicintctl[i]  7:4 level bits; 3:0 read 1111
//   every other offset         reads 0, writes ignored, OKAY
// Reset: pending, enable, attr (reads 0xC0: positive level, non-vectored) and the level
// bits (ctl reads 0x0F, level 15) are 0.
//
// Pending (D-034 items 6-9), per input, next value at each edge:
//   level mode (attr bit 1 = 0): irq_i ^ attr bit 2; writes, ack and claim ignored (K-20)
//   edge mode:  an edge of the selected polarity between prev_q (last cycle's raw sample)
//               and irq_i -> 1; else a write of byte 0 -> wdata[0]; else a clear (ack of
//               this id with the presented winner vectored, or claim of this id) -> 0;
//               else unchanged. An edge is never lost to a same-cycle clear or write.
//   The mode in force is the stored attr value; a store takes effect from the next cycle.
//
// Arbitration (K-50, D-034 items 10-12): candidates pending & enable; a binary tree picks
// the maximum of {level, id} (ties to the higher id) and the result is registered: the
// winner register (irq_valid_o, irq_id_o, irq_level_o = {level bits, ones}, irq_shv_o)
// is meaningful whether or not a request is presented (mnxti uses it in step 2.2d).
//
// Request (K-51, D-034 item 13): irq_req_o = winner valid && clic_mode_i && level > mil_i
// && level > mintthresh_i, combinational from the winner register and the core's current
// state (core flops), so a threshold raise, a level raise or a return to CLINT mode acts
// in the same cycle. MIE is checked by the core (D-033 item 2).
//
// Latency (PHASE2_ARCHITECTURE.md § 4.9): input change before edge 0 -> pending flop at
// edge 0 -> winner register and irq_req_o at edge 1.
//
// ack/claim invalidation (D-034 item 14): the winner registered at edge T+1 is invalid when
// it is the id acknowledged or claimed in cycle T; any other winner stays.
//
//   cycle        T-1       T              T+1                         T+2
//   pend[C]      1         1              0 (vectored ack / claim)    0
//   irq_id_o     ..        C              B (next maximum) or invalid  fresh
//   irq_req_o    ..        1 (C)          never for C                 fresh
//   ack_i        0         1, ack_id = C  0                           0
//
// A new edge of C in cycle T keeps pend[C] at 1 (the second event is not lost); C is still
// not presented at T+1, and is presented again from T+2.

`timescale 1ns/1ps

module px_clic #(
  parameter int NUM_IRQ  = 64,
  parameter int LVL_BITS = 4,
  localparam int IDW     = $clog2(NUM_IRQ)
) (
  input  logic               clk_i,
  input  logic               rst_ni,

  // interrupt inputs: synchronous on-chip signals (K-28)
  input  logic [NUM_IRQ-1:0] irq_i,

  // memory-mapped slave port (OBI subset, one-cycle response)
  input  logic               req_i,
  output logic               gnt_o,
  input  logic [15:0]        addr_i,
  input  logic               we_i,
  input  logic [3:0]         be_i,
  input  logic [31:0]        wdata_i,
  output logic               rvalid_o,
  output logic [31:0]        rdata_o,
  output logic               err_o,

  // core state (core flops)
  input  logic [7:0]         mil_i,
  input  logic [7:0]         mintthresh_i,
  input  logic               clic_mode_i,

  // take and mnxti claim from the core
  input  logic               ack_i,
  input  logic [IDW-1:0]     ack_id_i,
  input  logic               claim_i,
  input  logic [IDW-1:0]     claim_id_i,

  // registered winner and the qualified request
  output logic               irq_req_o,
  output logic               irq_valid_o,
  output logic [IDW-1:0]     irq_id_o,
  output logic [7:0]         irq_level_o,
  output logic               irq_shv_o
);

  localparam int          LB   = LVL_BITS;
  localparam logic [7:0]  ONES = 8'hFF >> LB;   // unimplemented low ctl bits read 1 (K-23)
  localparam int          NN   = 2 * NUM_IRQ;   // tree nodes 1 .. NN-1; leaves NUM_IRQ .. NN-1

  // ------------------------------------------------------------------ state
  logic [NUM_IRQ-1:0]    pend_q, ie_q, edge_q, neg_q, shv_q, prev_q;
  logic [NUM_IRQ*LB-1:0] lvl_q;
  logic                  win_valid_q, win_shv_q;
  logic [IDW-1:0]        win_id_q;
  logic [LB-1:0]         win_lvl_q;
  logic                  rvalid_q;
  logic [31:0]           rdata_q;

  // ------------------------------------------------------------------ bus decode (D-034 item 1)
  logic           idx_ok, hit;
  logic [IDW-1:0] idx;

  assign idx = addr_i[IDW+1:2];
  if (IDW < 10) begin : g_idx_hi
    assign idx_ok = (addr_i[11:IDW+2] == '0);
  end else begin : g_idx_full
    assign idx_ok = 1'b1;
  end
  assign hit = req_i && (addr_i[15:12] == 4'h1) && idx_ok;   // K-24, K-25: anything else reads 0

  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]  addr_lo_unused;
  logic [31:0] wdata_unused;
  assign addr_lo_unused = addr_i[1:0];   // word address; lanes come from be_i
  assign wdata_unused   = wdata_i;       // WARL: bits outside ip[0], ie[0], attr[2:0], ctl level are ignored
  /* verilator lint_on UNUSEDSIGNAL */

  assign gnt_o = req_i;
  assign err_o = 1'b0;

  // read value of the addressed entry (K-20..K-23 WARL read-back)
  logic [LB-1:0] rd_lvl;
  logic [7:0]    rd_ctl;
  logic [31:0]   rd_word;
  assign rd_lvl  = lvl_q[idx*LB +: LB];
  assign rd_ctl  = (8'(rd_lvl) << (8 - LB)) | ONES;
  assign rd_word = {rd_ctl, 2'b11, 3'b000, neg_q[idx], edge_q[idx], shv_q[idx],
                    7'd0, ie_q[idx], 7'd0, pend_q[idx]};

  // ------------------------------------------------------------------ per-input next state
  // Whole-vector logic (one bit per input): the same gates as 64 per-input instances, but a
  // handful of vector assigns for the simulator (Icarus re-evaluates a per-bit generate or
  // loop on every change of any shared vector, which cost about 2 ms per cycle).
  logic [NUM_IRQ-1:0]    sel_v;             // one-hot entry select of a store
  logic [NUM_IRQ-1:0]    w_ip, w_ie, w_attr, ack_v, claim_v;
  logic [NUM_IRQ*LB-1:0] w_lvl_mask;
  assign sel_v   = (hit && we_i) ? (NUM_IRQ'(1) << idx) : '0;
  assign w_ip    = sel_v & {NUM_IRQ{be_i[0]}};
  assign w_ie    = sel_v & {NUM_IRQ{be_i[1]}};
  assign w_attr  = sel_v & {NUM_IRQ{be_i[2]}};
  assign ack_v   = NUM_IRQ'(1) << ack_id_i;
  assign claim_v = NUM_IRQ'(1) << claim_id_i;
  assign w_lvl_mask = (hit && we_i && be_i[3]) ? ((NUM_IRQ*LB)'({LB{1'b1}}) << (idx * LB)) : '0;

  logic [NUM_IRQ-1:0]    edge_ev, clr, pend_edge;
  logic [NUM_IRQ-1:0]    pend_d, ie_d, edge_d, neg_d, shv_d;
  logic [NUM_IRQ*LB-1:0] lvl_d;
  // K-28, D-034 item 7: raw previous sample; the polarity selects the edge direction
  assign edge_ev = (neg_q & ~irq_i & prev_q) | (~neg_q & irq_i & ~prev_q);
  // K-71: ack clears only after a vectored entry (the presented winner's shv, item 9);
  // K-35: a claim clears an edge pending bit
  assign clr     = (ack_v & {NUM_IRQ{ack_i && win_shv_q}}) | (claim_v & {NUM_IRQ{claim_i}});
  // K-20, item 8 priority in edge mode: edge > software write > clear > hold
  assign pend_edge = edge_ev | (w_ip & {NUM_IRQ{wdata_i[0]}}) | (~w_ip & ~clr & pend_q);
  // level mode follows the input after polarity; writes, ack and claim have no effect
  assign pend_d  = (edge_q & pend_edge) | (~edge_q & (irq_i ^ neg_q));
  assign ie_d    = (w_ie & {NUM_IRQ{wdata_i[8]}})    | (~w_ie & ie_q);       // K-21
  assign shv_d   = (w_attr & {NUM_IRQ{wdata_i[16]}}) | (~w_attr & shv_q);    // K-22
  assign edge_d  = (w_attr & {NUM_IRQ{wdata_i[17]}}) | (~w_attr & edge_q);
  assign neg_d   = (w_attr & {NUM_IRQ{wdata_i[18]}}) | (~w_attr & neg_q);
  assign lvl_d   = (w_lvl_mask & {NUM_IRQ{wdata_i[31 -: LB]}}) | (~w_lvl_mask & lvl_q);   // K-23

  // ------------------------------------------------------------------ arbitration tree (K-50)
  // Heap layout: node n has children 2n (lower ids) and 2n+1 (higher ids); the leaf of
  // input i is node NUM_IRQ + i; the root is node 1. A node takes its right child when
  // {valid, level} of the right child is greater or equal: ties go to the higher id.
  // Payload: shv, and whether the id equals ack_id_i / claim_id_i (item 14). One array
  // element per node, so the simulator re-evaluates a node only when its children change.
  logic           t_v  [1:NN-1];
  logic           t_sh [1:NN-1];
  logic           t_ka [1:NN-1];
  logic           t_kc [1:NN-1];
  logic [LB-1:0]  t_l  [1:NN-1];
  logic [IDW-1:0] t_id [1:NN-1];

  for (genvar i = 0; i < NUM_IRQ; i++) begin : g_leaf
    assign t_v[NUM_IRQ + i]  = pend_q[i] && ie_q[i];
    assign t_l[NUM_IRQ + i]  = lvl_q[i*LB +: LB];
    assign t_sh[NUM_IRQ + i] = shv_q[i];
    assign t_ka[NUM_IRQ + i] = ack_v[i];
    assign t_kc[NUM_IRQ + i] = claim_v[i];
    assign t_id[NUM_IRQ + i] = IDW'(i);
  end

  for (genvar n = 1; n < NUM_IRQ; n++) begin : g_node
    logic r;
    assign r       = {t_v[2*n+1], t_l[2*n+1]} >= {t_v[2*n], t_l[2*n]};
    assign t_v[n]  = r ? t_v[2*n+1]  : t_v[2*n];
    assign t_l[n]  = r ? t_l[2*n+1]  : t_l[2*n];
    assign t_sh[n] = r ? t_sh[2*n+1] : t_sh[2*n];
    assign t_ka[n] = r ? t_ka[2*n+1] : t_ka[2*n];
    assign t_kc[n] = r ? t_kc[2*n+1] : t_kc[2*n];
    assign t_id[n] = r ? t_id[2*n+1] : t_id[2*n];
  end

  logic           root_v, root_sh, root_ka, root_kc;
  logic [LB-1:0]  root_l;
  logic [IDW-1:0] root_id;
  assign root_v  = t_v[1];
  assign root_l  = t_l[1];
  assign root_sh = t_sh[1];
  assign root_ka = t_ka[1];
  assign root_kc = t_kc[1];
  assign root_id = t_id[1];

  // winner register input: invalid when it is the id acknowledged or claimed this cycle
  logic           win_valid_d;
  logic [IDW-1:0] win_id_d;
  logic [LB-1:0]  win_lvl_d;
  logic           win_shv_d;
  assign win_valid_d = root_v && !(ack_i && root_ka) && !(claim_i && root_kc);
  assign win_id_d    = win_valid_d ? root_id : '0;
  assign win_lvl_d   = win_valid_d ? root_l  : '0;
  assign win_shv_d   = win_valid_d && root_sh;

  // ------------------------------------------------------------------ flops
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_q      <= '0;
      ie_q        <= '0;
      edge_q      <= '0;
      neg_q       <= '0;
      shv_q       <= '0;
      lvl_q       <= '0;
      prev_q      <= '0;
      win_valid_q <= 1'b0;
      win_id_q    <= '0;
      win_lvl_q   <= '0;
      win_shv_q   <= 1'b0;
      rvalid_q    <= 1'b0;
      rdata_q     <= '0;
    end else begin
      pend_q      <= pend_d;
      ie_q        <= ie_d;
      edge_q      <= edge_d;
      neg_q       <= neg_d;
      shv_q       <= shv_d;
      lvl_q       <= lvl_d;
      prev_q      <= irq_i;
      win_valid_q <= win_valid_d;
      win_id_q    <= win_id_d;
      win_lvl_q   <= win_lvl_d;
      win_shv_q   <= win_shv_d;
      rvalid_q    <= req_i;
      rdata_q     <= (hit && !we_i) ? rd_word : 32'd0;
    end
  end

  // ------------------------------------------------------------------ outputs
  logic [7:0] win_level;
  assign win_level = (8'(win_lvl_q) << (8 - LB)) | ONES;

  assign rvalid_o    = rvalid_q;
  assign rdata_o     = rdata_q;
  assign irq_valid_o = win_valid_q;
  assign irq_id_o    = win_id_q;
  assign irq_level_o = win_level;
  assign irq_shv_o   = win_shv_q;
  // K-51, D-034 item 13: strictly above max(mil, mintthresh), current core state
  assign irq_req_o   = win_valid_q && clic_mode_i && (win_level > mil_i) && (win_level > mintthresh_i);

endmodule
