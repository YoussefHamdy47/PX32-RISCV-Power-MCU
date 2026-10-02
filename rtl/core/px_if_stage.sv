// px_if_stage: instruction fetch, prefetch buffer, alignment and RVC expansion.
//
// Implements the IF stage of ARCHITECTURE.md § 4.1 (IMPLEMENTATION_GUIDE.md step 1.5).
//
// Fetch protocol (OBI-style, guide § 5.1)
//   - Word-aligned requests from instr_addr_o. A request that is not granted is held
//     with the same address until it is (OBI rule), even across a redirect.
//   - At most 1 request outstanding (IMPLEMENTATION_CONTRACTS.md § 3.2); the next grant
//     may coincide with the response, which keeps single-cycle memories at one word
//     per cycle. D-021 records why the earlier two-request version was changed.
//   - No request while reset is asserted: the first request is raised in the cycle
//     after reset release.
//   - Up to 3 fetched words are buffered. A new request is issued only when the buffer
//     plus the outstanding request leave room for its response.
//
// Alignment
//   The instruction at pc_q may start in either half of a word. A 32-bit instruction in
//   the upper half needs the next word as well. The words used by the aligner are the
//   buffer entries followed by this cycle's response (bypass), so an instruction can
//   leave IF in the same cycle its word arrives.
//
// Redirect (branch, jump, trap, FENCE.I)
//   redirect_i clears the buffer and changes pc_q in the same cycle. The request in that
//   cycle already goes to the target (unless an older request is still waiting for its
//   grant). Responses to requests issued before the redirect are counted and dropped.
//   Nothing is delivered in a redirect cycle.
//
// Timing (1-cycle memory): target requested in cycle t, word returns and the instruction
// leaves IF in t+1, so it is in ID in t+2. A 32-bit instruction starting in the upper
// half of a word needs one more cycle after a redirect (its second half is fetched next).
//
// Output to ID: valid_o/ready_i handshake. instr_o is the expanded 32-bit instruction,
// raw_o the original bits (16-bit ones zero-extended, for mtval and the trace).
// fetch_err_o marks a fetch fault; fetch_err_hi_o additionally says that only the second
// word of a straddling 32-bit instruction faulted, so mtval is pc + 2 (the address of the
// faulting half, privileged spec § 3.1.16) instead of pc.

