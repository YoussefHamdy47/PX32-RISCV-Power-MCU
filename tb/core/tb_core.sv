// tb_core: runs every core test program on px_core (step 1.5).
//
// Each program in tb/core/programs/list.txt runs twice:
//   ideal   single-cycle memories (grant at once, response next cycle). Timing markers
//           are checked here and a retirement trace is written to sim/logs/.
//   stress  random grant delays and 1-3 cycle response latency on both ports. Results
//           must be identical; timing is not checked.
//
// Memory model: ITCM 64 KB at 0x1000_0000 (fetch and data port), DTCM 64 KB at
// 0x2000_0000 (data port only). Anything else returns a bus error, as does a fetch from
// DTCM, so programs can test access faults.
//
// Pass criteria per run
//   - the program writes 1 to tohost (0x2000_FFF0) before the cycle limit
//   - the traps reported by the core equal the program's table at 0x2000_F000
//     (count, then cause/pc/tval per trap), in order
//   - every timing marker retires exactly its declared number of cycles after the
//     previous one (ideal mode)
//   - OBI rules hold on both ports: a request that is not granted keeps its address and
//     attributes, responses never arrive without an outstanding request
//   - the trace never shows x0 being written with a nonzero value
//
// Run: scripts/run_unit.sh tb_core tb/core/tb_core.f

