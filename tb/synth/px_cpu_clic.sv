// px_cpu_clic: synthesis-only top of px_core with px_clic attached the way tb_core attaches
// it (Phase 2 step 2.2d, DECISIONS.md D-035 item 21; D-034 obligations O1, O2, O4).
//
// Purpose: scripts/synth.sh runs `check -assert` on it, which fails on any combinational
// loop. px_clic's request is combinational in the core's mil/mintthresh/mode (D-034 item
// 13) and the core's take and claim are combinational in the request (D-033): a loop would
// exist if any of mil_o, mintthresh_o, clic_mode_o depended combinationally on the request,
// the acknowledge or the claim (O1, O2). scripts/core_cones.sh measures the depth of the
// core's outputs and of the paths from the take/claim logic into the CLIC's flops on this
// top (O4).
//
// Data port: addresses 0xE000_0000-0xE000_FFFF go to the CLIC (16-bit offset, granted in the
// request cycle, response in the next cycle), everything else to the memory side ports. The
// grant the core sees is the addressed target's (as in tb_core); with PX_GNT_FLAT it is the
// memory side's for every address (a platform whose fast targets all grant at once).
// Not part of the product RTL (no SoC yet); it lives with the test benches.

`timescale 1ns/1ps

module px_cpu_clic (
  input  logic        clk_i,
  input  logic        rst_ni,

  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  output logic [31:0] instr_addr_o,
  input  logic        instr_rvalid_i,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  output logic        data_req_o,
  input  logic        data_gnt_i,
  output logic [31:0] data_addr_o,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_wdata_o,
  input  logic        data_rvalid_i,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,

  input  logic [63:0] irq_i,

  output logic        rvfi_valid_o,
  output logic [31:0] rvfi_pc_o,
  output logic [31:0] rvfi_insn_o,
  output logic [4:0]  rvfi_rd_addr_o,
  output logic [31:0] rvfi_rd_wdata_o,
  output logic        trap_valid_o,
  output logic [5:0]  trap_cause_o,
  output logic [31:0] trap_pc_o
);

  logic        c_sel, c_gnt, c_rvalid, c_err, req, gnt;
  logic [31:0] c_rdata;
  logic        irq_req, irq_valid, irq_shv, ack, claim, cmode;
  logic [5:0]  irq_id, ack_id, claim_id;
  logic [7:0]  irq_level, mil, th;
  logic        core_req, core_we;
  logic [31:0] core_addr;

  /* verilator lint_off PINCONNECTEMPTY */
  px_core u_core (
    .clk_i, .rst_ni,
    .instr_req_o, .instr_gnt_i, .instr_addr_o, .instr_rvalid_i, .instr_rdata_i, .instr_err_i,
    .data_req_o(core_req), .data_gnt_i(gnt), .data_addr_o(core_addr),
    .data_we_o(core_we), .data_be_o, .data_wdata_o,
    .data_rvalid_i(data_rvalid_i || c_rvalid), .data_rdata_i(c_rvalid ? c_rdata : data_rdata_i),
    .data_err_i(c_rvalid ? c_err : data_err_i),
    .irq_req_i(irq_req), .irq_valid_i(irq_valid), .irq_id_i(irq_id), .irq_level_i(irq_level),
    .irq_shv_i(irq_shv), .irq_ack_o(ack), .irq_ack_id_o(ack_id),
    .irq_claim_o(claim), .irq_claim_id_o(claim_id),
    .mil_o(mil), .mintthresh_o(th), .clic_mode_o(cmode),
    .rvfi_valid_o, .rvfi_pc_o, .rvfi_insn_o, .rvfi_rd_addr_o, .rvfi_rd_wdata_o,
    .rvfi_mem_addr_o(), .rvfi_mem_rmask_o(), .rvfi_mem_wmask_o(), .rvfi_mem_rdata_o(),
    .rvfi_mem_wdata_o(), .rvfi_csr_we_o(), .rvfi_csr_addr_o(), .rvfi_csr_wdata_o(),
    .rvfi_csrx_we_o(), .rvfi_csrx_wdata_o(),
    .trap_valid_o, .trap_irq_o(), .trap_cause_o, .trap_pc_o, .trap_tval_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign c_sel        = core_addr[31:16] == 16'hE000;
`ifdef PX_GNT_FLAT
  // fast-route platform variant: every target grants in the request cycle, so the grant
  // the core sees does not depend on the address (cone measurement only, D-035 evidence)
  logic gnt_unused;
  assign gnt          = data_gnt_i;
  assign gnt_unused   = c_gnt;
`else
  // as tb_core: the grant comes from the addressed target
  assign gnt          = c_sel ? c_gnt : data_gnt_i;
`endif
  assign req          = core_req && c_sel;
  assign data_req_o   = core_req && !c_sel;
  assign data_addr_o  = core_addr;
  assign data_we_o    = core_we;

  px_clic #(.NUM_IRQ(64), .LVL_BITS(4)) u_clic (
    .clk_i, .rst_ni,
    .irq_i,
    .req_i(req), .gnt_o(c_gnt), .addr_i(core_addr[15:0]), .we_i(core_we), .be_i(data_be_o),
    .wdata_i(data_wdata_o), .rvalid_o(c_rvalid), .rdata_o(c_rdata), .err_o(c_err),
    .mil_i(mil), .mintthresh_i(th), .clic_mode_i(cmode),
    .ack_i(ack), .ack_id_i(ack_id), .claim_i(claim), .claim_id_i(claim_id),
    .irq_req_o(irq_req), .irq_valid_o(irq_valid), .irq_id_o(irq_id), .irq_level_o(irq_level),
    .irq_shv_o(irq_shv)
  );

endmodule