`timescale 1ns/1ps

module px_if_stage #(
  parameter logic [31:0] BOOT_ADDR = 32'h1000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        redirect_i,
  input  logic [31:0] redirect_pc_i,

  output logic        valid_o,
  input  logic        ready_i,
  output logic [31:0] pc_o,
  output logic [31:0] instr_o,
  output logic [31:0] raw_o,
  output logic        is_compressed_o,
  output logic        illegal_c_o,
  output logic        fetch_err_o,
  output logic        fetch_err_hi_o,

  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  output logic [31:0] instr_addr_o,
  input  logic        instr_rvalid_i,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i
);

  localparam int DEPTH   = 3;
  localparam int MAX_OUT = 1;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [31:0] pc_q, pc_d;
  // Next sequential word to request: seq_base_q + (seq_inc_q ? 4 : 0). Keeping the
  // increment as a flag moves the incrementer behind flops only, off the redirect path
  // (a redirect stores the target word directly).
  logic [31:0] seq_base_q, seq_base_d;
  logic        seq_inc_q, seq_inc_d;
  logic [31:0] seq_addr;
  logic [31:0] buf0_q, buf1_q, buf2_q;
  logic        err0_q, err1_q, err2_q;
  logic [1:0]  count_q, count_d;
  logic [1:0]  outst_q, outst_d;                 // granted, response not yet received
  logic [1:0]  discard_q, discard_d;             // of those, responses to drop
  logic        pend_q, pend_d;                   // request raised last cycle, not granted
  logic        pend_stale_q, pend_stale_d;       // ... and it belongs to the old stream
  logic [31:0] pend_addr_q, pend_addr_d;
  logic        run_q;                            // reset released (no request in reset)

  // ---------------------------------------------------------------------------
  // Word view: buffer entries followed by this cycle's (kept) response
  // ---------------------------------------------------------------------------
  logic        resp_keep;
  logic [2:0]  avail;
  logic [31:0] w0, w1, w2, w3;
  logic        e0, e1, e2, e3;

  assign resp_keep = instr_rvalid_i && (discard_q == 2'd0);
  assign avail     = {1'b0, count_q} + {2'b00, resp_keep};

  assign w0 = (count_q >= 2'd1) ? buf0_q : instr_rdata_i;
  assign w1 = (count_q >= 2'd2) ? buf1_q : instr_rdata_i;
  assign w2 = (count_q == 2'd3) ? buf2_q : instr_rdata_i;
  assign w3 = instr_rdata_i;
  assign e0 = (count_q >= 2'd1) ? err0_q : instr_err_i;
  assign e1 = (count_q >= 2'd2) ? err1_q : instr_err_i;
  assign e2 = (count_q == 2'd3) ? err2_q : instr_err_i;
  assign e3 = instr_err_i;

  // ---------------------------------------------------------------------------
  // Aligner
  // ---------------------------------------------------------------------------
  logic        half;                 // instruction starts in the upper half of w0
  logic [1:0]  w0_len;               // length bits of an instruction in the low half
  logic [15:0] w0_hi, w1_lo;
  logic        is32;
  logic [2:0]  need;                 // words needed to form the instruction
  logic [31:0] window;
  logic        aligned_valid;
  logic        aligned_err;
  logic        pop;                  // delivering it frees w0

  assign half  = pc_q[1];
  assign w0_len = w0[1:0];
  assign w0_hi = w0[31:16];
  assign w1_lo = w1[15:0];

  assign is32   = half ? (w0_hi[1:0] == 2'b11) : (w0_len == 2'b11);
  assign need   = (half && is32) ? 3'd2 : 3'd1;
  assign window = !half ? w0 : is32 ? {w1_lo, w0_hi} : {16'd0, w0_hi};
  // A faulting first word ends the instruction there (its length is unknown).
  assign aligned_err   = e0 || (need == 3'd2 && e1);
  // Qualified by avail first: with no word available, the fetch data (and so `need`)
  // is meaningless and must not reach the control path.
  assign aligned_valid = (avail == 3'd0) ? 1'b0 : ((avail >= need) || e0);
  assign pop           = half || is32 || e0;

  // RVC expansion
  logic [31:0] exp_instr;
  logic        exp_c, exp_ill;

  px_decompressor u_rvc (
    .instr_i        (window),
    .instr_o        (exp_instr),
    .is_compressed_o(exp_c),
    .illegal_o      (exp_ill)
  );

  logic fire;

  assign valid_o         = aligned_valid && !redirect_i && !pend_stale_q;
  assign fire            = valid_o && ready_i;
  assign pc_o            = pc_q;
  assign instr_o         = exp_instr;
  assign raw_o           = exp_c ? {16'd0, window[15:0]} : window;
  assign is_compressed_o = exp_c;
  assign illegal_c_o     = exp_ill && !aligned_err;
  assign fetch_err_o     = aligned_err;
  assign fetch_err_hi_o  = aligned_err && !e0;

  // ---------------------------------------------------------------------------
  // Request
  // ---------------------------------------------------------------------------
  logic        out_ok, space_ok, req, granted, stale_grant;
  logic [31:0] redirect_word;

  assign redirect_word = {redirect_pc_i[31:2], 2'b00};
  assign out_ok        = (outst_q < MAX_OUT[1:0]) || instr_rvalid_i;
  assign space_ok      = ({1'b0, count_q} + {1'b0, outst_q}) < DEPTH[2:0];
  assign req           = run_q && (pend_q || (out_ok && (redirect_i || space_ok)));
  assign instr_req_o   = req;
  assign seq_addr      = seq_inc_q ? seq_base_q + 32'd4 : seq_base_q;
  assign instr_addr_o  = pend_q ? pend_addr_q : redirect_i ? redirect_word : seq_addr;
  assign granted       = req && instr_gnt_i;
  assign stale_grant   = granted && pend_q && (pend_stale_q || redirect_i);

  // ---------------------------------------------------------------------------
  // Next state
  // ---------------------------------------------------------------------------
  logic        pop_now;
  logic [31:0] n0, n1, n2;
  logic        ne0, ne1, ne2;

  assign pop_now = fire && pop;
  assign n0  = pop_now ? w1 : w0;
  assign n1  = pop_now ? w2 : w1;
  assign n2  = pop_now ? w3 : w2;
  assign ne0 = pop_now ? e1 : e0;
  assign ne1 = pop_now ? e2 : e1;
  assign ne2 = pop_now ? e3 : e2;
  // At most 3: a request is only issued when the buffer has room for its response.
  logic [1:0] n_count_lo;
  assign n_count_lo = avail[1:0] - {1'b0, pop_now};

  always_comb begin
    // outstanding / discard bookkeeping
    outst_d = outst_q + {1'b0, granted} - {1'b0, instr_rvalid_i};
    if (redirect_i)
      discard_d = outst_q - {1'b0, instr_rvalid_i};
    else
      discard_d = discard_q - {1'b0, instr_rvalid_i && (discard_q != 2'd0)};
    if (stale_grant) discard_d = discard_d + 2'd1;

    // held request
    pend_d       = req && !instr_gnt_i;
    pend_addr_d  = instr_addr_o;
    pend_stale_d = pend_d && (pend_q ? (pend_stale_q || redirect_i) : 1'b0);

    // next sequential request address
    if (redirect_i) begin
      seq_base_d = redirect_word;
      seq_inc_d  = granted && !pend_q;        // the target itself was requested now
    end else if (granted && !stale_grant) begin
      seq_base_d = instr_addr_o;
      seq_inc_d  = 1'b1;
    end else begin
      seq_base_d = seq_base_q;
      seq_inc_d  = seq_inc_q;
    end

    // buffer and PC
    if (redirect_i) begin
      count_d = 2'd0;
      pc_d    = redirect_pc_i;
    end else begin
      count_d = n_count_lo;
      pc_d    = fire ? pc_q + (exp_c ? 32'd2 : 32'd4) : pc_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q         <= BOOT_ADDR;
      run_q        <= 1'b0;
      seq_base_q   <= {BOOT_ADDR[31:2], 2'b00};
      seq_inc_q    <= 1'b0;
      count_q      <= 2'd0;
      outst_q      <= 2'd0;
      discard_q    <= 2'd0;
      pend_q       <= 1'b0;
      pend_stale_q <= 1'b0;
      pend_addr_q  <= 32'd0;
      buf0_q <= 32'd0; buf1_q <= 32'd0; buf2_q <= 32'd0;
      err0_q <= 1'b0;  err1_q <= 1'b0;  err2_q <= 1'b0;
    end else begin
      pc_q         <= pc_d;
      run_q        <= 1'b1;
      seq_base_q   <= seq_base_d;
      seq_inc_q    <= seq_inc_d;
      count_q      <= count_d;
      outst_q      <= outst_d;
      discard_q    <= discard_d;
      pend_q       <= pend_d;
      pend_stale_q <= pend_stale_d;
      pend_addr_q  <= pend_addr_d;
      buf0_q <= n0;  buf1_q <= n1;  buf2_q <= n2;
      err0_q <= ne0; err1_q <= ne1; err2_q <= ne2;
    end
  end

endmodule
