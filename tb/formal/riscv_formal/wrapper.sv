// rvfi_wrapper: px_core in the riscv-formal testbench (DECISIONS.md D-030).
//
// Environment
//   - Both OBI ports: the grant, the response cycle and the response data are free
//     (anyseq) each cycle, with the protocol assumed: a grant only for a raised request and
//     only when no response is outstanding (or the outstanding one is answered in the same
//     cycle), a response only for a granted request, at most one outstanding request per
//     port (contract § 3.2, D-021). Nothing is assumed about the data: every instruction
//     word and every loaded value is arbitrary.
//   - Bus errors are assumed absent (instr_err_i = data_err_i = 0): riscv-formal's
//     instruction checks then see only architectural traps. Access faults are covered by
//     tb_core, riscv-tests, ACT4 and the Spike comparison (D-030 item 6).
//   - PX32_FAIRNESS (liveness check only): a grant and a response each wait at most one cycle
//     (any finite bound shows the absence of deadlock; this one keeps the BMC window short).
//   - Reset: riscv-formal holds `reset` high for its reset cycles; px_core's reset is
//     active low.

module rvfi_wrapper (
  input  clock,
  input  reset,
  `RVFI_OUTPUTS
);
  (* keep *) `rvformal_rand_reg        i_gnt, i_rvalid;
  (* keep *) `rvformal_rand_reg [31:0] i_rdata;
  (* keep *) `rvformal_rand_reg        d_gnt, d_rvalid;
  (* keep *) `rvformal_rand_reg [31:0] d_rdata;

  (* keep *) wire        i_req;
  (* keep *) wire [31:0] i_addr;
  (* keep *) wire        d_req, d_we;
  (* keep *) wire [31:0] d_addr, d_wdata;
  (* keep *) wire [3:0]  d_be;

  // CSR access report of the retiring instruction (mapped below)
  (* keep *) wire        c_valid, c_read, c_write;
  (* keep *) wire [11:0] c_addr;
  (* keep *) wire [31:0] c_rdata, c_wdata;

  // Product trace and trap ports are not used by riscv-formal.
  wire        u_valid, u_csr_we, u_tvalid;
  wire [31:0] u_pc, u_insn, u_rd_wdata, u_mem_addr, u_mem_rdata, u_mem_wdata, u_csr_wdata;
  wire [31:0] u_tpc, u_ttval;
  wire [4:0]  u_rd, u_tcause;
  wire [3:0]  u_rmask, u_wmask;
  wire [11:0] u_csr_addr;

  // default parameters (BOOT_ADDR 0x1000_0000, MTVEC_RESET 0x1000_0040): px_core is elaborated by
  // the slang front end, which cannot re-parameterize it from this Verilog-parsed wrapper
  px_core uut (
    .clk_i (clock), .rst_ni(!reset),
    .instr_req_o(i_req), .instr_gnt_i(i_gnt), .instr_addr_o(i_addr),
    .instr_rvalid_i(i_rvalid), .instr_rdata_i(i_rdata), .instr_err_i(1'b0),
    .data_req_o(d_req), .data_gnt_i(d_gnt), .data_addr_o(d_addr), .data_we_o(d_we),
    .data_be_o(d_be), .data_wdata_o(d_wdata), .data_rvalid_i(d_rvalid),
    .data_rdata_i(d_rdata), .data_err_i(1'b0),
    .rvfi_valid_o(u_valid), .rvfi_pc_o(u_pc), .rvfi_insn_o(u_insn),
    .rvfi_rd_addr_o(u_rd), .rvfi_rd_wdata_o(u_rd_wdata), .rvfi_mem_addr_o(u_mem_addr),
    .rvfi_mem_rmask_o(u_rmask), .rvfi_mem_wmask_o(u_wmask),
    .rvfi_mem_rdata_o(u_mem_rdata), .rvfi_mem_wdata_o(u_mem_wdata),
    .rvfi_csr_we_o(u_csr_we), .rvfi_csr_addr_o(u_csr_addr), .rvfi_csr_wdata_o(u_csr_wdata),
    .trap_valid_o(u_tvalid), .trap_cause_o(u_tcause), .trap_pc_o(u_tpc), .trap_tval_o(u_ttval),
    .rvf_valid_o(rvfi_valid), .rvf_order_o(rvfi_order), .rvf_insn_o(rvfi_insn),
    .rvf_trap_o(rvfi_trap), .rvf_halt_o(rvfi_halt), .rvf_intr_o(rvfi_intr),
    .rvf_mode_o(rvfi_mode), .rvf_ixl_o(rvfi_ixl),
    .rvf_rs1_addr_o(rvfi_rs1_addr), .rvf_rs2_addr_o(rvfi_rs2_addr),
    .rvf_rs1_rdata_o(rvfi_rs1_rdata), .rvf_rs2_rdata_o(rvfi_rs2_rdata),
    .rvf_rd_addr_o(rvfi_rd_addr), .rvf_rd_wdata_o(rvfi_rd_wdata),
    .rvf_pc_rdata_o(rvfi_pc_rdata), .rvf_pc_wdata_o(rvfi_pc_wdata),
    .rvf_mem_addr_o(rvfi_mem_addr), .rvf_mem_rmask_o(rvfi_mem_rmask),
    .rvf_mem_wmask_o(rvfi_mem_wmask), .rvf_mem_rdata_o(rvfi_mem_rdata),
    .rvf_mem_wdata_o(rvfi_mem_wdata),
    .rvf_csr_valid_o(c_valid), .rvf_csr_addr_o(c_addr), .rvf_csr_read_o(c_read),
    .rvf_csr_write_o(c_write), .rvf_csr_rdata_o(c_rdata), .rvf_csr_wdata_o(c_wdata)
  );

  // Per-CSR riscv-formal signals from the retiring Zicsr access. Only CSR instructions report a
  // CSR (trap entry and MRET writes are not reported): the checks used (csrw, csrc_any,
  // csrc_upcnt) look at CSR instructions only. 64-bit counters: the accessed half only.
  wire c_lo_mcycle   = c_valid && c_addr == 12'hB00, c_hi_mcycle   = c_valid && c_addr == 12'hB80;
  wire c_lo_minstret = c_valid && c_addr == 12'hB02, c_hi_minstret = c_valid && c_addr == 12'hB82;

`ifdef RISCV_FORMAL_CSR_MSCRATCH
  assign rvfi_csr_mscratch_rmask = (c_valid && c_addr == 12'h340 && c_read)  ? 32'hFFFF_FFFF : 32'd0;
  assign rvfi_csr_mscratch_wmask = (c_valid && c_addr == 12'h340 && c_write) ? 32'hFFFF_FFFF : 32'd0;
  assign rvfi_csr_mscratch_rdata = (c_valid && c_addr == 12'h340) ? c_rdata : 32'd0;
  assign rvfi_csr_mscratch_wdata = (c_valid && c_addr == 12'h340) ? c_wdata : 32'd0;
`endif
`ifdef RISCV_FORMAL_CSR_MTVAL
  assign rvfi_csr_mtval_rmask = (c_valid && c_addr == 12'h343 && c_read)  ? 32'hFFFF_FFFF : 32'd0;
  assign rvfi_csr_mtval_wmask = (c_valid && c_addr == 12'h343 && c_write) ? 32'hFFFF_FFFF : 32'd0;
  assign rvfi_csr_mtval_rdata = (c_valid && c_addr == 12'h343) ? c_rdata : 32'd0;
  assign rvfi_csr_mtval_wdata = (c_valid && c_addr == 12'h343) ? c_wdata : 32'd0;
`endif
`ifdef RISCV_FORMAL_CSR_MCYCLE
  assign rvfi_csr_mcycle_rmask = c_lo_mcycle && c_read  ? 64'h0000_0000_FFFF_FFFF :
                                 c_hi_mcycle && c_read  ? 64'hFFFF_FFFF_0000_0000 : 64'd0;
  assign rvfi_csr_mcycle_wmask = c_lo_mcycle && c_write ? 64'h0000_0000_FFFF_FFFF :
                                 c_hi_mcycle && c_write ? 64'hFFFF_FFFF_0000_0000 : 64'd0;
  assign rvfi_csr_mcycle_rdata = c_lo_mcycle ? {32'd0, c_rdata} : c_hi_mcycle ? {c_rdata, 32'd0} : 64'd0;
  assign rvfi_csr_mcycle_wdata = c_lo_mcycle ? {32'd0, c_wdata} : c_hi_mcycle ? {c_wdata, 32'd0} : 64'd0;
`endif
`ifdef RISCV_FORMAL_CSR_MINSTRET
  assign rvfi_csr_minstret_rmask = c_lo_minstret && c_read  ? 64'h0000_0000_FFFF_FFFF :
                                   c_hi_minstret && c_read  ? 64'hFFFF_FFFF_0000_0000 : 64'd0;
  assign rvfi_csr_minstret_wmask = c_lo_minstret && c_write ? 64'h0000_0000_FFFF_FFFF :
                                   c_hi_minstret && c_write ? 64'hFFFF_FFFF_0000_0000 : 64'd0;
  assign rvfi_csr_minstret_rdata = c_lo_minstret ? {32'd0, c_rdata} : c_hi_minstret ? {c_rdata, 32'd0} : 64'd0;
  assign rvfi_csr_minstret_wdata = c_lo_minstret ? {32'd0, c_wdata} : c_hi_minstret ? {c_wdata, 32'd0} : 64'd0;
`endif

  // OBI protocol assumptions, per port
  reg i_out, d_out;
  always @(posedge clock) begin
    if (reset) begin
      i_out <= 1'b0;
      d_out <= 1'b0;
    end else begin
      i_out <= (i_out && !i_rvalid) || (i_req && i_gnt);
      d_out <= (d_out && !d_rvalid) || (d_req && d_gnt);
    end
  end

  always @* begin
    if (reset) begin
      assume (!i_gnt && !i_rvalid && !d_gnt && !d_rvalid);
    end else begin
      assume (!i_gnt || i_req);
      assume (!d_gnt || d_req);
      assume (!i_rvalid || i_out);
      assume (!d_rvalid || d_out);
      assume (!(i_gnt && i_out && !i_rvalid));
      assume (!(d_gnt && d_out && !d_rvalid));
    end
  end

`ifdef PX32_FAIRNESS
  // Liveness only: a raised request is granted, and an outstanding request answered, after
  // at most one wait cycle.
  reg [2:0] i_wait, d_wait;
  always @(posedge clock) begin
    if (reset) begin
      i_wait <= 3'd0;
      d_wait <= 3'd0;
    end else begin
      i_wait <= ((i_req && !i_gnt) || (i_out && !i_rvalid)) ? i_wait + 3'd1 : 3'd0;
      d_wait <= ((d_req && !d_gnt) || (d_out && !d_rvalid)) ? d_wait + 3'd1 : 3'd0;
    end
  end
  always @* if (!reset) assume (i_wait < 3'd2 && d_wait < 3'd2);
`endif
endmodule
