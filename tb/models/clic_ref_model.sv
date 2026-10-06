// clic_ref_model: behavioural cycle model of the PX32 CLIC unit, the reference for
// tb_px_clic (PHASE2_VERIFICATION.md § 3.1).
//
// Written from the pinned CLIC draft 0.9 (clic.adoc at 514ddb112c8f9418ca6850d90292d4c1f9807049),
// PHASE2_CLIC_MATRIX.md and the platform choices of DECISIONS.md D-034, without reference
// to the RTL. It deliberately uses a different structure from any hardware arbiter: state
// in plain arrays, the winner found by a linear scan, every rule written as the draft or
// D-034 states it. Not synthesizable in the product sense; used only in simulation.
//
// Rules modelled (draft section / matrix row / D-034 item):
//   Memory map ("CLIC Memory Map", K-24/K-25, item 1): the word at offset 0x1000 + 4i
//     (i < NUM) holds clicintip (byte 0), clicintie (1), clicintattr (2), clicintctl (3);
//     every other offset of the 64 KiB window reads 0 and ignores writes; err is never set.
//   Bus (contract § 3.2, item 1): grant in the request cycle, one response (rvalid) exactly
//     one cycle later for reads and writes; rdata is the read value in a read response and
//     0 otherwise.
//   WARL (K-20..K-23, item 3): ip, ie bit 0 only; attr mode reads 11, bits 5:3 read 0,
//     trig (2:1) and shv (0) writable; ctl bits 7:4 writable, 3:0 read 1111.
//   Pending ("CLIC Interrupt Pending", items 6-9): level mode (attr bit 1 = 0): pending =
//     input XOR attr bit 2, writes ignored. Edge mode: an edge of the selected polarity
//     (attr bit 2: 0 rising, 1 falling) between the previous and the current sample sets
//     it; otherwise a software write sets it to wdata[0]; otherwise an ack of this id while
//     the presented winner is vectored, or a claim of this id, clears it.
//   Selection (K-50, item 10): the maximum of {level, id} over pending-and-enabled inputs,
//     ties to the highest id; registered; invalid in the next cycle when it is the id
//     acknowledged or claimed in this cycle (item 14).
//   Request (K-51, item 13): registered winner valid, CLIC mode, and its level (ctl level
//     bits followed by ones) strictly greater than mil and than mintthresh, from the
//     current values of those inputs.

