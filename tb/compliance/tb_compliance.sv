// tb_compliance: runs one external compliance test ELF image on px_core (step 1.8).
//
// Platform (tb/compliance only; D-024):
//   MEM   1 MB at 0x1000_0000, read/write/execute through both ports (the riscv-tests
//         p environment places code, data and tohost in one region; fence_i executes code
//         from .data). Same base as the PX32 ITCM; only the size differs from tb_core.
//   Every other address returns a bus error.
//   +core_map (step 1.9, programs built for tb_core, e.g. the long random programs): the
//         tb_core map without its side-effect device instead: ITCM 64 KB at 0x1000_0000
//         (fetch and data), DTCM 64 KB at 0x2000_0000 (data only; a fetch is a bus error),
//         everything else a bus error. The DTCM image comes from +dtcm_image.
//   mtvec resets to 0x1000_0040; the test environment sets it anyway.
// Test protocol (riscv-tests p environment, and the PX32 ACT4 RVMODEL_HALT macros):
//   the test stores to the word at +tohost=<hex address>. A stored value of 1 is PASS,
//   any other nonzero value is FAIL (riscv-tests: (test_number << 1) | 1). The store must
//   retire.
// Result line (exactly one): "PASS tb_compliance <name>", "FAIL tb_compliance <name> ...",
// or "TIMEOUT tb_compliance <name> ...". Anything else (no image, no tohost address, X on
// a control output, deadlock, cycle limit) is a failure with a nonzero exit.
//
// Plusargs: +image=<path to .hex, one 32-bit word per line from 0x1000_0000>
//           +tohost=<hex address>   +name=<test name>   +max_cycles=<n> (default 2,000,000)
//           +stress=<seed>          random grant delays and 1-3 cycle latency (default: ideal)
//           +trace=<file>           trace for step 1.9, in program order, one line per event:
//                                   retirement: pc insn rd value csr_we csr_addr csr_value
//                                     mem_addr rmask wmask wdata
//                                     (hex; csr_value is the CSR after the write; mem_addr is
//                                     the byte address, the masks are byte lanes of the
//                                     word, wdata the store data on its lanes)
//                                   trap:       "trap" cause epc tval (hex)
//                                   An older retirement and a younger trap in the same cycle
//                                   are written in that order (the trap is in EX, the
//                                   retirement in WB; a WB bus error has no retirement)
//           +core_map +dtcm_image=<path>   the tb_core memory map (above)
//           +console=<hex address>  byte stores to this address are printed (ACT4
//                                   RVMODEL_IO_WRITE_STR; failure messages)
// Run: scripts/compliance/run_riscv_tests.sh (compiles this bench once, runs every test)

