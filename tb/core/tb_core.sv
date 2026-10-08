// tb_core: runs every core test program on px_core (step 1.5, extended by the pre-1.6 audit).
//
// LIST names the program list: tb/core/programs/list.txt holds the directed programs
// (sw/tests/core); tb_core_random instantiates this bench with list_random.txt, the
// generated random programs, and RANDOM_SET = 1 (fewer modes per program: Icarus runs
// the core at a few thousand cycles per second).
//
// Each program runs in several memory modes (directed: all seven runs below; random:
// ideal, one stress, one long and one reset run):
//   ideal   single-cycle memories (grant at once, response next cycle). Timing markers
//           are checked here and a retirement trace is written to sim/logs/.
//   stress  random grant delays and 1-3 cycle response latency on both ports; bus data
//           and error inputs carry random garbage whenever rvalid is low.
//   long    bursty grants with gaps of up to 40 cycles and 1-8 cycle responses.
//   reset   stress mode with an asynchronous reset asserted between clock edges at a
//           random point of the run (requests and responses in flight); the program is
//           reloaded and must then run to completion.
// Timing is only checked in ideal mode; everything else is checked in every mode.
//
// Memory model: ITCM 64 KB at 0x1000_0000 (fetch and data port), DTCM 64 KB at
// 0x2000_0000 (data port only), and a side-effect device at 0x2001_0000 (word 0: each
// read returns the number of earlier reads; word 1: each write increments a counter that
// reads return). Anything else returns a bus error, as does a fetch from DTCM or the
// device, so programs can test access faults.
//
// Pass criteria per run
//   - the retirement trace equals the independent reference model's trace
//     (<prog>.trace.ref from scripts/px_iss.py): pc, instruction, rd and value, memory
//     address, byte masks and the data of the masked lanes, up to the tohost store. The
//     reference marks bits it cannot know (values derived from mcycle, which depends on
//     memory timing) with a care mask; every other bit is compared
//   - the traps equal both the reference model's list (<prog>.traps.ref) and the
//     program's own table at 0x2000_F000 (count, then cause/pc/tval per trap; a count of -1
//     means no table). The table is copied when the program is loaded, so the program
//     under test cannot change it
//   - the store of 1 to tohost (0x2000_FFF0) is granted and retires before the cycle limit
//   - every timing marker retires exactly its declared number of cycles after the
//     previous one (ideal mode)
//   - cycle-count checks: a store to CYCEXP (0x2000_FFE4) declares an expected value, the
//     next store to CYCCHK (0x2000_FFE8) supplies a value measured with mcycle. It must
//     equal the expectation in ideal mode and be at least the expectation in the other
//     modes (stalls only add cycles)
//   - CSR side effects: a CSR commit, MRET, or a multiply/divide leaving EX never
//     coincides with a trap; the divider only runs while a divide is valid in EX (a killed
//     divide leaves nothing behind)
// A run stops early (fail fast) after MAX_RUN_ERRORS errors, e.g. when a bug sends the
// program into a trap storm; a trap beyond the reference model's count is an error.
//   - OBI rules on both ports: a request that is not granted keeps its address and
//     attributes; at most one request outstanding per port (contract §3.2: a response and
//     the next grant may coincide); word-aligned addresses and legal byte enables; no
//     request while reset is asserted
//   - no X on control outputs; the trace never shows x0 written with a nonzero value
//
// Interrupt controller (step 2.2d, DECISIONS.md D-035; step 2.2b's flop model is gone)
//   px_clic (64 inputs, 4 level bits) sits on the data port: addresses 0xE000_0000 to
//   0xE000_FFFF go to it with the 16-bit offset, granted in the request cycle and answered
//   in the next cycle in every memory mode (a one-cycle slave; the random grants and
//   latencies of the stress modes apply to the memories). Its winner drives the core's
//   request port, the core's ack/claim and mil/mintthresh/mode drive it back. Inputs 0
//   (machine software interrupt, pending set by a store) and 1 (timer, Phase 4) are tied 0;
//   inputs 2-63 come from the harness words:
//   - IRQTRIG (0x2000_FFD0), a retired word store: after [15:0] cycles (plus a seeded random
//     0-15 if bit 31 is set) input [21:16] is driven so that px_clic's pending flop for it is
//     set at that edge (cycle 0): a one-cycle pulse, or with bit 30 a level held until the
//     program stores the id to IRQCLR (0x2000_FFD4). [27:24] is the expected latency in
//     ideal mode (0: not checked), measured when that id is taken.
//   - AGENT (0x2000_FFD8): a seeded agent on ids [5:0] .. [5:0] + [11:6] - 1 (2-63 only), an
//     event every 2^[15:12] cycles on average; bit 16 = level mode (raise an input and hold
//     it until IRQCLR), else one-cycle pulses; bit 31 enables, 0 stops it.
//   Monitors, every run:
//   - a take only while irq_req_i is high and mstatus.MIE is 1 (O2), acknowledging exactly
//     the presented id (O3); a claim only for a committed mnxti write while the presented
//     winner is valid, not vectored, above mpil and mintthresh, in CLIC mode, for its id
//     (O3); no CSR commit, MRET, data
//     request, multiplier stage-1 load or divide completion in the take cycle
//   - latency (pending flop to the handler's first instruction in EX): exactly the declared
//     value in ideal mode, at least 4 in every mode; every cycle in which the request is
//     eligible but not taken has one of the excluded causes (WB bus error, older access in
//     WB, ungranted request from the previous cycle, exception in EX)
//   - no take over a synchronous exception in EX or a WB bus error (contract § 2.3:
//     exceptions take precedence over maskable interrupts)
//   - coverage of the take point (EX contents and divider cycle at the take) and of each
//     deferral cause (WB bus error, EX exception, older access, ungranted request),
//     reported; every bin must be hit once an interrupt was taken in ideal mode
//   - vectored entry (D-035 items 16-19): the handler of a vectored take is the table word
//     (bit 0 cleared), or the table entry itself when its fetch faults; no take during a
//     table fetch; an MRET with minhv puts the refetched handler in EX 5 cycles after the
//     MRET in ideal mode (unless the entry faults or an interrupt is taken first); bins: the
//     fetch-stage state at a vectored take (nothing outstanding, a response arriving, a
//     granted request without response, an ungranted request, buffer full), a take deferred
//     by a refetch, a table fault, an MRET refetch; every bin must be hit once a vectored
//     take was seen in ideal mode
//   Programs with <name>.replay (built with "px-build: irq") have no static reference:
//   the bench writes every retirement, exception and interrupt of each run in program order
//   to sim/logs/replay_<NAME>_<run>.ev and lists the runs in sim/logs/replay_<NAME>.manifest;
//   the source list's post_check (scripts/px_iss.py --replay) re-executes them with the
//   recorded interrupts. Their trap table lists exceptions only. Since step 2.2d each
//   retirement also carries its CSR side writes, the cycle it left EX (its data grant or
//   CSR commit) and the cycle it retired; interrupts carry their take cycle; every change
//   of the CLIC inputs is a line "X <cycle> <inputs>" (cycles: the bench's edge count at
//   which the event is sampled), so px_iss can model the CLIC independently.
//
// Run: scripts/run_unit.sh tb_core tb/core/tb_core.f   (+only=<program>, +vcd)

