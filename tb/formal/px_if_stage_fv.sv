// px_if_stage_fv: formal harness for px_if_stage (SymbiYosys, tb/formal/px_if_stage.sby).
//
// Environment: arbitrary redirects (halfword-aligned targets), arbitrary ID backpressure,
// and an OBI slave with arbitrary grant delays and response latency that returns one
// in-order response per granted request, with arbitrary data and error bits while
// rvalid is low. Memory contents are symbolic: two consecutive words at an arbitrary
// address A (constant data DA/DB and error bits EA/EB) are tracked; every other word
// returns fresh arbitrary data. Because A is arbitrary, the data properties below cover
// every address.
//
// Properties
//   P1  a request that is not granted is held with the same address (OBI)
//   P2  at most one request outstanding: a grant only with nothing outstanding or the
//       outstanding response arriving in the same cycle (contract § 3.2)
//   P3  no request in the reset cycle
//   P4  word-aligned request addresses
//   P5  an instruction delivered at a PC inside A..A+7 carries exactly the memory bits
//       of that PC (both halves of a straddling instruction) and the right fault flags
//       (fetch_err_o; fetch_err_hi_o only for a fault on the second word alone)
//   P6  the delivered PC follows the program order: the redirect target after a
//       redirect, then PC + 2 or + 4 by the delivered length
//   P7  internal bookkeeping: outstanding count equals the slave's, discards never
//       exceed it, the buffer never overflows
//   P8  no word is available while an old-stream request is still held
// Vector table fetch (step 2.2d, DECISIONS.md D-035 items 16-19): a redirect may carry vec_i
// (word-aligned target: the table entry). The expected PC after it is the table word with
// bit 0 cleared, known when the entry is the tracked word A (A is arbitrary, so this covers
// every entry address); after an entry at another address the PC check pauses until the
// next redirect, as after a fault.
//   V1  nothing is delivered while the table word is awaited or in the self-redirect cycle;
//       vec_busy_o outside IDLE, vec_fault_o only on a delivered fetch fault
//   V2  the first request of a vector redirect's stream is the table entry; after it is
//       granted no request until its response; no request while a table fault is pending
//   V3  a table entry at A without error leads to the handler at {DA[31:1], 0} (P5/P6 then
//       check its bits and the following PCs); with error, the entry is delivered once as
//       a fetch fault at pc = A with vec_fault_o, and nothing after it until a redirect
// After a delivered fetch fault the stage is not checked until the next redirect: the
// core always redirects after one (the faulting instruction traps, or an older
// instruction flushes it), and the stage is not required to continue past it.