`timescale 1ns/1ps

module tb_compliance;

  localparam logic [31:0] MEM_BASE  = 32'h1000_0000;
  localparam int          WORDS     = 262144;          // 1 MB
  localparam logic [31:0] TRAPVEC   = 32'h1000_0040;
  localparam int          QDEPTH    = 8;
  localparam logic [31:0] DTCM_BASE = 32'h2000_0000;
  localparam int          CORE_WORDS = 16384;       // tb_core ITCM and DTCM: 64 KB each

  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk;

  logic [31:0] mem [0:WORDS-1];
  logic [31:0] dtcm [0:CORE_WORDS-1];
  bit          core_map;

  logic        i_req, i_gnt, i_rvalid, i_err;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_gnt, d_we, d_rvalid, d_err;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic [3:0]  d_be;
  logic        r_valid;
  logic [31:0] r_pc, r_insn, r_rd_wdata, r_mem_addr, r_mem_rdata, r_mem_wdata;
  logic [4:0]  r_rd;
  logic [3:0]  r_rmask, r_wmask;
  logic        r_csr_we;
  logic [11:0] r_csr_addr;
  logic [31:0] r_csr_wdata;
  logic        t_valid;
  logic [4:0]  t_cause;
  logic [31:0] t_pc, t_tval;

  px_core #(.BOOT_ADDR(MEM_BASE), .MTVEC_RESET(TRAPVEC)) dut (
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
    .rvfi_csr_we_o(r_csr_we), .rvfi_csr_addr_o(r_csr_addr), .rvfi_csr_wdata_o(r_csr_wdata),
    .trap_valid_o(t_valid), .trap_cause_o(t_cause), .trap_pc_o(t_pc), .trap_tval_o(t_tval)
  );

  function automatic bit in_mem(input logic [31:0] a);
    return a >= MEM_BASE && a < MEM_BASE + 4 * (core_map ? CORE_WORDS : WORDS);
  endfunction

  function automatic bit in_dtcm(input logic [31:0] a);
    return core_map && a >= DTCM_BASE && a < DTCM_BASE + 4 * CORE_WORDS;
  endfunction

  // ---------------------------------------------------------------------------
  // OBI memory model: one response per granted request, in order
  // ---------------------------------------------------------------------------
  bit          stress;
  int          seed;
  int          cycle;
  logic [31:0] iq_data [QDEPTH]; logic iq_err [QDEPTH]; int iq_due [QDEPTH];
  logic [31:0] dq_data [QDEPTH]; logic dq_err [QDEPTH]; int dq_due [QDEPTH];
  int          iq_head, iq_count, iq_last, dq_head, dq_count, dq_last;
  int          errors;

  function automatic int lat();
    return stress ? 1 + ($urandom(seed) % 3) : 1;
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      iq_head <= 0; iq_count <= 0; iq_last <= 0; dq_head <= 0; dq_count <= 0; dq_last <= 0;
      i_rvalid <= 1'b0; d_rvalid <= 1'b0; i_err <= 1'b0; d_err <= 1'b0;
      i_gnt <= 1'b1; d_gnt <= 1'b1;
      cycle <= 0;
    end else begin
      int ih, ic, dh, dc, il, dl, due;
      logic [31:0] w, a;
      logic e;
      ih = iq_head; ic = iq_count; il = iq_last; dh = dq_head; dc = dq_count; dl = dq_last;
      if (i_rvalid) begin ih = (ih + 1) % QDEPTH; ic--; end
      if (d_rvalid) begin dh = (dh + 1) % QDEPTH; dc--; end
      if (i_req && i_gnt) begin
        a = i_addr; e = !in_mem(a);
        w = e ? 32'hDEAD_BEEF : mem[(a - MEM_BASE) >> 2];
        due = cycle + lat(); if (due <= il) due = il + 1;
        iq_data[(ih + ic) % QDEPTH] = w; iq_err[(ih + ic) % QDEPTH] = e;
        iq_due[(ih + ic) % QDEPTH] = due; ic++; il = due;
      end
      if (d_req && d_gnt) begin
        a = d_addr; e = !in_mem(a) && !in_dtcm(a); w = 32'd0;
        if (!e) begin
          w = in_dtcm(a) ? dtcm[(a - DTCM_BASE) >> 2] : mem[(a - MEM_BASE) >> 2];
          if (d_we) begin
            for (int b = 0; b < 4; b++) if (d_be[b]) w[8*b +: 8] = d_wdata[8*b +: 8];
            if (in_dtcm(a)) dtcm[(a - DTCM_BASE) >> 2] = w;
            else            mem[(a - MEM_BASE) >> 2] = w;
          end
        end
        due = cycle + lat(); if (due <= dl) due = dl + 1;
        dq_data[(dh + dc) % QDEPTH] = d_we ? 32'd0 : w; dq_err[(dh + dc) % QDEPTH] = e;
        dq_due[(dh + dc) % QDEPTH] = due; dc++; dl = due;
      end
      if (ic > QDEPTH || dc > QDEPTH) begin
        errors++;
        $display("ERROR cycle %0d: memory model queue overflow", cycle);
      end
      i_rvalid <= (ic > 0) && (iq_due[ih] <= cycle + 1);
      d_rvalid <= (dc > 0) && (dq_due[dh] <= cycle + 1);
      i_rdata  <= iq_data[ih]; i_err <= (ic > 0) && (iq_due[ih] <= cycle + 1) && iq_err[ih];
      d_rdata  <= dq_data[dh]; d_err <= (dc > 0) && (dq_due[dh] <= cycle + 1) && dq_err[dh];
      i_gnt <= stress ? (($urandom(seed) % 4) != 0) : 1'b1;
      d_gnt <= stress ? (($urandom(seed) % 4) != 0) : 1'b1;
      iq_head <= ih; iq_count <= ic; iq_last <= il; dq_head <= dh; dq_count <= dc; dq_last <= dl;
      cycle <= cycle + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Monitors: tohost, X on control outputs, trace
  // ---------------------------------------------------------------------------
  logic [31:0] tohost, console;
  string       con_line;
  bit          done;
  logic [31:0] tohost_val;
  int          retired, last_retire, traps, trace_fd;

  always @(posedge clk) begin
    if (rst_n) begin
      if ((^{i_req, d_req, r_valid, t_valid}) === 1'bx ||
          (i_req && (^i_addr) === 1'bx) || (d_req && (^{d_addr, d_we, d_be}) === 1'bx)) begin
        errors++;
        $display("ERROR cycle %0d: X on a core control output", cycle);
      end
      if (r_valid && !done) begin
        retired++;
        last_retire = cycle;
        if (trace_fd != 0)
          $fwrite(trace_fd, "%08h %08h %0d %08h %0d %03h %08h %08h %01h %01h %08h\n", r_pc, r_insn,
                  r_rd, r_rd_wdata, r_csr_we, r_csr_addr, r_csr_wdata, r_mem_addr, r_rmask,
                  r_wmask, r_mem_wdata);
        if (console != 32'd0 && r_wmask != 4'd0 && r_mem_addr == console) begin
          // (Icarus 12 crashes on a string cast of a byte: use $sformatf)
          if (r_mem_wdata[7:0] == 8'h0A) begin
            $display("CONSOLE %s", con_line);
            con_line = "";
          end else
            con_line = $sformatf("%s%c", con_line, r_mem_wdata[7:0]);
        end
        if (r_wmask == 4'b1111 && r_mem_addr == tohost && r_mem_wdata != 32'd0) begin
          done = 1'b1;
          tohost_val = r_mem_wdata;
        end
      end
      if (t_valid && !done) begin
        traps++;
        if (trace_fd != 0) $fwrite(trace_fd, "trap %0h %08h %08h\n", t_cause, t_pc, t_tval);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Runner
  // ---------------------------------------------------------------------------
  initial begin
    string image, dimage, name, tfile;
    int    max_cycles, fd;
    rst_n = 1'b0;
    errors = 0; done = 1'b0; retired = 0; last_retire = 0; traps = 0; trace_fd = 0;
    tohost = 32'd0; tohost_val = 32'd0; console = 32'd0; con_line = "";
    if (!$value$plusargs("console=%h", console)) console = 32'd0;
    if (!$value$plusargs("name=%s", name)) name = "unnamed";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2000000;
    stress = $value$plusargs("stress=%d", seed);
    core_map = $test$plusargs("core_map");
    if (!$value$plusargs("image=%s", image)) begin
      $display("FAIL tb_compliance %s (no +image)", name);
      $fatal(1, "no image");
    end
    if (!$value$plusargs("tohost=%h", tohost) || tohost == 32'd0) begin
      $display("FAIL tb_compliance %s (no +tohost address)", name);
      $fatal(1, "no tohost");
    end
    fd = $fopen(image, "r");
    if (fd == 0) begin
      $display("FAIL tb_compliance %s (image %s not found)", name, image);
      $fatal(1, "no image file");
    end
    $fclose(fd);
    for (int k = 0; k < WORDS; k++) mem[k] = 32'd0;
    for (int k = 0; k < CORE_WORDS; k++) dtcm[k] = 32'd0;
    $readmemh(image, mem);
    if (core_map) begin
      if (!$value$plusargs("dtcm_image=%s", dimage)) begin
        $display("FAIL tb_compliance %s (+core_map needs +dtcm_image)", name);
        $fatal(1, "no dtcm image");
      end
      fd = $fopen(dimage, "r");
      if (fd == 0) begin
        $display("FAIL tb_compliance %s (image %s not found)", name, dimage);
        $fatal(1, "no dtcm image file");
      end
      $fclose(fd);
      $readmemh(dimage, dtcm);
    end
    if ($value$plusargs("trace=%s", tfile)) trace_fd = $fopen(tfile, "w");

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    while (!done && cycle < max_cycles && (cycle - last_retire) < 10000 && errors == 0)
      @(posedge clk);
    repeat (3) @(posedge clk);
    if (trace_fd != 0) $fclose(trace_fd);
    if (con_line != "") $display("CONSOLE %s", con_line);

    if (errors != 0) begin
      $display("FAIL tb_compliance %s (%0d bench errors, cycle %0d)", name, errors, cycle);
      $fatal(1, "bench errors");
    end else if (!done && (cycle - last_retire) >= 10000) begin
      $display("TIMEOUT tb_compliance %s (deadlock: nothing retired since cycle %0d)", name, last_retire);
      $fatal(1, "deadlock");
    end else if (!done) begin
      $display("TIMEOUT tb_compliance %s (no tohost write within %0d cycles, %0d retired)", name, max_cycles, retired);
      $fatal(1, "timeout");
    end else if (tohost_val != 32'd1) begin
      $display("FAIL tb_compliance %s (tohost %0d: test %0d failed, %0d retired, %0d cycles, %0d traps)",
               name, tohost_val, tohost_val >> 1, retired, cycle, traps);
      $fatal(1, "test failed");
    end else
      $display("PASS tb_compliance %s (%0d retired, %0d cycles, %0d traps)", name, retired, cycle, traps);
    $finish;
  end

endmodule
