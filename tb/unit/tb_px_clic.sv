// tb_px_clic: self-checking unit test for px_clic (Phase 2 step 2.2c, DECISIONS.md D-034,
// PHASE2_VERIFICATION.md § 3.1).
//
// Reference: tb/models/clic_ref_model.sv, a behavioural cycle model written from the pinned
// CLIC draft, PHASE2_CLIC_MATRIX.md and D-034 (linear-scan selection, no tree). Every
// output of the unit is compared with the model every cycle, just before the clock edge.
// Directed tests also compare against explicit constants and cycle numbers, so a mistake
// shared by the model and the RTL is still caught.
//
//   D1  reset values of all 64 entries (explicit constant)
//   D2  every field of every entry: word, halfword and byte stores, WARL read-back
//       (explicit values); a distinct pattern in all 64 entries read back (no crosstalk)
//   D3  reserved offsets (0x0000, clicinttrig, custom, inputs 64-4095, 0x8000-0xFFFF and
//       the bit-15 / bits 11:8 alias candidates): read 0, writes ignored, no state change
//   D4  bus protocol: grant in the request cycle, rvalid exactly one cycle later, err never,
//       back-to-back reads and write-then-read
//   D5  level mode, both polarities, every input; writes to the pending bit ignored
//   D6  edge mode, both polarities, every input; software set and clear
//   D7  trig changes while the input is static (D-034 item 7)
//   D8  the same-cycle priority table (D-034 item 8), every row
//   D9  ack vectored / non-vectored / level, claim, the invalidation cycle, ack then claim,
//       a different winner presented right after an ack or claim (item 14), an edge in the
//       ack cycle
//   D10 qualification: mil and mintthresh boundaries at every level, CLIC mode, and the
//       current-state timing (item 13)
//   D11 K-27 / K-28 timing: store and input effects counted in cycles
//   D12 every id as the only candidate; K-60
//   R   random stimulus (seeded, +seed=N), biased to ties, equal levels, single and empty
//       candidate sets, core-like ack/claim plus some free ones
// Monitors (independent of the model): an id acknowledged or claimed in cycle T is not
// presented in T+1; an edge-mode id is acknowledged (vectored) or claimed at most once per
// set event (edge or software set). Every coverage bin must be hit, otherwise the test fails.
//
// Run: scripts/run_unit.sh tb_px_clic [+seed=N] [+vcd]