`timescale 1ns/1ps

module px_if_stage_fv (
  input logic        clk_i,
  input logic        redirect_i,
  input logic        vec_i,
  input logic [31:0] redirect_pc_i,
  input logic        ready_i,
  input logic        instr_gnt_i,
  input logic        rvalid_choice,
  input logic [31:0] noise_data,
  input logic        noise_err,
  input logic [31:0] other_data,
  input logic        other_err
);

  // Symbolic constants: registers without reset that hold their arbitrary initial value
  // (the slang front end does not honour the anyconst attribute).
  logic [31:0] A, DA, DB;
  logic        EA, EB;
  always_ff @(posedge clk_i) begin
    A <= A; DA <= DA; DB <= DB; EA <= EA; EB <= EB;
  end

  // reset in the first cycle only
  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = !init;

  // ------------------------------------------------------------------ slave model
  logic        req, instr_rvalid, instr_err;
  logic [31:0] addr, instr_rdata;
  logic [1:0]  q_n;                 // outstanding requests (0..2; 2 would violate P2)
  logic [31:0] q_addr0, q_addr1;    // in order: 0 is the oldest

  assign instr_rvalid = rst_ni && (q_n != 2'd0) && rvalid_choice;

  logic [29:0] a_word;
  assign a_word = A[31:2];

  always_comb begin
    if (instr_rvalid && q_addr0[31:2] == a_word) begin
      instr_rdata = DA; instr_err = EA;
    end else if (instr_rvalid && q_addr0[31:2] == a_word + 30'd1) begin
      instr_rdata = DB; instr_err = EB;
    end else if (instr_rvalid) begin
      instr_rdata = other_data; instr_err = other_err;
    end else begin
      instr_rdata = noise_data; instr_err = noise_err;
    end
  end

  logic granted;
  assign granted = req && instr_gnt_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      q_n <= 2'd0;
    end else begin
      case ({granted, instr_rvalid})
        2'b10: begin
          if (q_n == 2'd0) q_addr0 <= addr; else q_addr1 <= addr;
          q_n <= q_n + 2'd1;
        end
        2'b01: begin
          q_addr0 <= q_addr1;
          q_n <= q_n - 2'd1;
        end
        2'b11: begin
          if (q_n == 2'd1) q_addr0 <= addr;
          else begin q_addr0 <= q_addr1; q_addr1 <= addr; end
        end
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------------ DUT
  logic        valid_o, is_c, ill_c, ferr, ferr_hi;
  logic        vec_busy, vec_fault;
  logic [31:0] pc_o, instr_o, raw_o;

  px_if_stage dut (
    .clk_i, .rst_ni,
    .redirect_i, .redirect_pc_i,
    .vec_i, .vec_busy_o(vec_busy), .vec_fault_o(vec_fault),
    .valid_o, .ready_i, .pc_o, .instr_o, .raw_o,
    .is_compressed_o(is_c), .illegal_c_o(ill_c),
    .fetch_err_o(ferr), .fetch_err_hi_o(ferr_hi),
    .instr_req_o(req), .instr_gnt_i, .instr_addr_o(addr),
    .instr_rvalid_i(instr_rvalid), .instr_rdata_i(instr_rdata), .instr_err_i(instr_err)
  );

  always_comb assume (redirect_pc_i[0] == 1'b0);
  // a vector redirect names a table entry (word address); vec_i only with a redirect
  always_comb if (vec_i) assume (redirect_i && redirect_pc_i[1:0] == 2'b00);

  // ------------------------------------------------------------------ properties
  logic        past_valid = 1'b0;
  logic        req_q, gnt_q;
  logic [31:0] addr_q;
  always_ff @(posedge clk_i) begin
    past_valid <= 1'b1;
    req_q  <= req;
    gnt_q  <= instr_gnt_i;
    addr_q <= addr;
  end

  // P1
  always_comb if (past_valid && rst_ni && req_q && !gnt_q) begin
    assert (req);
    assert (addr == addr_q);
  end
  // P2
  always_comb if (rst_ni && granted) assert (q_n == 2'd0 || (q_n == 2'd1 && instr_rvalid));
  // P3
  always_comb if (!rst_ni) assert (!req);
  // P4
  always_comb if (req) assert (addr[1:0] == 2'b00);

  // P6: expected PC
  logic [31:0] exp_pc;
  logic        poisoned;
  logic        fire;
  assign fire = valid_o && ready_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      exp_pc   <= 32'h1000_0000;
      poisoned <= 1'b0;
    end else if (redirect_i && vec_i) begin
      // V3: entry at A: handler address, or the faulting entry itself; elsewhere unchecked
      exp_pc   <= EA ? A & 32'hFFFF_FFFC : {DA[31:1], 1'b0};
      poisoned <= redirect_pc_i[31:2] != a_word;
    end else if (redirect_i) begin
      exp_pc   <= redirect_pc_i;
      poisoned <= 1'b0;
    end else if (fire) begin
      exp_pc   <= exp_pc + (is_c ? 32'd2 : 32'd4);
      if (ferr) poisoned <= 1'b1;
    end
  end

  always_comb if (rst_ni && valid_o && !poisoned) assert (pc_o == exp_pc);
  // nothing is delivered in a redirect cycle
  always_comb if (redirect_i) assert (!valid_o);

  // ------------------------------------------------------------------ V1-V3
  logic        vtab_open;          // a vector redirect's table request not yet granted
  logic [31:0] vtab_q;             // its table entry address
  logic        vtab_err;           // the current vector redirect's entry is A with EA
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      vtab_open <= 1'b0; vtab_err <= 1'b0;
    end else if (redirect_i) begin
      vtab_open <= vec_i && !(granted && !dut.stale_grant);
      vtab_q    <= redirect_pc_i;
      vtab_err  <= vec_i && redirect_pc_i[31:2] == a_word && EA;
    end else if (granted && !dut.stale_grant) begin
      vtab_open <= 1'b0;
    end
  end

  // V1
  always_comb if (rst_ni && (dut.vstate_q == 2'd1 || dut.vstate_q == 2'd2)) assert (!valid_o);
  always_comb if (rst_ni) assert (vec_busy == (dut.vstate_q != 2'd0));
  always_comb if (rst_ni && vec_fault && valid_o) assert (ferr);
  always_comb if (rst_ni && valid_o && !poisoned && vtab_err) assert (vec_fault && pc_o == (A & 32'hFFFF_FFFC));
  always_comb if (rst_ni && valid_o && !vec_fault) assert (!vtab_err || poisoned);
  // V2
  always_comb if (rst_ni && redirect_i && vec_i && req && !dut.pend_q) assert (addr == redirect_pc_i);
  always_comb if (rst_ni && !redirect_i && vtab_open && req && !(dut.pend_q && dut.pend_stale_q))
    assert (addr == vtab_q);
  always_comb if (rst_ni && !redirect_i && dut.vstate_q == 2'd1 && dut.vreq_q) assert (!req);
  always_comb if (rst_ni && !redirect_i && dut.vstate_q == 2'd3) assert (!req);
  always_comb if (rst_ni && dut.vstate_q == 2'd1 && !dut.vreq_q) assert (vtab_open);

  // P5: contents
  logic [31:0] pc_word_a;
  logic        at_a_lo, at_a_hi;
  assign at_a_lo = (pc_o[31:2] == a_word) && !pc_o[1];
  assign at_a_hi = (pc_o[31:2] == a_word) &&  pc_o[1];

  always_comb begin
    if (rst_ni && valid_o && !poisoned && at_a_lo) begin
      assert (ferr == EA);
      assert (!ferr_hi);
      if (!EA) begin
        if (DA[1:0] == 2'b11) begin
          assert (!is_c);
          assert (raw_o == DA);
        end else begin
          assert (is_c);
          assert (raw_o == {16'd0, DA[15:0]});
        end
      end
    end
    if (rst_ni && valid_o && !poisoned && at_a_hi) begin
      if (EA) begin
        assert (ferr && !ferr_hi);
      end else if (DA[17:16] == 2'b11) begin
        // 32-bit instruction straddling into A+4
        assert (ferr == EB);
        assert (ferr_hi == EB);
        if (!EB) assert (raw_o == {DB[15:0], DA[31:16]} && !is_c);
      end else begin
        assert (!ferr && !ferr_hi);
        assert (is_c);
        assert (raw_o == {16'd0, DA[31:16]});
      end
    end
  end

  // P7: bookkeeping (white box)
  always_comb if (rst_ni) begin
    assert (dut.outst_q == q_n);
    assert (dut.discard_q <= dut.outst_q);
    assert (dut.count_q <= 2'd3);
    assert ({1'b0, dut.count_q} + {1'b0, dut.outst_q} - {1'b0, dut.discard_q} <= 3'd3);
  end

  // P8: while an old-stream request is still held no word is available (this is why the
  // pend_stale_q term in valid_o is redundant; mutant F11 is declared equivalent on it)
  always_comb if (rst_ni && dut.pend_stale_q) assert (dut.avail == 3'd0);

  // Reachability: a straddling instruction at A+2 is delivered without faults.
  always_comb cover (rst_ni && valid_o && !poisoned && at_a_hi && !EA && !EB && DA[17:16] == 2'b11);
  // ... and one right after a redirect that discarded an outstanding response
  logic disc_seen;
  always_ff @(posedge clk_i) if (!rst_ni) disc_seen <= 1'b0; else if (dut.discard_q != 2'd0) disc_seen <= 1'b1;
  always_comb cover (rst_ni && valid_o && !poisoned && at_a_hi && !EB && DA[17:16] == 2'b11 && disc_seen);
  // ... a vectored handler reached through the table word at A, at a halfword offset
  logic vec_seen;
  always_ff @(posedge clk_i)
    if (!rst_ni) vec_seen <= 1'b0;
    else if (redirect_i) vec_seen <= vec_i && redirect_pc_i[31:2] == a_word;
  always_comb cover (rst_ni && valid_o && !poisoned && vec_seen && !EA && DA[1] && !vec_fault);
  // ... and a table fault delivered
  always_comb cover (rst_ni && valid_o && vec_fault && vec_seen);

endmodule