`timescale 1ns/1ps

module clic_ref_model #(
  parameter int NUM = 64,
  parameter int LB  = 4     // implemented level bits of clicintctl
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [NUM-1:0] irq,
  input  logic        req,
  input  logic [15:0] addr,
  input  logic        we,
  input  logic [3:0]  be,
  input  logic [31:0] wdata,
  output logic        gnt,
  output logic        rvalid,
  output logic [31:0] rdata,
  output logic        err,
  input  logic [7:0]  mil,
  input  logic [7:0]  th,
  input  logic        clic_mode,
  input  logic        ack,
  input  logic [5:0]  ack_id,
  input  logic        claim,
  input  logic [5:0]  claim_id,
  output logic        req_out,
  output logic        valid_out,
  output logic [5:0]  id_out,
  output logic [7:0]  level_out,
  output logic        shv_out
);

  // architectural state, one bit per input (bit i = input i)
  logic [NUM-1:0] ip, ie, shv;
  logic [NUM-1:0] tedge;           // clicintattr bit 1: edge-triggered
  logic [NUM-1:0] tneg;            // clicintattr bit 2: negative polarity
  logic [NUM-1:0] prev;            // previous sample of the raw input
  logic [7:0]     ctl [0:NUM-1];   // full 8-bit read value of clicintctl
  logic [NUM-1:0] lvb [0:7];       // lvb[k][i] = ctl[i][k] (for the bench's coverage monitor)
  // presented winner
  logic       w_valid;
  logic [5:0] w_id;
  logic [7:0] w_level;
  logic       w_shv;

  function automatic logic [7:0] ctl_legal(input logic [7:0] v);
    logic [7:0] ones;
    ones = 8'hFF >> LB;          // the 8 - LB unimplemented low bits read 1
    return (v & ~ones) | ones;
  endfunction

  assign gnt = req;
  assign err = 1'b0;
  assign valid_out = w_valid;
  assign id_out    = w_id;
  assign level_out = w_level;
  assign shv_out   = w_shv;
  assign req_out   = w_valid && clic_mode && (w_level > mil) && (w_level > th);

  always @(posedge clk or negedge rst_n) begin : step
    int         idx;
    logic       hit;
    logic       edge_seen, sw_wr, clr;
    logic       found;
    int         best;
    logic [NUM-1:0] n_ip;
    logic [7:0] nctl;
    if (!rst_n) begin
      ip <= '0; ie <= '0; tedge <= '0; tneg <= '0; shv <= '0; prev <= '0;
      for (int i = 0; i < NUM; i++) ctl[i] <= ctl_legal(8'h00);
      for (int k = 0; k < 8; k++) lvb[k] <= (((ctl_legal(8'h00) >> k) & 8'h01) != 8'h00) ? '1 : '0;
      w_valid <= 1'b0; w_id <= '0; w_level <= ctl_legal(8'h00); w_shv <= 1'b0;
      rvalid <= 1'b0; rdata <= '0;
    end else begin
      // ---- bus access
      hit = req && (addr[15:12] == 4'h1) && (int'(addr[11:2]) < NUM);
      idx = int'(addr[11:2]);
      rvalid <= req;
      if (hit && !we)
        rdata <= {ctl[idx], 2'b11, 3'b000, tneg[idx], tedge[idx], shv[idx], 7'd0, ie[idx], 7'd0, ip[idx]};
      else
        rdata <= 32'd0;
      if (hit && we) begin
        if (be[1]) ie[idx] <= wdata[8];
        if (be[2]) begin tneg[idx] <= wdata[18]; tedge[idx] <= wdata[17]; shv[idx] <= wdata[16]; end
        if (be[3]) begin
          nctl = ctl_legal(wdata[31:24]);
          ctl[idx] <= nctl;
          for (int k = 0; k < 8; k++) lvb[k][idx] <= nctl[k];
        end
      end
      // ---- pending bits (mode and polarity as stored before this cycle's store)
      // level mode: the input after polarity, whatever is written, acknowledged or claimed
      n_ip = irq ^ tneg;
      // edge mode: the D-034 item 8 order, input by input
      for (int i = 0; i < NUM; i++) begin
        if (tedge[i]) begin
          edge_seen = tneg[i] ? (!irq[i] && prev[i]) : (irq[i] && !prev[i]);
          sw_wr     = hit && we && be[0] && (idx == i);
          clr       = (ack && (int'(ack_id) == i) && w_shv) || (claim && (int'(claim_id) == i));
          if (edge_seen)  n_ip[i] = 1'b1;
          else if (sw_wr) n_ip[i] = wdata[0];
          else if (clr)   n_ip[i] = 1'b0;
          else            n_ip[i] = ip[i];
        end
      end
      ip   <= n_ip;
      prev <= irq;
      // ---- selection over the state of this cycle
      found = 1'b0;
      best  = 0;
      for (int i = 0; i < NUM; i++)
        if (ip[i] && ie[i] && (!found || ctl[i] >= ctl[best])) begin
          found = 1'b1;
          best  = i;
        end
      if (found && (ack && int'(ack_id) == best)) found = 1'b0;
      if (found && (claim && int'(claim_id) == best)) found = 1'b0;
      w_valid <= found;
      w_id    <= found ? best[5:0] : 6'd0;
      w_level <= found ? ctl[best] : ctl_legal(8'h00);   // D-034 item 12: level bits 0, ones appended
      w_shv   <= found ? shv[best] : 1'b0;
    end
  end

endmodule
