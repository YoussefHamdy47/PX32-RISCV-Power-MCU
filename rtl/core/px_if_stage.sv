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
// Vector table fetch (Phase 2 step 2.2d, DECISIONS.md D-035 items 16-19; smclicshv, D-029
// registered table word): a redirect with vec_i set does not fetch instructions at
// redirect_pc_i but the vector table entry at that (word) address. vstate:
//   IDLE   normal fetching
//   FETCH  the table request is issued as the first request of the new stream (after any
//          older outstanding or held request, D-021: their responses are dropped by the
//          discard counter); once it is granted no other request is issued, so the first
//          kept response is the table word. It is not delivered to ID: bit 0 is cleared and
//          the word registered (vword_q).
//   JUMP   one cycle: the fetch stage redirects itself to vword_q (as for redirect_i, but
//          from a flop: the deep redirect_pc_i path keeps its mux depth).
//   FAULT  the table response carried an error: it is buffered as a faulting entry at
//          pc = the table address and delivered with vec_fault_o (the core raises an
//          instruction access fault with minhv = 1); no request is issued until a redirect.
// vec_busy_o (a flop decode) is 1 outside IDLE: the core takes no interrupt then (the next
// instruction's pc is not known yet). A redirect_i in any state starts over (none can occur
// in practice: the pipeline behind a vector redirect is empty).
// Timing (1-cycle memory): vector redirect in cycle t (table request), table word in t+1,
// target requested in t+2 (JUMP), instruction leaves IF in t+3, ID t+4, EX t+5.
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
  input  logic        vec_i,          // with redirect_i: fetch the vector table entry at redirect_pc_i
  output logic        vec_busy_o,     // a vector table fetch is in progress
  output logic        vec_fault_o,    // the delivered entry is a table-fetch fault

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
  // vector table fetch (D-035)
  localparam logic [1:0] V_IDLE = 2'd0, V_FETCH = 2'd1, V_JUMP = 2'd2, V_FAULT = 2'd3;
  logic [1:0]  vstate_q, vstate_d;
  logic        vreq_q, vreq_d;                   // the table request has been granted
  logic [31:0] vword_q, vword_d;                 // handler address (table word, bit 0 cleared)
  logic        jump;                             // self-redirect to vword_q this cycle
  logic        tbl_resp;                         // this cycle's kept response is the table word
  logic [31:0] vword_al, tbl_word;               // part-selects outside always_* (Icarus)
  assign vword_al = {vword_q[31:2], 2'b00};
  assign tbl_word = {instr_rdata_i[31:1], 1'b0};

  // ---------------------------------------------------------------------------
  // Word view: buffer entries followed by this cycle's (kept) response
  // ---------------------------------------------------------------------------
  logic        resp_keep;
  logic [2:0]  avail;
  logic [31:0] w0, w1, w2, w3;
  logic        e0, e1, e2, e3;

  // A kept response in FETCH is the table word: not buffered unless it faulted (FAULT
  // delivers it as a faulting entry).
  assign tbl_resp  = (vstate_q == V_FETCH) && instr_rvalid_i && (discard_q == 2'd0);
  assign resp_keep = instr_rvalid_i && (discard_q == 2'd0) && !(tbl_resp && !instr_err_i);
  assign avail     = {1'b0, count_q} + {2'b00, resp_keep};
  assign jump      = (vstate_q == V_JUMP);

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

  // Nothing is delivered in a redirect cycle, during a table fetch or in the JUMP cycle; in
  // FAULT the faulting table entry is delivered.
  assign valid_o         = aligned_valid && !redirect_i && !pend_stale_q &&
                           (vstate_q == V_IDLE || vstate_q == V_FAULT);
  assign vec_busy_o      = (vstate_q != V_IDLE);
  assign vec_fault_o     = (vstate_q == V_FAULT);
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
  // No request while the table word is awaited or a table fault is pending (D-035)
  logic        vblock;
  assign vblock        = (vstate_q == V_FETCH && vreq_q) || (vstate_q == V_FAULT);
  assign req           = run_q && (pend_q || (out_ok && (redirect_i || jump || (space_ok && !vblock))));
  assign instr_req_o   = req;
  assign seq_addr      = seq_inc_q ? seq_base_q + 32'd4 : seq_base_q;
  // the JUMP target comes from a flop, inside the redirect_i mux: redirect_pc_i keeps its depth
  assign instr_addr_o  = pend_q ? pend_addr_q : redirect_i ? redirect_word :
                         jump ? vword_al : seq_addr;
  assign granted       = req && instr_gnt_i;
  assign stale_grant   = granted && pend_q && (pend_stale_q || redirect_i || jump);

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
    if (redirect_i || jump)
      discard_d = outst_q - {1'b0, instr_rvalid_i};
    else
      discard_d = discard_q - {1'b0, instr_rvalid_i && (discard_q != 2'd0)};
    if (stale_grant) discard_d = discard_d + 2'd1;

    // held request
    pend_d       = req && !instr_gnt_i;
    pend_addr_d  = instr_addr_o;
    pend_stale_d = pend_d && (pend_q ? (pend_stale_q || redirect_i || jump) : 1'b0);

    // next sequential request address
    if (redirect_i) begin
      seq_base_d = redirect_word;
      seq_inc_d  = granted && !pend_q;        // the target itself was requested now
    end else if (jump) begin
      seq_base_d = vword_al;
      seq_inc_d  = granted && !pend_q;
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
    end else if (jump) begin
      count_d = 2'd0;
      pc_d    = vword_q;
    end else begin
      count_d = n_count_lo;
      pc_d    = fire ? pc_q + (exp_c ? 32'd2 : 32'd4) : pc_q;
    end

    // vector table fetch
    vword_d = vword_q;
    vreq_d  = vreq_q;
    if (redirect_i) begin
      vstate_d = vec_i ? V_FETCH : V_IDLE;
      vreq_d   = vec_i && granted && !stale_grant;  // the table request went out now
    end else begin
      vstate_d = vstate_q;
      case (vstate_q)
        V_FETCH: begin
          if (granted && !stale_grant) vreq_d = 1'b1;
          if (tbl_resp) begin
            if (instr_err_i) vstate_d = V_FAULT;
            else begin
              vstate_d = V_JUMP;
              vword_d  = tbl_word;
            end
          end
        end
        V_JUMP:  vstate_d = V_IDLE;
        V_FAULT: if (fire) vstate_d = V_IDLE;
        default: ;
      endcase
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
      vstate_q     <= V_IDLE;
      vreq_q       <= 1'b0;
      vword_q      <= 32'd0;
    end else begin
      vstate_q     <= vstate_d;
      vreq_q       <= vreq_d;
      vword_q      <= vword_d;
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
