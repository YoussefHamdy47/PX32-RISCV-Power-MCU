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
  logic [4:0]  r_rd;
  logic [3:0]  r_rmask, r_wmask;
  logic        t_valid;
  logic [4:0]  t_cause;
  logic [31:0] t_pc, t_tval;

  px_core #(.BOOT_ADDR(ITCM_BASE), .MTVEC_RESET(TRAPVEC)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .instr_req_o(i_req), .instr_gnt_i(i_gnt), .instr_addr_o(i_addr),
    .instr_rvalid_i(i_rvalid), .instr_rdata_i(i_rdata), .instr_err_i(i_err),
    .data_req_o(d_req), .data_gnt_i(d_gnt), .data_addr_o(d_addr), .data_we_o(d_we),
    .data_be_o(d_be), .data_wdata_o(d_wdata), .data_rvalid_i(d_rvalid),
    .data_rdata_i(d_rdata), .data_err_i(d_err),
    .rvfi_valid_o(r_valid), .rvfi_pc_o(r_pc), .rvfi_insn_o(r_insn),
    .rvfi_rd_addr_o(r_rd), .rvfi_rd_wdata_o(r_rd_wdata), .rvfi_mem_addr_o(r_mem_addr),
    .rvfi_mem_rmask_o(r_rmask), .rvfi_mem_wmask_o(r_wmask),
    .rvfi_mem_rdata_o(r_mem_rdata), .rvfi_mem_wdata_o(r_mem_wdata),
    .trap_valid_o(t_valid), .trap_cause_o(t_cause), .trap_pc_o(t_pc), .trap_tval_o(t_tval)
  );

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
      if (d_req && d_gnt && (dc - (d_rvalid ? 1 : 0)) != 0)
        run_error($sformatf("data port: grant with %0d request(s) outstanding", dc - (d_rvalid ? 1 : 0)));
      i_pend <= i_req && !i_gnt;  i_pend_addr <= i_addr;
      d_pend <= d_req && !d_gnt;  d_pend_addr <= d_addr;
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
      if (d_req && d_gnt) begin
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
  // Retirement and trap monitors
  // ---------------------------------------------------------------------------
  task automatic check_ref();
    logic [31:0] e_pc, e_insn, e_wd, e_ma, e_md, e_care;
    int          e_rd, n;
    logic [3:0]  e_rm, e_wm;
    logic [31:0] got_md, lm;
    if (ref_fd != 0) begin
      n = $fscanf(ref_fd, "%h %h %d %h %h %h %h %h %h\n", e_pc, e_insn, e_rd, e_wd, e_ma, e_rm, e_wm, e_md, e_care);
      if (n != 9)
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
      if (t_valid && !tohost_retired && ref_traps >= 0 && n_traps >= ref_traps)
        run_error($sformatf("trap %0d (cause %0d pc %08h) beyond the %0d traps of the reference model",
                            n_traps + 1, t_cause, t_pc, ref_traps));
      if (t_valid && !tohost_retired) begin
        if (n_traps < MAXTRAPS) begin
          trap_cause_log[n_traps] = t_cause;
          trap_pc_log[n_traps]    = t_pc;
          trap_tval_log[n_traps]  = t_tval;
        end
        n_traps++;
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
    ref_fd = $fopen({"tb/core/programs/", name, ".trace.ref"}, "r");
    if (ref_fd == 0) run_error({"missing reference trace for ", name});
    ref_checked = 0;
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
    if (trace_fd != 0) $fclose(trace_fd);
    trace_fd = 0;

    if (!tohost_seen || !tohost_retired)
      run_error("timeout: tohost never written and retired");
    else if (tohost_val != 32'd1)
      run_error($sformatf("program reported failure in test %0d", (tohost_val >> 1) - 1));

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
    // ... and the reference model's list
    rfd = $fopen({"tb/core/programs/", name, ".traps.ref"}, "r");
    if (rfd == 0) run_error({"missing reference trap list for ", name});
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
    $display("%-6s %-22s %-6s seed %08h  %0d retired, %0d cycles, %0d traps, %0d timing marks, %0d cycle checks",
             errors_run == 0 ? "ok" : "FAILED", name, mname, seed_i, retired, cycle, n_traps,
             marks_checked, cyc_checked);
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
    trace_fd = 0; ref_fd = 0;
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
    if (runs == 0) begin
      $display("FAIL %s (no programs)", NAME);
      $fatal(1, "no programs");
    end else if (total_errors == 0)
      $display("PASS %s (%0d program runs, %0d retirements matched the reference model)", NAME, runs, total_ref);
    else begin
      $display("FAIL %s (%0d errors over %0d runs)", NAME, total_errors, runs);
      $fatal(1, "tb_core failed");
    end
    $finish;
  end

endmodule