`timescale 1ns/1ps

module tb_core #(
  parameter LIST       = "tb/core/programs/list.txt",
  parameter RANDOM_SET = 0,
  parameter NAME       = "tb_core"
);

  localparam logic [31:0] ITCM_BASE = 32'h1000_0000;
  localparam logic [31:0] DTCM_BASE = 32'h2000_0000;
  localparam logic [31:0] DEV_BASE  = 32'h2001_0000;
  localparam int          WORDS     = 16384;
  localparam logic [31:0] TOHOST    = 32'h2000_FFF0;
  localparam logic [31:0] MARKER    = 32'h2000_FFE0;
  localparam logic [31:0] CYCEXP    = 32'h2000_FFE4;
  localparam logic [31:0] CYCCHK    = 32'h2000_FFE8;
  localparam logic [31:0] TRAPTAB   = 32'h2000_F000;
  localparam logic [31:0] IRQTRIG   = 32'h2000_FFD0;
  localparam logic [31:0] IRQCLR    = 32'h2000_FFD4;
  localparam logic [31:0] AGENT     = 32'h2000_FFD8;
  localparam logic [31:0] TRAPVEC   = 32'h1000_0040;
  localparam int          MAX_CYCLES = 400000;
  localparam int          QDEPTH    = 8;
  localparam int          MAXTRAPS  = 1024;
  localparam int          MAX_RUN_ERRORS = 10;

  localparam int MODE_IDEAL = 0, MODE_STRESS = 1, MODE_LONG = 2, MODE_RESET = 3;

  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk;

  logic [31:0] itcm [0:WORDS-1];
  logic [31:0] dtcm [0:WORDS-1];

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic        i_req, i_gnt, i_rvalid, i_err;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_gnt, d_we, d_rvalid, d_err;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic [3:0]  d_be;
  logic        r_valid;
  logic [31:0] r_pc, r_insn, r_rd_wdata, r_mem_addr, r_mem_rdata, r_mem_wdata;
  logic        r_csr_we;
  logic [11:0] r_csr_addr;
  logic [31:0] r_csr_wdata;
  logic [4:0]  r_rd;
  logic [3:0]  r_rmask, r_wmask;
  logic        t_valid, t_irq;
  logic [5:0]  t_cause;
  logic [31:0] t_pc, t_tval;
  logic [3:0]  r_csrx_we;
  logic [127:0] r_csrx_wdata;
  logic        irq_req, irq_ack, irq_valid, irq_shv, claim, cmode;
  logic [5:0]  irq_id, irq_ack_id, claim_id;
  logic [7:0]  irq_level, mil, mthresh;
  // data port as the core sees it: memories (bench model) or the CLIC
  logic        dc_gnt, dc_rvalid, dc_err;
  logic [31:0] dc_rdata;
  logic        c_sel, c_gnt, c_rvalid, c_err;
  logic [31:0] c_rdata;
  logic [63:0] clic_in;

  px_core #(.BOOT_ADDR(ITCM_BASE), .MTVEC_RESET(TRAPVEC)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .instr_req_o(i_req), .instr_gnt_i(i_gnt), .instr_addr_o(i_addr),
    .instr_rvalid_i(i_rvalid), .instr_rdata_i(i_rdata), .instr_err_i(i_err),
    .data_req_o(d_req), .data_gnt_i(dc_gnt), .data_addr_o(d_addr), .data_we_o(d_we),
    .data_be_o(d_be), .data_wdata_o(d_wdata), .data_rvalid_i(dc_rvalid),
    .data_rdata_i(dc_rdata), .data_err_i(dc_err),
    .irq_req_i(irq_req), .irq_valid_i(irq_valid), .irq_id_i(irq_id), .irq_level_i(irq_level),
    .irq_shv_i(irq_shv), .irq_ack_o(irq_ack), .irq_ack_id_o(irq_ack_id),
    .irq_claim_o(claim), .irq_claim_id_o(claim_id),
    .mil_o(mil), .mintthresh_o(mthresh), .clic_mode_o(cmode),
    .trap_irq_o(t_irq),
    .rvfi_valid_o(r_valid), .rvfi_pc_o(r_pc), .rvfi_insn_o(r_insn),
    .rvfi_rd_addr_o(r_rd), .rvfi_rd_wdata_o(r_rd_wdata), .rvfi_mem_addr_o(r_mem_addr),
    .rvfi_mem_rmask_o(r_rmask), .rvfi_mem_wmask_o(r_wmask),
    .rvfi_mem_rdata_o(r_mem_rdata), .rvfi_mem_wdata_o(r_mem_wdata),
    .rvfi_csr_we_o(r_csr_we), .rvfi_csr_addr_o(r_csr_addr), .rvfi_csr_wdata_o(r_csr_wdata),
    .rvfi_csrx_we_o(r_csrx_we), .rvfi_csrx_wdata_o(r_csrx_wdata),
    .trap_valid_o(t_valid), .trap_cause_o(t_cause), .trap_pc_o(t_pc), .trap_tval_o(t_tval)
  );

  // CLIC on the data port (D-035 item 21): granted in the request cycle, one-cycle response
  localparam logic [15:0] CLIC_HI = 16'hE000;
  assign c_sel = d_addr[31:16] == CLIC_HI;
  px_clic #(.NUM_IRQ(64), .LVL_BITS(4)) u_clic (
    .clk_i(clk), .rst_ni(rst_n),
    .irq_i(clic_in),
    .req_i(d_req && c_sel), .gnt_o(c_gnt), .addr_i(d_addr[15:0]), .we_i(d_we), .be_i(d_be),
    .wdata_i(d_wdata), .rvalid_o(c_rvalid), .rdata_o(c_rdata), .err_o(c_err),
    .mil_i(mil), .mintthresh_i(mthresh), .clic_mode_i(cmode),
    .ack_i(irq_ack), .ack_id_i(irq_ack_id), .claim_i(claim), .claim_id_i(claim_id),
    .irq_req_o(irq_req), .irq_valid_o(irq_valid), .irq_id_o(irq_id), .irq_level_o(irq_level),
    .irq_shv_o(irq_shv)
  );
  assign dc_gnt    = c_sel ? c_gnt : d_gnt;
  assign dc_rvalid = d_rvalid || c_rvalid;
  assign dc_rdata  = c_rvalid ? c_rdata : d_rdata;
  assign dc_err    = c_rvalid ? c_err : d_err;

  // ---------------------------------------------------------------------------
  // Memory access helpers
  // ---------------------------------------------------------------------------
  function automatic bit in_itcm(input logic [31:0] a);
    return a >= ITCM_BASE && a < ITCM_BASE + 32'h1_0000;
  endfunction
  function automatic bit in_dtcm(input logic [31:0] a);
    return a >= DTCM_BASE && a < DTCM_BASE + 32'h1_0000;
  endfunction
  function automatic bit is_dev(input logic [31:0] a);
    return a == DEV_BASE || a == DEV_BASE + 32'd4;
  endfunction
  function automatic logic [31:0] lane_mask(input logic [3:0] m);
    return {{8{m[3]}}, {8{m[2]}}, {8{m[1]}}, {8{m[0]}}};
  endfunction

  // ---------------------------------------------------------------------------
  // Port models (shared state machine per port). Updated on the rising edge with
  // nonblocking assignments, so the DUT samples stable values.
  // ---------------------------------------------------------------------------
  int mode;
  int seed;
  int cycle;
  int gap_i, gap_d;              // long mode: remaining cycles without a grant
  int dev_reads, dev_writes;     // side-effect device state

  // instruction port queue
  logic [31:0] iq_data [QDEPTH];
  logic        iq_err  [QDEPTH];
  int          iq_due  [QDEPTH];
  int          iq_head, iq_count, iq_last_due;
  // data port queue
  logic [31:0] dq_data [QDEPTH];
  logic        dq_err  [QDEPTH];
  int          dq_due  [QDEPTH];
  int          dq_head, dq_count, dq_last_due;

  // run results
  logic [31:0] tohost_val;
  bit          tohost_seen;
  bit          tohost_retired;
  int          errors_run;
  int          n_traps;
  logic [4:0]  trap_cause_log [MAXTRAPS];
  logic [31:0] trap_pc_log    [MAXTRAPS];
  logic [31:0] trap_tval_log  [MAXTRAPS];
  int          exp_n;
  logic [31:0] exp_tab [0:3*64];
  int          retired;
  int          last_mark;
  bit          mark_started;
  int          marks_checked;
  logic [31:0] cyc_exp;
  int          cyc_checked;
  int          trace_fd;
  int          ref_fd;
  int          ref_checked;
  int          ref_traps;          // trap count in the reference list (-1: unknown)
  int          last_retire;

  // Interrupt harness and replay (D-033, D-035)
  bit          replay;             // this program is checked by px_iss --replay
  int          ev_fd, man_fd, replay_runs;
  bit          irq_armed, irq_trig_level;
  bit          irq_meas;           // a declared-latency trigger fired and was not taken yet
  int          irq_cnt;            // cycles until the trigger fires
  int          irq_t0;             // edge at which the pending flop of the trigger is set
  int          irq_lat_exp;        // declared latency (ideal mode), 0 = not checked
  logic [5:0]  irq_trig_id;
  logic [63:0] h_pulse, h_level, a_pulse, a_level;   // harness and agent inputs
  bit          agent_on, agent_lvl;
  int          agent_base, agent_n, agent_rate;
  logic [63:0] x_last;             // last logged input vector
  int          exq [$];            // cycles in which the instructions now in WB left EX
  int          n_claims, total_claims;
  bit          irq_wait_ex;        // a take happened, waiting for the handler in EX
  logic [31:0] irq_target;
  int          n_irqs, total_irqs, lat_checked, lat_min, lat_max;
  int          run_lat_n, run_lat_min, run_lat_max, run_lat_exact;   // per run
  // coverage of the take point: EX contents at the take, divider cycle at the take
  // 0 nothing in ID/EX, 1 ID only, 2 other instruction in EX, 3 load, 4 store, 5 MUL, 6 DIV,
  // 7 CSR instruction, 8 MRET, 9 taken branch, 10 JALR, 11 FENCE.I, 12 JAL in ID
  localparam int COV_EX = 13;
  int          cov_ex [COV_EX];
  int          cov_div [1:17];
  int          cov_defer [4];   // eligible but deferred: WB bus error, EX exception, older access, ungranted request
  // vectored entry (D-035 item 17): fetch-stage state at a vectored take (0 nothing
  // outstanding, 1 a response arriving, 2 a granted request without response, 3 a raised
  // request not granted, 4 buffer full), 5 a take deferred by a table fetch (MRET refetch),
  // 6 a table fetch fault, 7 an MRET refetch; checked once a vectored take was seen in ideal mode
  localparam int COV_VEC = 8;
  int          cov_vec [COV_VEC];
  bit          vec_ideal_seen;
  bit          mr_wait;            // an MRET refetch is in progress
  int          mr_t0;
  logic [31:0] mr_tbl, mr_target;
  bit          irq_ideal_seen;

  // OBI stability tracking
  bit          i_pend, d_pend;
  logic [31:0] i_pend_addr, d_pend_addr, d_pend_wdata;
  logic        d_pend_we;
  logic [3:0]  d_pend_be;

  task automatic run_error(input string msg);
    errors_run++;
    if (errors_run <= 10) $display("ERROR cycle %0d: %s", cycle, msg);
  endtask

  function automatic int latency();
    if (mode == MODE_IDEAL) return 1;
    if (mode == MODE_LONG)  return 1 + ($urandom(seed) % 8);
    return 1 + ($urandom(seed) % 3);
  endfunction

  // (Icarus 12 functions take input arguments only: the gap counters are module state)
  function automatic bit grant_next(input bit port_i);
    int gap;
    bit g;
    if (mode == MODE_IDEAL) return 1'b1;
    if (mode != MODE_LONG) return ($urandom(seed) % 4) != 0;
    gap = port_i ? gap_i : gap_d;
    if (gap > 0) begin
      gap--;
      g = 1'b0;
    end else begin
      if (($urandom(seed) % 16) == 0) gap = $urandom(seed) % 40;
      g = ($urandom(seed) % 3) != 0;
    end
    if (port_i) gap_i = gap; else gap_d = gap;
    return g;
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      iq_head <= 0; iq_count <= 0; iq_last_due <= 0;
      dq_head <= 0; dq_count <= 0; dq_last_due <= 0;
      i_rvalid <= 1'b0; d_rvalid <= 1'b0;
      i_err <= 1'b0; d_err <= 1'b0;
      i_gnt <= 1'b1; d_gnt <= 1'b1;
      i_pend <= 1'b0; d_pend <= 1'b0;
      gap_i = 0; gap_d = 0;
      cycle <= 0;
    end else begin
      int          ih, ic, dh, dc, ild, dld, due;
      logic [31:0] word, a;
      logic        err;
      bit          noisy;

      ih = iq_head; ic = iq_count; ild = iq_last_due;
      dh = dq_head; dc = dq_count; dld = dq_last_due;

      // ---- OBI rule checks (values seen during this cycle) ----
      if (i_pend && (!i_req || i_addr !== i_pend_addr))
        run_error("instruction request dropped or changed before grant");
      if (d_pend && (!d_req || d_addr !== d_pend_addr || d_we !== d_pend_we ||
                     d_be !== d_pend_be || (d_we && d_wdata !== d_pend_wdata)))
        run_error("data request dropped or changed before grant");
      if (i_req && i_addr[1:0] != 2'b00)
        run_error($sformatf("instruction address %08h not word aligned", i_addr));
      if (d_req && d_addr[1:0] != 2'b00)
        run_error($sformatf("data address %08h not word aligned", d_addr));
      // (Icarus 12 has no `inside`)
      if (d_req && d_be != 4'b0001 && d_be != 4'b0010 && d_be != 4'b0100 && d_be != 4'b1000 &&
          d_be != 4'b0011 && d_be != 4'b1100 && d_be != 4'b1111)
        run_error($sformatf("illegal byte enables %b", d_be));
      // One outstanding request per port (contract §3.2): a grant is only allowed when
      // nothing is outstanding or the outstanding response arrives in the same cycle.
      if (i_req && i_gnt && (ic - (i_rvalid ? 1 : 0)) != 0)
        run_error($sformatf("instruction port: grant with %0d request(s) outstanding", ic - (i_rvalid ? 1 : 0)));
      // (a CLIC request is answered in the next cycle: c_rvalid marks it outstanding)
      if (d_req && dc_gnt && (dc + (c_rvalid ? 1 : 0) - (dc_rvalid ? 1 : 0)) != 0)
        run_error($sformatf("data port: grant with %0d request(s) outstanding", dc + (c_rvalid ? 1 : 0) - (dc_rvalid ? 1 : 0)));
      if (c_rvalid && d_rvalid) run_error("CLIC and memory responses in the same cycle");
      i_pend <= i_req && !i_gnt;  i_pend_addr <= i_addr;
      d_pend <= d_req && !dc_gnt; d_pend_addr <= d_addr;
      d_pend_we <= d_we; d_pend_be <= d_be; d_pend_wdata <= d_wdata;

      // ---- responses consumed this cycle ----
      if (i_rvalid) begin ih = (ih + 1) % QDEPTH; ic--; end
      if (d_rvalid) begin dh = (dh + 1) % QDEPTH; dc--; end

      // ---- requests granted this cycle ----
      if (i_req && i_gnt) begin
        a   = i_addr;
        err = !in_itcm(a);
        word = err ? 32'hDEAD_BEEF : itcm[(a - ITCM_BASE) >> 2];
        due = cycle + latency();
        if (due <= ild) due = ild + 1;
        iq_data[(ih + ic) % QDEPTH] = word; iq_err[(ih + ic) % QDEPTH] = err;
        iq_due[(ih + ic) % QDEPTH] = due; ic++; ild = due;
        if (ic > QDEPTH) run_error("instruction queue overflow");
      end
      if (d_req && d_gnt && !c_sel) begin
        a   = d_addr;
        err = !(in_itcm(a) || in_dtcm(a) || is_dev(a));
        word = 32'h0;
        if (!err) begin
          if (a == DEV_BASE) begin
            if (!d_we) begin word = dev_reads; dev_reads++; end
          end else if (a == DEV_BASE + 32'd4) begin
            if (d_we) dev_writes++;
            else      word = dev_writes;
          end else begin
            if (in_itcm(a)) word = itcm[(a - ITCM_BASE) >> 2];
            else            word = dtcm[(a - DTCM_BASE) >> 2];
            if (d_we) begin
              for (int b = 0; b < 4; b++)
                if (d_be[b]) word[8*b +: 8] = d_wdata[8*b +: 8];
              if (in_itcm(a)) itcm[(a - ITCM_BASE) >> 2] = word;
              else            dtcm[(a - DTCM_BASE) >> 2] = word;
              if (a == TOHOST) begin tohost_val = d_wdata; tohost_seen = 1'b1; end
            end
          end
        end
        due = cycle + latency();
        if (due <= dld) due = dld + 1;
        dq_data[(dh + dc) % QDEPTH] = d_we ? 32'h0 : word; dq_err[(dh + dc) % QDEPTH] = err;
        dq_due[(dh + dc) % QDEPTH] = due; dc++; dld = due;
        if (dc > QDEPTH) run_error("data queue overflow");
      end

      // ---- outputs for the next cycle ----
      // Outside ideal mode, data and error inputs carry garbage while rvalid is low:
      // the core may only look at them together with rvalid.
      noisy = (mode != MODE_IDEAL);
      i_rvalid <= (ic > 0) && (iq_due[ih] <= cycle + 1);
      d_rvalid <= (dc > 0) && (dq_due[dh] <= cycle + 1);
      if ((ic > 0) && (iq_due[ih] <= cycle + 1)) begin
        i_rdata <= iq_data[ih]; i_err <= iq_err[ih];
      end else begin
        i_rdata <= noisy ? $urandom(seed) : 32'hx;
        i_err   <= noisy ? $urandom(seed) % 2 : 1'b0;
      end
      if ((dc > 0) && (dq_due[dh] <= cycle + 1)) begin
        d_rdata <= dq_data[dh]; d_err <= dq_err[dh];
      end else begin
        d_rdata <= noisy ? $urandom(seed) : 32'hx;
        d_err   <= noisy ? $urandom(seed) % 2 : 1'b0;
      end
      i_gnt <= grant_next(1'b1);
      d_gnt <= grant_next(1'b0);

      iq_head <= ih; iq_count <= ic; iq_last_due <= ild;
      dq_head <= dh; dq_count <= dc; dq_last_due <= dld;
      cycle   <= cycle + 1;
    end
  end

  // No request while reset is asserted.
  always @(negedge clk)
    if (!rst_n && (i_req || d_req)) run_error("request while reset is asserted");

  // ---------------------------------------------------------------------------
  // Interrupt harness (D-033, D-035): drives the CLIC inputs. A trigger "fires" at the edge
  // that drives its input, so px_clic's pending flop for it is set at the next edge (cycle 0
  // of the latency). `cycle` (old value) is the number of the current edge.
  // ---------------------------------------------------------------------------
  assign clic_in = (h_pulse | h_level | a_pulse | a_level) & ~64'h3;   // inputs 0 and 1 tied 0

  task automatic trig_fire();
    if (irq_trig_level) h_level[irq_trig_id] <= 1'b1;
    else                h_pulse[irq_trig_id] <= 1'b1;
    irq_t0   = cycle + 1;
    irq_meas = 1'b1;
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      h_pulse <= '0; h_level <= '0; a_pulse <= '0; a_level <= '0;
      irq_armed = 1'b0; irq_meas = 1'b0; agent_on = 1'b0;
    end else begin
      h_pulse <= '0;                               // pulses last one cycle
      a_pulse <= '0;
      if (irq_armed) begin
        if (irq_cnt == 0) begin trig_fire(); irq_armed = 1'b0; end
        else irq_cnt = irq_cnt - 1;
      end
      if (r_valid && r_wmask == 4'b1111 && !tohost_retired) begin
        if (r_mem_addr == IRQTRIG) begin
          if (irq_armed || (irq_meas && irq_lat_exp != 0))
            run_error("interrupt trigger while a previous trigger with a declared latency is pending");
          irq_cnt        = int'(r_mem_wdata[15:0]) + (r_mem_wdata[31] ? int'($urandom(seed) % 16) : 0);
          irq_trig_id    = r_mem_wdata[21:16];
          irq_trig_level = r_mem_wdata[30];
          irq_lat_exp    = int'(r_mem_wdata[27:24]);
          if (irq_trig_id < 6'd2) run_error("interrupt trigger on a tied input (id 0 or 1)");
          if (irq_cnt == 0) trig_fire();
          else begin irq_cnt = irq_cnt - 1; irq_armed = 1'b1; end
        end
        if (r_mem_addr == IRQCLR) begin
          h_level[r_mem_wdata[5:0]] <= 1'b0;
          a_level[r_mem_wdata[5:0]] <= 1'b0;
        end
        if (r_mem_addr == AGENT) begin
          agent_on   = r_mem_wdata[31];
          agent_lvl  = r_mem_wdata[16];
          agent_base = int'(r_mem_wdata[5:0]);
          agent_n    = int'(r_mem_wdata[11:6]);
          agent_rate = int'(r_mem_wdata[15:12]);
          if (agent_on && (agent_base < 2 || agent_n == 0 || agent_base + agent_n > 64))
            run_error("agent id range outside inputs 2-63");
        end
      end
      // seeded agent: an event every 2^rate cycles on average on a random id of its range
      if (agent_on && agent_n != 0 && ($urandom(seed) % (1 << agent_rate)) == 0) begin
        int id;
        id = agent_base + int'($urandom(seed) % agent_n);
        if (agent_lvl) a_level[id] <= 1'b1;
        else           a_pulse[id] <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Retirement and trap monitors
  // ---------------------------------------------------------------------------
  task automatic check_ref();
    logic [31:0] e_pc, e_insn, e_wd, e_ma, e_md, e_care, e_cd, e_ccare;
    logic [11:0] e_ca;
    int          e_rd, e_cw, n;
    logic [3:0]  e_rm, e_wm;
    logic [31:0] got_md, lm;
    logic [3:0]  e_sx;
    logic [31:0] e_s0, e_s1, e_s2, e_s3;
    if (ref_fd != 0) begin
      n = $fscanf(ref_fd, "%h %h %d %h %h %h %h %h %h %d %h %h %h %h %h %h %h %h\n", e_pc, e_insn, e_rd, e_wd, e_ma,
                  e_rm, e_wm, e_md, e_care, e_cw, e_ca, e_cd, e_ccare, e_sx, e_s0, e_s1, e_s2, e_s3);
      if (n != 18)
        run_error($sformatf("retired pc %08h beyond the end of the reference trace", r_pc));
      else begin
        ref_checked++;
        lm     = lane_mask(r_rmask | r_wmask);
        got_md = (r_rmask != 4'd0) ? r_mem_rdata : r_mem_wdata;
        if (r_pc !== e_pc || r_insn !== e_insn || r_rd !== e_rd[4:0] ||
            (r_rd_wdata & e_care) !== (e_wd & e_care) ||
            r_rmask !== e_rm || r_wmask !== e_wm ||
            ((r_rmask | r_wmask) != 4'd0 &&
             (r_mem_addr !== e_ma || (got_md & lm & e_care) !== (e_md & lm & e_care))))
          run_error($sformatf("retirement %0d differs from reference: pc %08h insn %08h x%0d=%08h mem %08h r%h w%h %08h; expected pc %08h insn %08h x%0d=%08h mem %08h r%h w%h %08h",
                              ref_checked, r_pc, r_insn, r_rd, r_rd_wdata, r_mem_addr, r_rmask, r_wmask, got_md,
                              e_pc, e_insn, e_rd, e_wd, e_ma, e_rm, e_wm, e_md));
        else if (r_csr_we !== e_cw[0] ||
                 (e_cw != 0 && (r_csr_addr !== e_ca || (r_csr_wdata & e_ccare) !== (e_cd & e_ccare))))
          run_error($sformatf("retirement %0d (pc %08h) CSR write differs from reference: we %0d csr %03h = %08h; expected we %0d csr %03h = %08h",
                              ref_checked, r_pc, r_csr_we, r_csr_addr, r_csr_wdata, e_cw, e_ca, e_cd));
        else if (r_csrx_we !== e_sx || (e_sx[0] && r_csrx_wdata[31:0] !== e_s0) ||
                 (e_sx[1] && r_csrx_wdata[63:32] !== e_s1) || (e_sx[2] && r_csrx_wdata[95:64] !== e_s2) ||
                 (e_sx[3] && r_csrx_wdata[127:96] !== e_s3))
          run_error($sformatf("retirement %0d (pc %08h) CSR side writes %b %h differ from reference %b %08h %08h %08h %08h",
                              ref_checked, r_pc, r_csrx_we, r_csrx_wdata, e_sx, e_s0, e_s1, e_s2, e_s3));
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      // No X on control outputs, ever: undefined bus data must not reach control.
      // (XOR reduction: Icarus 12's $isunknown misreports concatenations)
      if ((^{i_req, d_req, r_valid, t_valid}) === 1'bx ||
          (i_req && (^i_addr) === 1'bx) ||
          (d_req && (^{d_addr, d_we, d_be}) === 1'bx) ||
          (d_req && d_we && (^d_wdata) === 1'bx))
        run_error("X on a core control output");
      if (r_valid) begin
        last_retire = cycle;
        if (!tohost_retired) begin
          retired++;
          if (replay && ev_fd != 0)
            $fwrite(ev_fd, "R %08h %08h %0d %08h %08h %h %h %08h %0d %03h %08h %h %08h %08h %08h %08h %0d %0d\n",
                    r_pc, r_insn, r_rd, r_rd_wdata, r_mem_addr, r_rmask, r_wmask,
                    (r_rmask != 4'd0) ? r_mem_rdata : r_mem_wdata, r_csr_we, r_csr_addr, r_csr_wdata,
                    r_csrx_we, r_csrx_wdata[31:0], r_csrx_wdata[63:32], r_csrx_wdata[95:64],
                    r_csrx_wdata[127:96], (exq.size() != 0) ? exq[0] : -1, cycle);
          else
            check_ref();
        end
        if (r_wmask != 4'd0 && r_mem_addr == TOHOST && !tohost_retired) begin
          tohost_retired = 1'b1;
          if (r_mem_wdata != 32'd1)
            run_error($sformatf("tohost store retired with %08h", r_mem_wdata));
        end
        if (r_rd == 5'd0 && r_rd_wdata !== 32'd0) run_error("x0 written with a nonzero value");
        if (trace_fd != 0)
          $fwrite(trace_fd, "%08h %08h x%0d=%08h\n", r_pc, r_insn, r_rd, r_rd_wdata);
        if (r_wmask == 4'b1111 && r_mem_addr == CYCEXP) cyc_exp = r_mem_wdata;
        if (r_wmask == 4'b1111 && r_mem_addr == CYCCHK && !tohost_retired) begin
          cyc_checked++;
          // (no string ternary: it crashes Icarus 12)
          if (mode == MODE_IDEAL && r_mem_wdata !== cyc_exp)
            run_error($sformatf("cycle check %0d: measured %0d, expected %0d (pc %08h)",
                                cyc_checked, r_mem_wdata, cyc_exp, r_pc));
          if (mode != MODE_IDEAL && r_mem_wdata < cyc_exp)
            run_error($sformatf("cycle check %0d: measured %0d, expected at least %0d (pc %08h)",
                                cyc_checked, r_mem_wdata, cyc_exp, r_pc));
        end
        if (r_wmask != 4'd0 && r_mem_addr == MARKER) begin
          if (mode == MODE_IDEAL && mark_started && r_mem_wdata[7:0] != 8'd0) begin
            marks_checked++;
            if (cycle - last_mark != int'(r_mem_wdata[31:8]))
              run_error($sformatf("timing marker %0d: %0d cycles, expected %0d (pc %08h)",
                                  r_mem_wdata[7:0], cycle - last_mark, r_mem_wdata[31:8], r_pc));
          end
          mark_started = 1'b1;
          last_mark    = cycle;
        end
      end
      // A CSR access, MRET, multiply or divide leaves EX only when nothing traps in the
      // same cycle, and the divider runs only for a divide that is valid in EX.
      if (t_valid && (dut.csr_commit || dut.mret_commit || dut.div_accept ||
                      (dut.ex_to_wb && dut.ex_is_mul)))
        run_error("CSR commit, MRET or multiply/divide completion in the same cycle as a trap");
      if (dut.div_busy && !(dut.ex_valid_q && dut.ex_is_div))
        run_error("divider running without a divide in EX");
      if (t_valid && !t_irq && !tohost_retired && ref_traps >= 0 && n_traps >= ref_traps)
        run_error($sformatf("trap %0d (cause %0d pc %08h) beyond the %0d traps of the reference model",
                            n_traps + 1, t_cause, t_pc, ref_traps));
      if (t_valid && !t_irq && !tohost_retired) begin
        if (n_traps < MAXTRAPS) begin
          trap_cause_log[n_traps] = t_cause;
          trap_pc_log[n_traps]    = t_pc;
          trap_tval_log[n_traps]  = t_tval;
        end
        n_traps++;
        if (replay && ev_fd != 0) $fwrite(ev_fd, "T %0d %08h %08h\n", t_cause, t_pc, t_tval);
      end

      // ---- interrupt take point (D-033) and CLIC interface rules (D-034 O2, O3) ----
      if (t_irq !== irq_ack) run_error("trap_irq_o and irq_ack_o differ");
      if (claim) begin
        // a claim only for a committed mnxti write that found the presented winner, its id
        if (!(dut.csr_commit && dut.ex_csr_addr == 12'h345 && dut.ex_dec_q.csr_write) || !irq_valid ||
            irq_shv || !cmode || claim_id !== irq_id || irq_level <= dut.u_csr.u_clic.mpil_q ||
            irq_level <= mthresh)
          run_error($sformatf("claim of id %0d without a committed mnxti write and an eligible presented winner (valid %b id %0d level %02h shv %b)",
                              claim_id, irq_valid, irq_id, irq_level, irq_shv));
        if (irq_ack) run_error("claim and take in the same cycle");
        if (!tohost_retired) n_claims++;
      end
      // vector table fetch (D-035 item 17): once the table request is granted no other
      // instruction request until its response; none while a table fault is pending
      if (i_req && !dut.if_redirect &&
          ((dut.u_if.vstate_q == 2'd1 && dut.u_if.vreq_q) || dut.u_if.vstate_q == 2'd3))
        run_error("instruction request while the vector table word is awaited or faulted");
      if (irq_ack) begin
        if (!irq_req || !dut.csr_mie)
          run_error("interrupt taken without an eligible request");
        if (irq_ack_id !== irq_id) run_error("acknowledged id differs from the request");
        if (!t_valid || t_cause !== irq_id || t_tval !== 32'd0)
          run_error($sformatf("take reported as valid %b cause %0d tval %08h", t_valid, t_cause, t_tval));
        if (dut.if_vec_busy)
          run_error("interrupt taken during a vector table fetch");
        mr_wait = 1'b0;                  // an interrupt right after an MRET refetch: the
                                         // handler of the take is checked instead
        if (dut.csr_commit || dut.mret_commit || d_req || dut.u_mul.en_i ||
            dut.div_accept)
          run_error("CSR commit, MRET, data request, multiply or divide completion in a take cycle");
        // contract § 2.3: synchronous exceptions (and an older access fault) take precedence
        if ((dut.ex_valid_q && dut.ex_exc) || dut.wb_bus_err)
          run_error("interrupt taken over a synchronous exception or a WB bus error");
        // coverage
        if (dut.ex_valid_q) begin
          if (dut.ex_is_div) begin
            cov_ex[6]++;
            cov_div[dut.u_div.active_q ? int'(dut.u_div.cnt_q) + 1 : 1]++;
          end
          else if (dut.ex_is_mul)              cov_ex[5]++;
          else if (dut.ex_dec_q.is_load)       cov_ex[3]++;
          else if (dut.ex_dec_q.is_store)      cov_ex[4]++;
          else if (dut.ex_dec_q.csr_en)        cov_ex[7]++;
          else if (dut.ex_dec_q.is_mret)       cov_ex[8]++;
          else if (dut.br_taken)               cov_ex[9]++;
          else if (dut.ex_dec_q.is_jalr)       cov_ex[10]++;
          else if (dut.ex_dec_q.is_fence_i)    cov_ex[11]++;
          else                                 cov_ex[2]++;
        end else if (dut.id_valid_q)           cov_ex[1]++;
        else                                   cov_ex[0]++;
        if (dut.id_valid_q && dut.dec.is_jal)  cov_ex[12]++;
        if (mode == MODE_IDEAL) irq_ideal_seen = 1'b1;
        if (!tohost_retired) begin
          n_irqs++;
          if (replay && ev_fd != 0) $fwrite(ev_fd, "I %0d %08h %0d\n", irq_id, t_pc, cycle);
        end
        // vectored take: fetch-stage state (coverage)
        if (irq_shv) begin
          if (mode == MODE_IDEAL) vec_ideal_seen = 1'b1;
          if (dut.u_if.count_q == 2'd3)                cov_vec[4]++;
          if (i_req && !i_gnt)                         cov_vec[3]++;
          else if (i_rvalid)                           cov_vec[1]++;
          else if (dut.u_if.outst_q != 2'd0)           cov_vec[2]++;
          else                                         cov_vec[0]++;
          if (!in_itcm(dut.csr_tbl_addr))              cov_vec[6]++;
        end
        // latency is measured for the trigger's own id; the handler is at NBASE, or (vectored)
        // at the table word with bit 0 cleared; a faulting table fetch delivers the entry
        // itself (pc = the table address) to EX
        if (irq_meas && irq_ack_id == irq_trig_id) begin
          irq_wait_ex = 1'b1;
          irq_meas    = 1'b0;
          if (!irq_shv)                       irq_target = dut.csr_mtvec;
          else if (in_itcm(dut.csr_tbl_addr)) irq_target = itcm[(dut.csr_tbl_addr - ITCM_BASE) >> 2] & 32'hFFFF_FFFE;
          else                                irq_target = dut.csr_tbl_addr;
        end
      end else if (irq_req && dut.csr_mie) begin
        // eligible but deferred: count each cause (coverage), any other reason is an error
        if (dut.wb_bus_err)                    cov_defer[0]++;
        if (dut.ex_valid_q && dut.ex_exc)      cov_defer[1]++;
        if (dut.hold_older)                    cov_defer[2]++;
        if (dut.dreq_pend_q)                   cov_defer[3]++;
        if (dut.if_vec_busy)                   cov_vec[5]++;
        if (!(dut.wb_bus_err || dut.hold_older || dut.dreq_pend_q || (dut.ex_valid_q && dut.ex_exc) ||
              dut.if_vec_busy))
          run_error("eligible interrupt not taken, and no excluded condition holds");
      end
      if (irq_wait_ex && !irq_ack && dut.ex_valid_q) begin
        int lat;
        irq_wait_ex = 1'b0;
        lat = cycle - 1 - irq_t0;          // EX was loaded at the previous edge
        if (dut.ex_pc_q !== irq_target)
          run_error($sformatf("first instruction in EX after a take at %08h, handler at %08h",
                              dut.ex_pc_q, irq_target));
        if (lat < 4)
          run_error($sformatf("interrupt latency %0d cycles, below the minimum of 4", lat));
        if (mode == MODE_IDEAL && irq_lat_exp != 0 && lat != irq_lat_exp)
          run_error($sformatf("interrupt latency %0d cycles, expected %0d (handler %08h)",
                              lat, irq_lat_exp, irq_target));
        lat_checked++;
        if (lat < lat_min) lat_min = lat;
        if (lat > lat_max) lat_max = lat;
        run_lat_n++;
        if (lat < run_lat_min) run_lat_min = lat;
        if (lat > run_lat_max) run_lat_max = lat;
        if (mode == MODE_IDEAL && irq_lat_exp != 0 && lat == irq_lat_exp) run_lat_exact++;
      end
      // MRET with minhv (D-035 item 19): the table entry at mepc & ~3 is refetched; the
      // handler (or the faulting entry) is in EX 5 cycles after the MRET (ideal mode)
      if (mr_wait && dut.ex_valid_q) begin
        int lat;
        mr_wait = 1'b0;
        lat = cycle - mr_t0;
        if (dut.ex_pc_q !== mr_target)
          run_error($sformatf("first instruction in EX after an MRET refetch at %08h, handler at %08h",
                              dut.ex_pc_q, mr_target));
        // (a faulting refetch delivers the entry itself one cycle earlier: not checked)
        if (mode == MODE_IDEAL && in_itcm(mr_tbl) && lat != 5)
          run_error($sformatf("MRET refetch latency %0d cycles, expected 5", lat));
      end
      if (dut.mret_vec) begin
        cov_vec[7]++;
        mr_wait = 1'b1;
        mr_t0   = cycle;
        mr_tbl  = dut.csr_mepc & 32'hFFFF_FFFC;
        mr_target = in_itcm(mr_tbl) ? itcm[(mr_tbl - ITCM_BASE) >> 2] & 32'hFFFF_FFFE : mr_tbl;
        if (!in_itcm(mr_tbl)) cov_vec[6]++;
      end
      // EX-leave stamps for the replay log (after the retirement above has used exq[0])
      if ((r_valid || dut.wb_bus_err) && exq.size() != 0) begin
        int dmy;
        dmy = exq.pop_front();
      end
      if (dut.ex_to_wb) exq.push_back(cycle);
      if (exq.size() > 2) run_error("more than two instructions between EX and retirement");
    end
  end

  // ---------------------------------------------------------------------------
  // Replay stamps (D-035 item 22): the cycle in which each instruction left EX (pushed when
  // it moves to WB, popped when it retires or traps in WB), and every change of the CLIC
  // inputs. A take, an EX trap or a WB bus error never leaves an entry behind: only
  // instructions that reach WB are pushed, and each of them leaves WB once.
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      exq.delete();
      x_last = '0;
    end else begin
      if (clic_in !== x_last) begin
        if (replay && ev_fd != 0 && !tohost_retired) $fwrite(ev_fd, "X %0d %016h\n", cycle, clic_in);
        x_last = clic_in;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Exactly-once data accesses (audit D-08): every granted data request leaves the core
  // exactly once, in order, either as the retirement of that access (same word address,
  // byte lanes and direction) or as an access-fault trap on its address; nothing else
  // retires with a memory access. Checked for every instruction of every run. A reset
  // discards accesses in flight; the end of a run requires none outstanding.
  // ---------------------------------------------------------------------------
  localparam int XO_DEPTH = 4;
  logic [31:0] xo_addr [0:XO_DEPTH-1];
  logic [3:0]  xo_be   [0:XO_DEPTH-1];
  logic        xo_we   [0:XO_DEPTH-1];
  int          xo_n, xo_checked;

  task automatic xo_pop();
    for (int k = 0; k < XO_DEPTH - 1; k++) begin
      xo_addr[k] = xo_addr[k + 1]; xo_be[k] = xo_be[k + 1]; xo_we[k] = xo_we[k + 1];
    end
    xo_n--;
    xo_checked++;
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      xo_n = 0;
    end else begin
      // older events first: a response and the next grant may share a cycle
      if (r_valid && (r_rmask | r_wmask) != 4'd0) begin
        if (xo_n == 0)
          run_error($sformatf("pc %08h retired a memory access that was never granted", r_pc));
        else begin
          if (r_mem_addr[31:2] !== xo_addr[0][31:2] || (r_rmask | r_wmask) !== xo_be[0] ||
              (r_wmask != 4'd0) !== xo_we[0])
            run_error($sformatf("pc %08h retired access %08h be %h we %0d, oldest granted access was %08h be %h we %0d",
                                r_pc, r_mem_addr, r_rmask | r_wmask, r_wmask != 4'd0,
                                xo_addr[0], xo_be[0], xo_we[0]));
          xo_pop();
        end
      end
      if (t_valid && dut.wb_bus_err) begin
        if (xo_n == 0)
          run_error($sformatf("bus-error trap at pc %08h without a granted access", t_pc));
        else begin
          if ((t_cause != 5'd5 && t_cause != 5'd7) || (t_cause == 5'd7) !== xo_we[0] ||
              t_tval[31:2] !== xo_addr[0][31:2])
            run_error($sformatf("bus-error trap cause %0d tval %08h, oldest granted access was %08h we %0d",
                                t_cause, t_tval, xo_addr[0], xo_we[0]));
          xo_pop();
        end
      end
      if (d_req && dc_gnt) begin
        if (xo_n == XO_DEPTH) run_error("more than 4 data accesses in flight");
        else begin
          xo_addr[xo_n] = d_addr; xo_be[xo_n] = d_be; xo_we[xo_n] = d_we;
          xo_n++;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Program runner
  // ---------------------------------------------------------------------------
  int total_errors = 0;
  int runs = 0;
  int total_ref = 0;

  task automatic load_program(input string name);
    int base;
    for (int k = 0; k < WORDS; k++) begin itcm[k] = 32'd0; dtcm[k] = 32'd0; end
    $readmemh({"tb/core/programs/", name, ".itcm.hex"}, itcm);
    $readmemh({"tb/core/programs/", name, ".dtcm.hex"}, dtcm);
    // Expected-trap table, copied before the program can overwrite it.
    base  = (TRAPTAB - DTCM_BASE) >> 2;
    exp_n = int'(dtcm[base]);
    for (int k = 0; k < 3 * 64; k++) exp_tab[k] = dtcm[base + 1 + k];
    dev_reads = 0; dev_writes = 0;
  endtask

  task automatic open_trace(input string name);
    if (trace_fd != 0) $fclose(trace_fd);
    if (ref_fd != 0) $fclose(ref_fd);
    // (a ternary between strings inside the concatenation crashes Icarus 12)
    if (mode == MODE_IDEAL) trace_fd = $fopen({"sim/logs/core_", name, ".trace"}, "w");
    else                    trace_fd = 0;
    // Interrupt programs (D-033) are checked by px_iss --replay from an event log instead
    // of a static reference.
    begin
      int rfd2;
      rfd2   = $fopen({"tb/core/programs/", name, ".replay"}, "r");
      replay = (rfd2 != 0);
      if (rfd2 != 0) $fclose(rfd2);
    end
    if (ev_fd != 0) $fclose(ev_fd);
    ev_fd = 0;
    if (replay) begin
      ref_fd = 0;
      ev_fd  = $fopen($sformatf("sim/logs/replay_%s_%0d.ev", NAME, replay_runs), "w");
      if (ev_fd == 0) run_error("cannot write the replay event log");
    end else begin
      ref_fd = $fopen({"tb/core/programs/", name, ".trace.ref"}, "r");
      if (ref_fd == 0) run_error({"missing reference trace for ", name});
    end
    ref_checked = 0;
    n_irqs = 0; irq_wait_ex = 1'b0; n_claims = 0; mr_wait = 1'b0;
    run_lat_n = 0; run_lat_min = 1 << 30; run_lat_max = 0; run_lat_exact = 0;
    begin
      int tfd;
      ref_traps = -1;
      tfd = $fopen({"tb/core/programs/", name, ".traps.ref"}, "r");
      if (tfd != 0) begin
        if ($fscanf(tfd, "%d", ref_traps) != 1) ref_traps = -1;
        $fclose(tfd);
      end
    end
    tohost_seen = 1'b0; tohost_retired = 1'b0; tohost_val = 32'd0;
    n_traps = 0; retired = 0; last_retire = 0;
    mark_started = 1'b0; marks_checked = 0; last_mark = 0;
    cyc_exp = 32'hFFFF_FFFF; cyc_checked = 0;
  endtask

  task automatic run_program(input string name, input int mode_i, input int seed_i);
    string       mname;
    int          rfd, rn, ref_n, reset_at;
    int          c_ref;
    logic [31:0] p_ref, t_ref;
    case (mode_i)
      MODE_IDEAL:  mname = "ideal";
      MODE_STRESS: mname = "stress";
      MODE_LONG:   mname = "long";
      default:     mname = "reset";
    endcase

    mode = mode_i;
    seed = seed_i;
    errors_run = 0;
    load_program(name);
    open_trace(name);

    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    if (mode_i == MODE_RESET) begin
      // Asynchronous reset at a random point, between clock edges, while traffic is in
      // flight; then reload the program and run it from the start.
      reset_at = 20 + ($urandom(seed) % 400);
      while (cycle < reset_at && !tohost_seen) @(posedge clk);
      #3;
      rst_n = 1'b0;
      #1;
      if (i_req || d_req) run_error("request still raised after reset assertion");
      repeat (2) @(posedge clk);
      load_program(name);
      open_trace(name);
      @(negedge clk);
      rst_n = 1'b1;
    end

    // Stop at tohost, at the cycle limit, when nothing has retired for 2000 cycles, or
    // after MAX_RUN_ERRORS errors (fail fast).
    while (!tohost_retired && cycle < MAX_CYCLES && (cycle - last_retire) < 2000 &&
           errors_run < MAX_RUN_ERRORS) @(posedge clk);
    if (errors_run >= MAX_RUN_ERRORS)
      $display("ERROR run stopped after %0d errors (cycle %0d)", errors_run, cycle);
    if (!tohost_retired && (cycle - last_retire) >= 2000)
      run_error($sformatf("deadlock: nothing retired since cycle %0d", last_retire));
    repeat (5) @(posedge clk);
    if (xo_n != 0)
      run_error($sformatf("%0d granted data access(es) never retired or trapped", xo_n));
    if (trace_fd != 0) $fclose(trace_fd);
    trace_fd = 0;

    if (!tohost_seen || !tohost_retired)
      run_error("timeout: tohost never written and retired");
    else if (tohost_val != 32'd1)
      run_error($sformatf("program reported failure in test %0d", (tohost_val >> 1) - 1));

    // replay runs: close the event log (its last line states the totals) and list the run
    if (replay && ev_fd != 0) begin
      $fwrite(ev_fd, "E %0d %0d %0d\n", retired, n_traps, n_irqs);
      $fclose(ev_fd);
      ev_fd = 0;
      $fwrite(man_fd, "run sim/logs/replay_%s_%0d.ev %s %s %08h\n", NAME, replay_runs, name, mname, seed_i);
      replay_runs++;
    end
    total_irqs += n_irqs;
    total_claims += n_claims;
    if (irq_wait_ex) run_error("an interrupt was taken but its handler never reached EX");

    // reference trace fully consumed (it ends with the tohost store)
    if (ref_fd != 0) begin
      logic [31:0] dummy;
      if ($fscanf(ref_fd, "%h", dummy) == 1)
        run_error($sformatf("run ended after %0d retirements, reference trace is longer", ref_checked));
      $fclose(ref_fd);
      ref_fd = 0;
    end
    total_ref += ref_checked;

    // expected traps: the program's own table (a count of -1 means the program has no
    // table, as in the generated random programs; the reference list then decides) ...
    if (exp_n != -1 && exp_n != n_traps)
      run_error($sformatf("%0d traps seen, %0d expected by the program table", n_traps, exp_n));
    for (int k = 0; k < exp_n && k < n_traps && k < 64; k++) begin  // table holds up to 64
      if (trap_cause_log[k] != exp_tab[3*k][4:0] || trap_pc_log[k] != exp_tab[3*k + 1] ||
          trap_tval_log[k] != exp_tab[3*k + 2])
        run_error($sformatf("trap %0d: cause %0d pc %08h tval %08h, expected %0d %08h %08h", k,
                            trap_cause_log[k], trap_pc_log[k], trap_tval_log[k],
                            exp_tab[3*k], exp_tab[3*k + 1], exp_tab[3*k + 2]));
    end
    // ... and the reference model's list (replay runs: px_iss --replay checks every trap)
    rfd = replay ? 0 : $fopen({"tb/core/programs/", name, ".traps.ref"}, "r");
    if (replay) ;
    else if (rfd == 0) run_error({"missing reference trap list for ", name});
    else begin
      rn = $fscanf(rfd, "%d\n", ref_n);
      if (rn != 1 || ref_n != n_traps)
        run_error($sformatf("%0d traps seen, %0d in the reference list", n_traps, ref_n));
      for (int k = 0; k < ref_n && k < n_traps && k < MAXTRAPS; k++) begin
        rn = $fscanf(rfd, "%d %h %h\n", c_ref, p_ref, t_ref);
        if (rn != 3 || trap_cause_log[k] != c_ref[4:0] || trap_pc_log[k] != p_ref ||
            trap_tval_log[k] != t_ref)
          run_error($sformatf("trap %0d: cause %0d pc %08h tval %08h, reference %0d %08h %08h", k,
                              trap_cause_log[k], trap_pc_log[k], trap_tval_log[k], c_ref, p_ref, t_ref));
      end
      $fclose(rfd);
    end

    runs++;
    total_errors += errors_run;
    $display("%-6s %-22s %-6s seed %08h  %0d retired, %0d cycles, %0d traps, %0d interrupts, %0d claims, %0d timing marks, %0d cycle checks",
             errors_run == 0 ? "ok" : "FAILED", name, mname, seed_i, retired, cycle, n_traps,
             n_irqs, n_claims, marks_checked, cyc_checked);
    if (run_lat_n != 0)
      $display("       interrupt latency %0d-%0d cycles over %0d takes; %0d exactly as declared (ideal mode)",
               run_lat_min, run_lat_max, run_lat_n, run_lat_exact);
  endtask

  bit stop_on_fail;
  // (Icarus 12: no return in tasks)
  task automatic run_checked(input string name, input int mode_i, input int seed_i);
    if (!(stop_on_fail && total_errors != 0)) run_program(name, mode_i, seed_i);
  endtask

  initial begin
    int    fd;
    string name;
    string only;
    fd = $fopen(LIST, "r");
    if (fd == 0) begin
      $display("FAIL %s (no program list)", NAME);
      $fatal(1, "no program list");
    end
    rst_n = 1'b0;
    trace_fd = 0; ref_fd = 0; ev_fd = 0;
    replay_runs = 0; total_irqs = 0; total_claims = 0; lat_checked = 0; lat_min = 1 << 30; lat_max = 0;
    irq_ideal_seen = 1'b0;
    for (int k = 0; k < COV_EX; k++) cov_ex[k] = 0;
    for (int k = 1; k <= 17; k++) cov_div[k] = 0;
    for (int k = 0; k < 4; k++) cov_defer[k] = 0;
    for (int k = 0; k < COV_VEC; k++) cov_vec[k] = 0;
    vec_ideal_seen = 1'b0;
    man_fd = $fopen($sformatf("sim/logs/replay_%s.manifest", NAME), "w");
    if (man_fd == 0) begin
      $display("FAIL %s (cannot write the replay manifest)", NAME);
      $fatal(1, "no manifest");
    end
    // +only=<program> runs a single program (debugging); +vcd dumps a waveform.
    if (!$value$plusargs("only=%s", only)) only = "";
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_core.vcd");
      $dumpvars(0, tb_core);
    end
    // +stop_on_fail ends the bench after the first failing run (used by scripts/mutate.py,
    // where one detection is enough and the remaining runs only cost time).
    stop_on_fail = $test$plusargs("stop_on_fail");
    while ($fscanf(fd, "%s", name) == 1 && !(stop_on_fail && total_errors != 0)) begin
      if (only == "" || only == name) begin
        run_checked(name, MODE_IDEAL,  0);
        run_checked(name, MODE_STRESS, 32'h1234);
        if (!RANDOM_SET) begin
          run_checked(name, MODE_STRESS, 32'hBEEF);
          run_checked(name, MODE_STRESS, 32'h5EED0003);
          run_checked(name, MODE_LONG,   32'h7A11);
        end
        run_checked(name, MODE_LONG,   32'h10C0FFEE);
        run_checked(name, MODE_RESET,  32'hAB5E7);
      end
    end
    $fclose(fd);
    $fwrite(man_fd, "end %0d\n", replay_runs);
    $fclose(man_fd);
    // take-point coverage: every bin once interrupts were taken in ideal mode (D-033)
    if (irq_ideal_seen) begin
      int holes;
      holes = 0;
      for (int k = 0; k < COV_EX; k++)
        if (cov_ex[k] == 0) begin holes++; $display("hole: take with EX/ID kind %0d", k); end
      for (int k = 1; k <= 17; k++)
        if (cov_div[k] == 0) begin holes++; $display("hole: take at divider cycle %0d", k); end
      for (int k = 0; k < 4; k++)
        if (cov_defer[k] == 0) begin holes++; $display("hole: take deferred by cause %0d", k); end
      if (vec_ideal_seen)
        for (int k = 0; k < COV_VEC; k++)
          if (cov_vec[k] == 0) begin holes++; $display("hole: vectored entry bin %0d", k); end
      if (holes != 0) begin
        $display("ERROR %0d interrupt coverage holes", holes);
        total_errors += holes;
      end
    end
    if (runs == 0) begin
      $display("FAIL %s (no programs)", NAME);
      $fatal(1, "no programs");
    end else if (total_errors == 0) begin
      // (no string ternary inside a concatenation: Icarus 12)
      if (total_irqs == 0)
        $display("PASS %s (%0d program runs, %0d retirements matched the reference model, %0d data accesses checked exactly once)", NAME, runs, total_ref, xo_checked);
      else
        $display("PASS %s (%0d program runs, %0d retirements matched the reference model, %0d data accesses checked exactly once; %0d interrupts taken, %0d mnxti claims, %0d trigger latencies %0d-%0d cycles, take coverage %0d+17+4 bins; %0d runs for replay)",
                 NAME, runs, total_ref, xo_checked, total_irqs, total_claims, lat_checked, lat_min, lat_max,
                 COV_EX, replay_runs);
    end else begin
      $display("FAIL %s (%0d errors over %0d runs)", NAME, total_errors, runs);
      $fatal(1, "tb_core failed");
    end
    $finish;
  end

endmodule