`timescale 1ns/1ps

module tb_core;

  localparam logic [31:0] ITCM_BASE = 32'h1000_0000;
  localparam logic [31:0] DTCM_BASE = 32'h2000_0000;
  localparam int          WORDS     = 16384;
  localparam logic [31:0] TOHOST    = 32'h2000_FFF0;
  localparam logic [31:0] MARKER    = 32'h2000_FFE0;
  localparam logic [31:0] TRAPTAB   = 32'h2000_F000;
  localparam logic [31:0] TRAPVEC   = 32'h1000_0040;
  localparam int          MAX_CYCLES = 200000;
  localparam int          QDEPTH    = 8;

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

  px_core #(.BOOT_ADDR(ITCM_BASE)) dut (
    .clk_i(clk), .rst_ni(rst_n), .trap_vector_i(TRAPVEC),
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

  // ---------------------------------------------------------------------------
  // Port models (shared state machine per port). Updated on the rising edge with
  // nonblocking assignments, so the DUT samples stable values.
  // ---------------------------------------------------------------------------
  bit stress;
  int seed;
  int cycle;

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
  logic [4:0]  trap_cause_log [32];
  logic [31:0] trap_pc_log    [32];
  logic [31:0] trap_tval_log  [32];
  int          retired;
  int          last_mark;
  bit          mark_started;
  int          marks_checked;
  int          trace_fd;
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
    if (!stress) return 1;
    return 1 + ($urandom(seed) % 3);
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      iq_head <= 0; iq_count <= 0; iq_last_due <= 0;
      dq_head <= 0; dq_count <= 0; dq_last_due <= 0;
      i_rvalid <= 1'b0; d_rvalid <= 1'b0;
      i_gnt <= 1'b1; d_gnt <= 1'b1;
      i_pend <= 1'b0; d_pend <= 1'b0;
      cycle <= 0;
    end else begin
      int          ih, ic, dh, dc, ild, dld, due;
      logic [31:0] word, a;
      logic        err;

      ih = iq_head; ic = iq_count; ild = iq_last_due;
      dh = dq_head; dc = dq_count; dld = dq_last_due;

      // ---- OBI rule checks (values seen during this cycle) ----
      if (i_pend && (!i_req || i_addr !== i_pend_addr))
        run_error("instruction request dropped or changed before grant");
      if (d_pend && (!d_req || d_addr !== d_pend_addr || d_we !== d_pend_we ||
                     d_be !== d_pend_be || (d_we && d_wdata !== d_pend_wdata)))
        run_error("data request dropped or changed before grant");
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
        err = !(in_itcm(a) || in_dtcm(a));
        word = 32'h0;
        if (!err) begin
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
        due = cycle + latency();
        if (due <= dld) due = dld + 1;
        dq_data[(dh + dc) % QDEPTH] = d_we ? 32'h0 : word; dq_err[(dh + dc) % QDEPTH] = err;
        dq_due[(dh + dc) % QDEPTH] = due; dc++; dld = due;
        if (dc > QDEPTH) run_error("data queue overflow");
      end

      // ---- outputs for the next cycle ----
      i_rvalid <= (ic > 0) && (iq_due[ih] <= cycle + 1);
      i_rdata  <= (ic > 0) ? iq_data[ih] : 32'hx;
      i_err    <= (ic > 0) ? iq_err[ih]  : 1'b0;
      d_rvalid <= (dc > 0) && (dq_due[dh] <= cycle + 1);
      d_rdata  <= (dc > 0) ? dq_data[dh] : 32'hx;
      d_err    <= (dc > 0) ? dq_err[dh]  : 1'b0;
      i_gnt    <= stress ? (($urandom(seed) % 4) != 0) : 1'b1;
      d_gnt    <= stress ? (($urandom(seed) % 4) != 0) : 1'b1;

      iq_head <= ih; iq_count <= ic; iq_last_due <= ild;
      dq_head <= dh; dq_count <= dc; dq_last_due <= dld;
      cycle   <= cycle + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Retirement and trap monitors
  // ---------------------------------------------------------------------------
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
        if (!tohost_retired) retired++;
        if (r_wmask != 4'd0 && r_mem_addr == TOHOST) tohost_retired = 1'b1;
        if (r_rd == 5'd0 && r_rd_wdata !== 32'd0) run_error("x0 written with a nonzero value");
        if (trace_fd != 0)
          $fwrite(trace_fd, "%08h %08h x%0d=%08h\n", r_pc, r_insn, r_rd, r_rd_wdata);
        if (r_wmask != 4'd0 && r_mem_addr == MARKER) begin
          if (!stress && mark_started && r_mem_wdata[7:0] != 8'd0) begin
            marks_checked++;
            if (cycle - last_mark != int'(r_mem_wdata[31:8]))
              run_error($sformatf("timing marker %0d: %0d cycles, expected %0d (pc %08h)",
                                  r_mem_wdata[7:0], cycle - last_mark, r_mem_wdata[31:8], r_pc));
          end
          mark_started = 1'b1;
          last_mark    = cycle;
        end
      end
      if (t_valid) begin
        if (n_traps < 32) begin
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

  task automatic run_program(input string name, input bit stress_mode, input int seed_i);
    string       mode;
    int          exp_n, base;
    mode = stress_mode ? "stress" : "ideal";

    for (int k = 0; k < WORDS; k++) begin itcm[k] = 32'd0; dtcm[k] = 32'd0; end
    $readmemh({"tb/core/programs/", name, ".itcm.hex"}, itcm);
    $readmemh({"tb/core/programs/", name, ".dtcm.hex"}, dtcm);

    stress = stress_mode;
    seed   = seed_i;
    tohost_seen = 1'b0; tohost_retired = 1'b0; tohost_val = 32'd0;
    errors_run = 0; n_traps = 0; retired = 0; last_retire = 0;
    mark_started = 1'b0; marks_checked = 0; last_mark = 0;
    // (a ternary between strings inside the concatenation crashes Icarus 12)
    if (stress_mode) trace_fd = $fopen({"sim/logs/core_", name, "_stress.trace"}, "w");
    else             trace_fd = $fopen({"sim/logs/core_", name, ".trace"}, "w");

    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // Stop at tohost, at the cycle limit, or when nothing has retired for 2000 cycles.
    while (!tohost_seen && cycle < MAX_CYCLES && (cycle - last_retire) < 2000) @(posedge clk);
    if (!tohost_seen && (cycle - last_retire) >= 2000)
      run_error($sformatf("deadlock: nothing retired since cycle %0d", last_retire));
    repeat (5) @(posedge clk);      // let the final store retire
    if (trace_fd != 0) $fclose(trace_fd);
    trace_fd = 0;

    if (!tohost_seen)
      run_error("timeout: tohost never written");
    else if (tohost_val != 32'd1)
      run_error($sformatf("program reported failure in test %0d", (tohost_val >> 1) - 1));

    // expected traps
    base  = (TRAPTAB - DTCM_BASE) >> 2;
    exp_n = int'(dtcm[base]);
    if (exp_n != n_traps)
      run_error($sformatf("%0d traps seen, %0d expected", n_traps, exp_n));
    for (int k = 0; k < exp_n && k < n_traps && k < 32; k++) begin
      if (trap_cause_log[k] != dtcm[base + 1 + 3*k][4:0] || trap_pc_log[k] != dtcm[base + 2 + 3*k] ||
          trap_tval_log[k] != dtcm[base + 3 + 3*k])
        run_error($sformatf("trap %0d: cause %0d pc %08h tval %08h, expected %0d %08h %08h", k,
                            trap_cause_log[k], trap_pc_log[k], trap_tval_log[k],
                            dtcm[base + 1 + 3*k], dtcm[base + 2 + 3*k], dtcm[base + 3 + 3*k]));
    end

    runs++;
    total_errors += errors_run;
    $display("%-6s %-22s %s  %0d retired, %0d cycles, %0d traps, %0d timing marks",
             errors_run == 0 ? "ok" : "FAILED", name, mode, retired, cycle, n_traps, marks_checked);
  endtask

  initial begin
    int    fd;
    string name;
    string only;
    fd = $fopen("tb/core/programs/list.txt", "r");
    if (fd == 0) begin
      $display("FAIL tb_core (no program list)");
      $finish;
    end
    rst_n = 1'b0;
    // +only=<program> runs a single program (debugging); +vcd dumps a waveform.
    if (!$value$plusargs("only=%s", only)) only = "";
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_core.vcd");
      $dumpvars(0, tb_core);
    end
    while ($fscanf(fd, "%s", name) == 1) begin
      if (only == "" || only == name) begin
        run_program(name, 1'b0, 0);
        run_program(name, 1'b1, 32'h1234);
        run_program(name, 1'b1, 32'hBEEF);
      end
    end
    $fclose(fd);
    if (runs == 0)
      $display("FAIL tb_core (no programs)");
    else if (total_errors == 0)
      $display("PASS tb_core (%0d program runs, ideal and stress memory)", runs);
    else
      $display("FAIL tb_core (%0d errors over %0d runs)", total_errors, runs);
    $finish;
  end

endmodule