`timescale 1ns/1ps

module tb_px_clic;

  localparam int N          = 64;
  int NUM_RANDOM = 100000;     // +random=N overrides (default 100,000)

  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk;

  // stimulus
  logic [N-1:0] irq;
  logic         req, we;
  logic [15:0]  addr;
  logic [3:0]   be;
  logic [31:0]  wdata;
  logic [7:0]   mil, th;
  logic         mode;
  logic         ack, claim;
  logic [5:0]   ack_id, claim_id;

  // unit outputs
  logic        d_gnt, d_rvalid, d_err, d_req, d_valid, d_shv;
  logic [31:0] d_rdata;
  logic [5:0]  d_id;
  logic [7:0]  d_level;
  // model outputs
  logic        m_gnt, m_rvalid, m_err, m_req, m_valid, m_shv;
  logic [31:0] m_rdata;
  logic [5:0]  m_id;
  logic [7:0]  m_level;

  px_clic #(.NUM_IRQ(N), .LVL_BITS(4)) dut (
    .clk_i(clk), .rst_ni(rst_n), .irq_i(irq),
    .req_i(req), .gnt_o(d_gnt), .addr_i(addr), .we_i(we), .be_i(be), .wdata_i(wdata),
    .rvalid_o(d_rvalid), .rdata_o(d_rdata), .err_o(d_err),
    .mil_i(mil), .mintthresh_i(th), .clic_mode_i(mode),
    .ack_i(ack), .ack_id_i(ack_id), .claim_i(claim), .claim_id_i(claim_id),
    .irq_req_o(d_req), .irq_valid_o(d_valid), .irq_id_o(d_id), .irq_level_o(d_level),
    .irq_shv_o(d_shv));

  clic_ref_model #(.NUM(N), .LB(4)) mdl (
    .clk(clk), .rst_n(rst_n), .irq(irq),
    .req(req), .addr(addr), .we(we), .be(be), .wdata(wdata),
    .gnt(m_gnt), .rvalid(m_rvalid), .rdata(m_rdata), .err(m_err),
    .mil(mil), .th(th), .clic_mode(mode),
    .ack(ack), .ack_id(ack_id), .claim(claim), .claim_id(claim_id),
    .req_out(m_req), .valid_out(m_valid), .id_out(m_id), .level_out(m_level), .shv_out(m_shv));

  int errors = 0;
  int checks = 0;
  int seed, seed0, nrand;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 30) $display("ERROR t=%0t: %s", $time, msg);
  endtask

  task automatic expect_eq(input logic [31:0] got, input logic [31:0] exp, input string what);
    checks++;
    if (got !== exp) fail($sformatf("%s: got 0x%08h, expected 0x%08h", what, got, exp));
  endtask

  // ------------------------------------------------------------------ per-cycle comparison
  always @(negedge clk) begin
    if (rst_n === 1'b1) begin
      checks++;
      if ({d_gnt, d_rvalid, d_err, d_req, d_valid, d_shv, d_rdata, d_id, d_level} !==
          {m_gnt, m_rvalid, m_err, m_req, m_valid, m_shv, m_rdata, m_id, m_level})
        fail($sformatf("unit/model differ: gnt %b/%b rvalid %b/%b err %b/%b req %b/%b valid %b/%b shv %b/%b rdata %h/%h id %0d/%0d level %h/%h",
                       d_gnt, m_gnt, d_rvalid, m_rvalid, d_err, m_err, d_req, m_req, d_valid, m_valid,
                       d_shv, m_shv, d_rdata, m_rdata, d_id, m_id, d_level, m_level));
      if (d_err !== 1'b0) fail("err asserted");
      if (d_gnt !== req) fail("grant not in the request cycle");
    end
  end

  // ------------------------------------------------------------------ coverage
  int cov_k [20:71];                 // matrix rows observed (index = row number)
  int cov_win_lvl [0:15];
  int cov_tie_lvl [0:15];
  int cov_win_id [0:63];
  int cov_conf [0:7];                // D-034 item 8 rows, see conf_name
  int cov_stale [0:7];               // stale-qualification and invalidation scenarios
  int cov_set_empty, cov_set_single, cov_set_equal, cov_set_many;
  int cov_access [0:2];              // byte, halfword, word stores to entries
  int cov_free_ack, cov_proto_ack, cov_proto_claim;

  function automatic string conf_name(input int r);
    case (r)
      0: conf_name = "edge + software write 0";
      1: conf_name = "edge + vectored ack of this id";
      2: conf_name = "edge + claim of this id";
      3: conf_name = "software write 1 + clear";
      4: conf_name = "software write 0 + clear";
      5: conf_name = "clear only";
      6: conf_name = "software write only";
      default: conf_name = "non-vectored ack (no clear)";
    endcase
  endfunction

  function automatic string stale_name(input int r);
    case (r)
      0: stale_name = "ack: acked id not presented next cycle";
      1: stale_name = "claim: claimed id not presented next cycle";
      2: stale_name = "mintthresh raise acts in the same cycle";
      3: stale_name = "mil raise acts in the same cycle";
      4: stale_name = "CLINT mode acts in the same cycle";
      5: stale_name = "store disabling the winner: one-cycle lag (K-27)";
      6: stale_name = "another winner presented right after ack/claim";
      default: stale_name = "edge in the ack/claim cycle serviced again";
    endcase
  endfunction

  // Monitor state, sampled at the negedge before the edge it describes. Whole-vector
  // operations on the model's state (bit i = input i), one pass per cycle.
  logic         p_ack, p_claim;
  logic [5:0]   p_ack_id, p_claim_id;
  logic [N-1:0] armed;

  always @(negedge clk) begin : monitor
    int           top, cnt, ncand;
    logic [N-1:0] cand, m, edge_ev, sw_v, ack_v, claim_v, clr_v, set_v, edge_m;
    logic         hit;
    if (rst_n !== 1'b1) begin
      p_ack = 1'b0; p_claim = 1'b0;
      armed = '0;
    end else begin
      // invalidation monitor: an id acknowledged / claimed in the previous cycle is not presented
      if (p_ack && d_valid && d_id == p_ack_id) fail($sformatf("acked id %0d presented in the next cycle", p_ack_id));
      if (p_claim && d_valid && d_id == p_claim_id) fail($sformatf("claimed id %0d presented in the next cycle", p_claim_id));
      if (p_ack && d_valid && d_id != p_ack_id) cov_stale[6]++;
      if (p_claim && d_valid && d_id != p_claim_id) cov_stale[6]++;
      if (p_ack) cov_stale[0]++;
      if (p_claim) cov_stale[1]++;
      // winner coverage
      if (d_valid) begin
        cov_win_lvl[d_level[7:4]]++;
        cov_win_id[d_id]++;
      end
      // candidate-set shape and ties, from the model state of this cycle
      cand  = mdl.ip & mdl.ie;
      ncand = $countones(cand);
      top = -1; cnt = 0;
      for (int l = 15; l >= 0 && top < 0; l--) begin
        m = cand & (l[3] ? mdl.lvb[7] : ~mdl.lvb[7]) & (l[2] ? mdl.lvb[6] : ~mdl.lvb[6]) &
                   (l[1] ? mdl.lvb[5] : ~mdl.lvb[5]) & (l[0] ? mdl.lvb[4] : ~mdl.lvb[4]);
        if (m != '0) begin top = l; cnt = $countones(m); end
      end
      if (ncand == 0) cov_set_empty++;
      else if (ncand == 1) cov_set_single++;
      else begin
        cov_set_many++;
        if (cnt == ncand) cov_set_equal++;
      end
      if (cnt >= 2) cov_tie_lvl[top]++;
      // conflict-table rows (edge-mode inputs) and the once-per-set-event monitor
      hit     = req && we && (addr[15:12] == 4'h1) && (addr[11:8] == 4'h0);
      edge_m  = mdl.tedge;
      edge_ev = edge_m & ((mdl.tneg & ~irq & mdl.prev) | (~mdl.tneg & irq & ~mdl.prev));
      sw_v    = (hit && be[0]) ? (N'(1) << addr[7:2]) : '0;
      ack_v   = ack ? (N'(1) << ack_id) : '0;
      claim_v = claim ? (N'(1) << claim_id) : '0;
      clr_v   = (d_shv ? ack_v : '0) | claim_v;
      if ((edge_ev & sw_v) != '0 && !wdata[0])                         cov_conf[0]++;
      if ((edge_ev & ack_v) != '0 && d_shv)                            cov_conf[1]++;
      if ((edge_ev & claim_v) != '0)                                   cov_conf[2]++;
      if ((edge_m & ~edge_ev & sw_v & clr_v) != '0 && wdata[0])        cov_conf[3]++;
      if ((edge_m & ~edge_ev & sw_v & clr_v) != '0 && !wdata[0])       cov_conf[4]++;
      if ((edge_m & ~edge_ev & ~sw_v & clr_v) != '0)                   cov_conf[5]++;
      if ((edge_m & ~edge_ev & sw_v & ~clr_v) != '0)                   cov_conf[6]++;
      if ((edge_m & ~edge_ev & ~sw_v & ack_v & mdl.ip) != '0 && !d_shv) cov_conf[7]++;
      if ((edge_ev & clr_v) != '0)                                     cov_stale[7]++;
      // a core-like (presented) vectored ack or claim of an edge-mode id must find a set
      // event (edge or software set) since its last clear by ack/claim: one service per event
      armed = armed | ~edge_m;   // level mode: the stored bit may survive a switch to edge mode
      if (ack && d_req && ack_id == d_id && d_shv && edge_m[ack_id] && !armed[ack_id])
        fail($sformatf("id %0d acknowledged twice for one set event", ack_id));
      if (claim && d_valid && claim_id == d_id && edge_m[claim_id] && !armed[claim_id])
        fail($sformatf("id %0d claimed twice for one set event", claim_id));
      set_v = edge_ev | (sw_v & {N{wdata[0]}});
      armed = (armed | set_v) & ~(clr_v & edge_m & ~set_v);   // level mode clears nothing
      p_ack = ack; p_ack_id = ack_id; p_claim = claim; p_claim_id = claim_id;
    end
  end

  // ------------------------------------------------------------------ drivers
  task automatic tick();
    @(posedge clk);
    #1;
  endtask

  task automatic idle();
    req = 1'b0; we = 1'b0; addr = '0; be = '0; wdata = '0;
    ack = 1'b0; claim = 1'b0; ack_id = '0; claim_id = '0;
  endtask

  // one store (granted in this cycle); returns after the grant edge (response cycle)
  task automatic store(input logic [15:0] a, input logic [3:0] b, input logic [31:0] d);
    req = 1'b1; we = 1'b1; addr = a; be = b; wdata = d;
    tick();
    req = 1'b0; we = 1'b0; be = '0;
    if (d_rvalid !== 1'b1 || d_rdata !== 32'd0) fail($sformatf("store 0x%04h: rvalid %b rdata %h", a, d_rvalid, d_rdata));
    if (b == 4'hF) cov_access[2]++;
    else if (b == 4'h3 || b == 4'hC) cov_access[1]++;
    else cov_access[0]++;
  endtask

  task automatic load(input logic [15:0] a, output logic [31:0] d);
    req = 1'b1; we = 1'b0; addr = a; be = 4'hF; wdata = '0;
    tick();
    req = 1'b0;
    if (d_rvalid !== 1'b1) fail($sformatf("load 0x%04h: no rvalid", a));
    d = d_rdata;
  endtask

  function automatic logic [15:0] ent(input int i);
    ent = 16'h1000 + 16'(4 * i);
  endfunction

  task automatic check_entry(input int i, input logic [31:0] exp, input string what);
    logic [31:0] v;
    load(ent(i), v);
    expect_eq(v, exp, $sformatf("%s entry %0d", what, i));
  endtask

  // configure one entry with a word store: ip, ie, attr bits 2:0 {neg, edge, shv}, level
  task automatic cfg(input int i, input logic ipv, input logic iev, input logic [2:0] attr, input logic [3:0] lvl);
    store(ent(i), 4'hF, {lvl, 4'h0, 5'b0, attr, 7'b0, iev, 7'b0, ipv});
  endtask

  task automatic clear_all();
    for (int i = 0; i < N; i++) store(ent(i), 4'hF, 32'd0);
    irq = '0;
    tick(); tick();
  endtask

  // ------------------------------------------------------------------ directed tests
  task automatic d1_reset();
    for (int i = 0; i < N; i++) check_entry(i, 32'h0FC0_0000, "D1 reset");
    expect_eq({31'd0, d_valid}, 32'd0, "D1 no winner after reset");
  endtask

  task automatic d2_fields();
    for (int i = 0; i < N; i++) begin
      store(ent(i), 4'hF, 32'hFFFF_FFFF);   // level mode at the store: pending follows the input (0)
      check_entry(i, 32'hFFC7_0100, "D2 word all ones");
      store(ent(i), 4'hF, 32'h0000_0000);
      check_entry(i, 32'h0FC0_0000, "D2 word zero");
      store(ent(i) + 16'd1, 4'b0010, 32'h0000_FF00);   // byte 1: ie
      store(ent(i) + 16'd2, 4'b0100, 32'h003A_0000);   // byte 2: mode 00, 5:3 = 111, trig 01, shv 0
      store(ent(i) + 16'd3, 4'b1000, 32'h5A00_0000);   // byte 3: ctl
      store(ent(i), 4'b0001, 32'h0000_0003);            // byte 0: now edge mode, bit 0 = 1
      check_entry(i, 32'h5FC2_0101, "D2 bytes");
      store(ent(i), 4'b0011, 32'h0000_0100);            // halfword ip/ie
      store(ent(i) + 16'd2, 4'b1100, 32'hA5FE_0000);   // halfword attr/ctl: trig 11, shv 0
      check_entry(i, 32'hAFC6_0100, "D2 halfwords");
      store(ent(i) + 16'd2, 4'b0100, 32'h0001_0000);   // shv alone, edge off
      check_entry(i, 32'hAFC1_0100, "D2 shv");
      store(ent(i), 4'hF, 32'd0);
      cov_k[22]++; cov_k[23]++; cov_k[26]++;
    end
    // distinct pattern in every entry: no crosstalk, no aliasing between indices
    for (int i = 0; i < N; i++)
      store(ent(i), 4'hF, {4'(i), 4'h0, 5'b0, 3'(i % 8) & 3'b101, 7'b0, 1'(i % 3 == 0), 7'b0, 1'b0});
    // level mode; inputs 0: the pending bit reads the polarity bit
    for (int i = 0; i < N; i++)
      check_entry(i, {4'(i), 4'hF, 2'b11, 3'b0, 3'(i % 8) & 3'b101, 7'b0, 1'(i % 3 == 0), 7'b0, 1'((i % 8) >= 4)}, "D2 pattern");
    clear_all();
    cov_k[21]++;
  endtask

  task automatic d3_reserved();
    logic [15:0] probes [0:27];
    logic [31:0] snap [0:N-1];
    logic [31:0] v;
    probes[0] = 16'h0000; probes[1] = 16'h0004; probes[2] = 16'h003C; probes[3] = 16'h0040;
    probes[4] = 16'h0044; probes[5] = 16'h00BC; probes[6] = 16'h00C0; probes[7] = 16'h0800;
    probes[8] = 16'h0FFC; probes[9] = 16'h1100; probes[10] = 16'h1104; probes[11] = 16'h11FC;
    probes[12] = 16'h1200; probes[13] = 16'h1400; probes[14] = 16'h1800; probes[15] = 16'h2000;
    probes[16] = 16'h3000; probes[17] = 16'h4FFC; probes[18] = 16'h5000; probes[19] = 16'h7FFC;
    probes[20] = 16'h8000; probes[21] = 16'h9000; probes[22] = 16'h9004; probes[23] = 16'h90FC;
    probes[24] = 16'hD000; probes[25] = 16'hFFFC; probes[26] = 16'h0100; probes[27] = 16'h9100;
    for (int i = 0; i < N; i++)
      store(ent(i), 4'hF, {4'(i), 4'h0, 5'b0, 3'b000, 7'b0, 1'b1, 7'b0, 1'b0});
    for (int i = 0; i < N; i++) begin load(ent(i), v); snap[i] = v; end
    for (int k = 0; k < 28; k++) begin
      load(probes[k], v);
      expect_eq(v, 32'd0, $sformatf("D3 read of reserved 0x%04h", probes[k]));
      store(probes[k], 4'hF, 32'hFFFF_FFFF);
      store(probes[k] + 16'd1, 4'b0010, 32'h0000_FF00);
      load(probes[k], v);
      expect_eq(v, 32'd0, $sformatf("D3 read after write of reserved 0x%04h", probes[k]));
    end
    for (int i = 0; i < N; i++) check_entry(i, snap[i], "D3 unchanged after reserved writes");
    clear_all();
    cov_k[24]++; cov_k[25]++;
  endtask

  task automatic d4_protocol();
    logic [31:0] v;
    // back-to-back reads of every entry with the request held high
    for (int i = 0; i < N; i++) store(ent(i), 4'b1000, {4'(i), 28'd0});
    req = 1'b1; we = 1'b0; be = 4'hF;
    for (int i = 0; i < N; i++) begin
      addr = ent(i);
      tick();
      expect_eq({31'd0, d_rvalid}, 32'd1, "D4 rvalid every cycle");
      expect_eq(d_rdata, {4'(i), 4'hF, 8'hC0, 16'd0}, "D4 back-to-back read");
    end
    req = 1'b0;
    tick();
    expect_eq({31'd0, d_rvalid}, 32'd0, "D4 no rvalid without a request");
    // write then read of the same entry in the next cycle
    for (int i = 0; i < 4; i++) begin
      req = 1'b1; we = 1'b1; addr = ent(i); be = 4'hF; wdata = 32'h7000_0100;
      tick();
      we = 1'b0;
      tick();
      expect_eq(d_rdata, 32'h7FC0_0100, "D4 read right after write");
      req = 1'b0;
      tick();
    end
    clear_all();
  endtask

  task automatic d5_level();
    for (int i = 0; i < N; i++) begin
      cfg(i, 1'b0, 1'b0, 3'b000, 4'd0);           // positive level
      irq[i] = 1'b1; tick();
      check_entry(i, 32'h0FC0_0001, "D5 positive level, input 1");
      store(ent(i), 4'b0001, 32'd0);                 // write ignored
      check_entry(i, 32'h0FC0_0001, "D5 level ignores write 0");
      irq[i] = 1'b0; tick();
      check_entry(i, 32'h0FC0_0000, "D5 positive level, input 0");
      store(ent(i), 4'b0001, 32'd1);
      check_entry(i, 32'h0FC0_0000, "D5 level ignores write 1");
      cfg(i, 1'b0, 1'b0, 3'b100, 4'd0);           // negative level: pending = !input
      tick();
      check_entry(i, 32'h0FC4_0001, "D5 negative level, input 0");
      irq[i] = 1'b1; tick();
      check_entry(i, 32'h0FC4_0000, "D5 negative level, input 1");
      irq[i] = 1'b0;
      store(ent(i), 4'hF, 32'd0);
    end
    tick();
    cov_k[20]++;
  endtask

  task automatic d6_edge();
    for (int i = 0; i < N; i++) begin
      cfg(i, 1'b0, 1'b0, 3'b010, 4'd0);           // positive edge
      irq[i] = 1'b1; tick();
      check_entry(i, 32'h0FC2_0001, "D6 rising edge sets");
      store(ent(i), 4'b0001, 32'd0);
      check_entry(i, 32'h0FC2_0000, "D6 software clear");
      tick(); tick();
      check_entry(i, 32'h0FC2_0000, "D6 held input: no new edge");
      irq[i] = 1'b0; tick();
      check_entry(i, 32'h0FC2_0000, "D6 falling edge ignored (positive)");
      store(ent(i), 4'b0001, 32'd1);
      check_entry(i, 32'h0FC2_0001, "D6 software set");
      store(ent(i), 4'b0001, 32'd0);
      store(ent(i) + 16'd2, 4'b0100, 32'h0006_0000); // negative edge
      irq[i] = 1'b1; tick();
      check_entry(i, 32'h0FC6_0000, "D6 rising edge ignored (negative)");
      irq[i] = 1'b0; tick();
      check_entry(i, 32'h0FC6_0001, "D6 falling edge sets (negative)");
      store(ent(i), 4'hF, 32'd0);
    end
    tick();
  endtask

  task automatic d7_trig_change();
    for (int i = 0; i < N; i += 7) begin
      // polarity change in edge mode with a static input: no edge
      cfg(i, 1'b0, 1'b0, 3'b010, 4'd0);
      irq[i] = 1'b1; tick();
      store(ent(i), 4'b0001, 32'd0);
      store(ent(i) + 16'd2, 4'b0100, 32'h0006_0000);
      tick();
      check_entry(i, 32'h0FC6_0000, "D7 polarity change (input high): no edge");
      store(ent(i) + 16'd2, 4'b0100, 32'h0002_0000);
      tick();
      check_entry(i, 32'h0FC2_0000, "D7 polarity change back: no edge");
      // level -> edge with the input active: the stored bit is kept, no new edge
      store(ent(i) + 16'd2, 4'b0100, 32'h0000_0000);
      tick();
      check_entry(i, 32'h0FC0_0001, "D7 level mode, input high");
      store(ent(i) + 16'd2, 4'b0100, 32'h0002_0000);
      tick(); tick();
      check_entry(i, 32'h0FC2_0001, "D7 level -> edge keeps the bit");
      store(ent(i), 4'b0001, 32'd0);
      check_entry(i, 32'h0FC2_0000, "D7 cleared after the switch");
      // edge -> level: the pending flop follows the input from the edge after the store's
      // write edge (a read returns the state before its grant edge)
      store(ent(i) + 16'd2, 4'b0100, 32'h0000_0000);
      check_entry(i, 32'h0FC0_0000, "D7 edge -> level: old value in the write cycle");
      check_entry(i, 32'h0FC0_0001, "D7 edge -> level follows the input");
      // word store that switches to edge mode and writes the pending bit: old mode rules
      irq[i] = 1'b0; tick();
      store(ent(i), 4'hF, 32'h0002_0001);
      check_entry(i, 32'h0FC2_0000, "D7 same-store pending write under level mode ignored");
      store(ent(i), 4'hF, 32'd0);
    end
    tick();
  endtask

  // set up input i alone as the winner: edge (positive), shv as given, pending via an edge
  task automatic arm_edge(input int i, input logic sv, input logic [3:0] lvl);
    cfg(i, 1'b0, 1'b1, {1'b0, 1'b1, sv}, lvl);
    irq[i] = 1'b1; tick();
    irq[i] = 1'b0; tick(); tick();
  endtask

  task automatic d8_conflicts();
    int i;
    mil = 8'd0; th = 8'd0; mode = 1'b1;
    for (int r = 0; r < 8; r++) begin
      i = 5 + 7 * r;
      arm_edge(i, (r == 7) ? 1'b0 : 1'b1, 4'd3);
      expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(i)}, "D8 winner before the conflict");
      // the conflict cycle
      case (r)
        0: begin irq[i] = 1'b1; req = 1'b1; we = 1'b1; addr = ent(i); be = 4'b0001; wdata = 32'd0; end
        1: begin irq[i] = 1'b1; ack = 1'b1; ack_id = 6'(i); end
        2: begin irq[i] = 1'b1; claim = 1'b1; claim_id = 6'(i); end
        3: begin req = 1'b1; we = 1'b1; addr = ent(i); be = 4'b0001; wdata = 32'd1; claim = 1'b1; claim_id = 6'(i); end
        4: begin req = 1'b1; we = 1'b1; addr = ent(i); be = 4'b0001; wdata = 32'd0; ack = 1'b1; ack_id = 6'(i); end
        5: begin claim = 1'b1; claim_id = 6'(i); end
        6: begin req = 1'b1; we = 1'b1; addr = ent(i); be = 4'b0001; wdata = 32'd1; end
        default: begin ack = 1'b1; ack_id = 6'(i); end   // non-vectored: no clear
      endcase
      tick();
      idle();
      case (r)
        0, 1, 2, 3, 6, 7: check_entry(i, {4'd3, 4'hF, 8'hC2 | 8'(r != 7), 16'h0101}, $sformatf("D8 row '%s'", conf_name(r)));
        default:          check_entry(i, {4'd3, 4'hF, 8'hC3, 16'h0100}, $sformatf("D8 row '%s'", conf_name(r)));
      endcase
      irq[i] = 1'b0;
      store(ent(i), 4'hF, 32'd0);
      tick();
    end
  endtask

  task automatic d9_ack_claim();
    int c, b, h;
    mil = 8'd0; th = 8'd0; mode = 1'b1;
    // vectored ack clears an edge bit; the acked id is not presented in the next cycle
    c = 10;
    arm_edge(c, 1'b1, 4'd6);
    expect_eq({31'd0, d_req}, 32'd1, "D9 request before the ack");
    ack = 1'b1; ack_id = 6'(c); tick(); idle();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 invalid in the cycle after the ack");
    tick();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 vectored edge cleared");
    cov_k[71]++;
    // non-vectored ack: bit stays, presented again from T+2
    store(ent(c) + 16'd2, 4'b0100, 32'h0002_0000);  // shv 0
    store(ent(c), 4'b0001, 32'd1);
    tick();
    ack = 1'b1; ack_id = 6'(c); tick(); idle();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 non-vectored: invalid in T+1");
    tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(c)}, "D9 non-vectored: presented again at T+2");
    // claim clears it
    claim = 1'b1; claim_id = 6'(c); tick(); idle();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 claim: invalid in T+1");
    tick();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 claim cleared the edge bit");
    // level interrupt: ack does not clear, it is presented again at T+2
    cfg(c, 1'b0, 1'b1, 3'b001, 4'd6);              // level, vectored
    irq[c] = 1'b1; tick(); tick();
    ack = 1'b1; ack_id = 6'(c); tick(); idle();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 level: invalid in T+1");
    tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(c)}, "D9 level: still pending at T+2");
    irq[c] = 1'b0; store(ent(c), 4'hF, 32'd0); tick(); tick();
    // ack of C, B (lower) presented in T+1 (selective invalidation), then claim of B
    c = 20; b = 3;
    arm_edge(b, 1'b0, 4'd2);
    arm_edge(c, 1'b1, 4'd9);
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(c)}, "D9 C is the winner");
    ack = 1'b1; ack_id = 6'(c); tick(); idle();
    // the maximum computed in the ack cycle was C itself: invalid in T+1, B from T+2
    // (B is not eligible in T+1 anyway: a take clears MIE, a claim raises mil to C's level)
    expect_eq({31'd0, d_valid}, 32'd0, "D9 invalid right after the ack of the maximum");
    tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(b)}, "D9 B presented at T+2");
    claim = 1'b1; claim_id = 6'(b); tick(); idle();
    expect_eq({31'd0, d_valid}, 32'd0, "D9 ack then claim: nothing left");
    tick();
    // claim of C while a higher H rises: H presented at T+1 (the latency case of item 14)
    c = 30; h = 2;
    arm_edge(c, 1'b0, 4'd4);
    cfg(h, 1'b0, 1'b1, 3'b011, 4'd15);
    mil = 8'h4F;                                    // inside C's handler: mil = C's level
    #1;
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(c)}, "D9 C presented (mnxti view)");
    expect_eq({31'd0, d_req}, 32'd0, "D9 no request at mil = level");
    irq[h] = 1'b1;                                 // H pending at the claim edge
    tick();
    claim = 1'b1; claim_id = 6'(c);                // pending flop of H set at this edge
    tick(); idle();
    expect_eq({24'd0, d_valid, d_id, d_req}, {24'd0, 1'b1, 6'(h), 1'b1}, "D9 H presented and requested in the cycle after the claim");
    // ack of H with a new edge of H in the same cycle: H serviced again
    irq[h] = 1'b0; tick();
    irq[h] = 1'b1; ack = 1'b1; ack_id = 6'(h); tick(); idle();
    expect_eq({31'd0, d_valid && d_id == 6'(h)}, 32'd0, "D9 H not presented right after its ack");
    tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'(h)}, "D9 the edge of the ack cycle is kept");
    irq = '0; mil = 8'd0;
    clear_all();
  endtask

  task automatic d10_qualification();
    logic [7:0] lvl8;
    mode = 1'b1;
    for (int l = 0; l < 16; l++) begin
      cfg(40, 1'b0, 1'b1, 3'b000, 4'(l));           // positive level
      irq[40] = 1'b1; tick(); tick();
      lvl8 = {4'(l), 4'hF};
      expect_eq({24'd0, d_level}, {24'd0, lvl8}, "D10 level output");
      for (int k = 0; k < 4; k++) begin
        // k: 0 mil = level - 1, 1 mil = level, 2 th = level - 1, 3 th = level
        mil = (k == 0) ? lvl8 - 8'd1 : (k == 1) ? lvl8 : 8'd0;
        th  = (k == 2) ? lvl8 - 8'd1 : (k == 3) ? lvl8 : 8'd0;
        #1;
        expect_eq({31'd0, d_req}, {31'd0, (k == 0 || k == 2)}, $sformatf("D10 level %0d boundary %0d", l, k));
        if (k == 1) cov_k[52]++;
        if (k == 3) cov_k[59]++;
      end
      mil = 8'd0; th = 8'd0; mode = 1'b0; #1;
      expect_eq({31'd0, d_req}, 32'd0, "D10 CLINT mode: no request");
      mode = 1'b1; #1;
      expect_eq({31'd0, d_req}, 32'd1, "D10 CLIC mode: request");
      tick();
    end
    // current-state timing: the winner register is unchanged, qualification acts at once
    th = 8'd0; mil = 8'd0; tick();
    expect_eq({31'd0, d_req}, 32'd1, "D10 request before the threshold write");
    th = 8'hFF; #1; expect_eq({31'd0, d_req}, 32'd0, "D10 threshold raise acts in the same cycle"); cov_stale[2]++;
    th = 8'd0; mil = 8'hFF; #1; expect_eq({31'd0, d_req}, 32'd0, "D10 mil raise acts in the same cycle"); cov_stale[3]++;
    mil = 8'd0; mode = 1'b0; #1; expect_eq({31'd0, d_req}, 32'd0, "D10 CLINT mode acts in the same cycle"); cov_stale[4]++;
    mode = 1'b1;
    // full sweep of mil and mintthresh against a level-0x9F winner
    cfg(40, 1'b0, 1'b1, 3'b000, 4'd9);
    tick(); tick();
    for (int v = 0; v < 256; v++) begin
      mil = 8'(v); th = 8'd0; #1;
      expect_eq({31'd0, d_req}, {31'd0, 8'h9F > 8'(v)}, "D10 mil sweep");
      mil = 8'd0; th = 8'(v); #1;
      expect_eq({31'd0, d_req}, {31'd0, 8'h9F > 8'(v)}, "D10 mintthresh sweep");
    end
    mil = 8'd0; th = 8'd0;
    irq[40] = 1'b0;
    clear_all();
    cov_k[51]++;
  endtask

  task automatic d11_timing();
    // K-28: input change in cycle T -> pending flop at edge T+1 (cycle 0) -> winner at edge T+2
    cfg(50, 1'b0, 1'b1, 3'b010, 4'd5);
    tick();
    irq[50] = 1'b1;                       // changes in cycle T
    expect_eq({31'd0, d_valid}, 32'd0, "D11 cycle T: nothing yet");
    tick();                               // edge T+1: pending set (cycle 0)
    expect_eq({31'd0, d_valid}, 32'd0, "D11 cycle 0: pending only");
    tick();                               // edge T+2: winner registered (cycle 1)
    expect_eq({24'd0, d_valid, d_id, d_req}, {24'd0, 1'b1, 6'd50, 1'b1}, "D11 cycle 1: request");
    cov_k[28]++;
    // K-27: a store disabling the presented winner: still presented in the cycle after the
    // write edge, gone one cycle later
    store(ent(50) + 16'd1, 4'b0010, 32'd0);
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'd50}, "D11 K-27 lag: still presented");
    tick();
    expect_eq({31'd0, d_valid}, 32'd0, "D11 K-27: gone one cycle later");
    cov_stale[5]++;
    // a store lowering the level: the old level is presented for one more cycle
    store(ent(50), 4'hF, 32'hC000_0101);                 // level 12, enabled, pending (edge mode? no: level mode now)
    irq[50] = 1'b1; tick(); tick();
    store(ent(50) + 16'd3, 4'b1000, 32'h1000_0000);
    expect_eq({24'd0, d_level}, 32'h0000_00CF, "D11 K-27 lag: old level");
    tick();
    expect_eq({24'd0, d_level}, 32'h0000_001F, "D11 K-27: new level");
    // a software set in edge mode: presented two edges after the store's grant
    irq[50] = 1'b0;
    store(ent(50), 4'hF, 32'h5002_0100);                 // edge, enabled, not pending
    tick();
    expect_eq({31'd0, d_valid}, 32'd0, "D11 no winner before the set");
    store(ent(50), 4'b0001, 32'd1);                      // write edge = T+1
    expect_eq({31'd0, d_valid}, 32'd0, "D11 set: not yet at T+1");
    tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'd50}, "D11 set: presented at T+2");
    cov_k[27]++;
    clear_all();
  endtask

  task automatic d12_ids();
    mil = 8'd0; th = 8'd0; mode = 1'b1;
    for (int i = 0; i < N; i++) begin
      cfg(i, 1'b0, 1'b1, 3'b001, 4'(i % 16));       // level mode, vectored
      irq[i] = 1'b1; tick(); tick();
      expect_eq({16'd0, d_valid, d_id, d_shv, d_level}, {16'd0, 1'b1, 6'(i), 1'b1, 4'(i % 16), 4'hF},
                $sformatf("D12 only candidate %0d", i));
      irq[i] = 1'b0;
      store(ent(i), 4'hF, 32'd0);
    end
    // K-60: ctl 0x00 reads 0x0F and requests above mil = 0
    cfg(7, 1'b0, 1'b1, 3'b000, 4'd0);
    irq[7] = 1'b1; tick(); tick();
    expect_eq({23'd0, d_req, d_level}, {23'd0, 1'b1, 8'h0F}, "D12 K-60 lowest level requests");
    mil = 8'h0F; #1;
    expect_eq({31'd0, d_req}, 32'd0, "D12 K-60 masked at mil 15");
    mil = 8'd0;
    cov_k[60]++;
    // equal levels: the highest id wins; all 64 at one level
    for (int i = 0; i < N; i++) cfg(i, 1'b0, 1'b1, 3'b000, 4'd7);
    irq = '1; tick(); tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'd63}, "D12 all equal: highest id");
    irq[63] = 1'b0; tick(); tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'd62}, "D12 next highest id");
    store(ent(0) + 16'd3, 4'b1000, 32'h8000_0000); tick(); tick();
    expect_eq({25'd0, d_valid, d_id}, {25'd0, 1'b1, 6'd0}, "D12 higher level beats higher ids");
    cov_k[50]++;
    clear_all();
  endtask

  // ------------------------------------------------------------------ random
  task automatic random_phase();
    int r, pool_n;
    logic [3:0] pool [0:2];
    logic [15:0] a;
    for (int cyc = 0; cyc < NUM_RANDOM; cyc++) begin
      if (cyc % 1500 == 0) begin
        pool_n = 1 + ($unsigned($random(seed)) % 3);
        for (int k = 0; k < 3; k++) pool[k] = 4'($random(seed));
      end
      idle();
      // inputs: a few toggles, occasional bursts
      r = $unsigned($random(seed)) % 16;
      if (r < 6) irq[$unsigned($random(seed)) % N] ^= 1'b1;
      else if (r == 6) irq = irq ^ (64'($random(seed)) & 64'($random(seed)) & {32'($random(seed)), 32'($random(seed))});
      // bus
      r = $unsigned($random(seed)) % 100;
      if (r < 55) begin
        req = 1'b1;
        we  = ($unsigned($random(seed)) % 10) < 6;
        if ((r % 8) == 0) a = 16'($random(seed)) & 16'hFFFC;            // anywhere, mostly reserved
        else a = ent($unsigned($random(seed)) % N);
        addr = a;
        case ($unsigned($random(seed)) % 7)
          0: be = 4'b0001; 1: be = 4'b0010; 2: be = 4'b0100; 3: be = 4'b1000;
          4: be = 4'b0011; 5: be = 4'b1100; default: be = 4'b1111;
        endcase
        wdata = $random(seed);
        wdata[31:28] = pool[$unsigned($random(seed)) % pool_n];          // levels from a small pool
        if (($unsigned($random(seed)) % 10) < 7) wdata[8] = 1'b1;       // mostly enabled
        if (we && a[15:12] == 4'h1 && a[11:8] == 4'h0) begin
          if (be == 4'hF) cov_access[2]++;
          else if (be == 4'h3 || be == 4'hC) cov_access[1]++;
          else cov_access[0]++;
        end
      end
      // core state
      r = $unsigned($random(seed)) % 16;
      if (r == 0) mil = 8'($random(seed));
      else if (r == 1) mil = d_valid ? d_level - 8'(($unsigned($random(seed)) % 3)) : 8'd0;
      else if (r == 2) mil = 8'd0;
      r = $unsigned($random(seed)) % 16;
      if (r == 0) th = 8'($random(seed));
      else if (r == 1) th = d_valid ? d_level - 8'(($unsigned($random(seed)) % 2)) : 8'd0;
      else if (r < 4) th = 8'd0;
      if (($unsigned($random(seed)) % 64) == 0) mode = !mode;
      if (($unsigned($random(seed)) % 8) == 0) mode = 1'b1;
      // core-like ack and claim of the presented winner, plus a few free ones
      #1;
      if (d_req && ($unsigned($random(seed)) % 10) < 3) begin
        ack = 1'b1; ack_id = d_id; cov_proto_ack++;
      end else if (($unsigned($random(seed)) % 50) == 0) begin
        ack = 1'b1; ack_id = 6'($random(seed)); cov_free_ack++;
      end
      if (d_valid && ($unsigned($random(seed)) % 10) < 2) begin
        claim = 1'b1; claim_id = d_id; cov_proto_claim++;
      end else if (($unsigned($random(seed)) % 50) == 0) begin
        claim = 1'b1; claim_id = 6'($random(seed));
      end
      tick();
    end
    idle();
  endtask

  // ------------------------------------------------------------------ main
  initial begin
    int holes;
    if (!$value$plusargs("seed=%d", seed)) seed = 32'h2C2C_0001;
    seed0 = seed;
    if ($value$plusargs("random=%d", nrand)) NUM_RANDOM = nrand;
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_clic.vcd");
      $dumpvars(0, tb_px_clic);
    end
    for (int k = 20; k <= 71; k++) cov_k[k] = 0;
    for (int k = 0; k < 16; k++) begin cov_win_lvl[k] = 0; cov_tie_lvl[k] = 0; end
    for (int k = 0; k < 64; k++) cov_win_id[k] = 0;
    for (int k = 0; k < 8; k++) begin cov_conf[k] = 0; cov_stale[k] = 0; end
    for (int k = 0; k < 3; k++) cov_access[k] = 0;
    cov_set_empty = 0; cov_set_single = 0; cov_set_equal = 0; cov_set_many = 0;
    cov_free_ack = 0; cov_proto_ack = 0; cov_proto_claim = 0;
    irq = '0; mil = 8'd0; th = 8'd0; mode = 1'b1;
    idle();
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;
    tick();

    d1_reset();
    d2_fields();
    d3_reserved();
    d4_protocol();
    d5_level();
    d6_edge();
    d7_trig_change();
    d8_conflicts();
    d9_ack_claim();
    d10_qualification();
    d11_timing();
    d12_ids();
    random_phase();
    tick(); tick();

    // ---- coverage
    holes = 0;
    begin
      int rows [0:13];
      rows[0] = 20; rows[1] = 21; rows[2] = 22; rows[3] = 23; rows[4] = 24; rows[5] = 25; rows[6] = 26;
      rows[7] = 27; rows[8] = 28; rows[9] = 50; rows[10] = 51; rows[11] = 52; rows[12] = 59; rows[13] = 60;
      for (int k = 0; k < 14; k++) if (cov_k[rows[k]] == 0) begin holes++; $display("hole: K-%0d", rows[k]); end
      if (cov_k[71] == 0) begin holes++; $display("hole: K-71"); end
    end
    for (int k = 0; k < 16; k++) begin
      if (cov_win_lvl[k] == 0) begin holes++; $display("hole: level %0d never the winner", k); end
      if (cov_tie_lvl[k] == 0) begin holes++; $display("hole: no tie at level %0d", k); end
    end
    for (int k = 0; k < 64; k++) if (cov_win_id[k] == 0) begin holes++; $display("hole: id %0d never the winner", k); end
    for (int k = 0; k < 8; k++) if (cov_conf[k] == 0) begin holes++; $display("hole: conflict row '%s'", conf_name(k)); end
    for (int k = 0; k < 8; k++) if (cov_stale[k] == 0) begin holes++; $display("hole: scenario '%s'", stale_name(k)); end
    for (int k = 0; k < 3; k++) if (cov_access[k] == 0) begin holes++; $display("hole: access size %0d", k); end
    if (cov_set_empty == 0 || cov_set_single == 0 || cov_set_equal == 0 || cov_set_many == 0) begin
      holes++; $display("hole: candidate-set shapes empty %0d single %0d equal %0d many %0d",
                        cov_set_empty, cov_set_single, cov_set_equal, cov_set_many);
    end
    if (cov_free_ack == 0 || cov_proto_ack == 0 || cov_proto_claim == 0) begin holes++; $display("hole: ack/claim kinds"); end
    if (holes != 0) fail($sformatf("%0d coverage holes", holes));

    if (errors == 0)
      $display("PASS tb_px_clic (%0d checks, %0d random cycles, seed %0d, %0d acks and %0d claims of the presented winner, full functional coverage)",
               checks, NUM_RANDOM, seed0, cov_proto_ack, cov_proto_claim);
    else begin
      $display("FAIL tb_px_clic (%0d errors, %0d checks)", errors, checks);
      $fatal(1, "tb_px_clic failed");
    end
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL tb_px_clic (TIMEOUT)");
    $fatal(1, "timeout");
  end

endmodule
