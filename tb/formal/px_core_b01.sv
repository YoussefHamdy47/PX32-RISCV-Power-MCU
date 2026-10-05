// px_core_b01: formal harness for the audit B-01 change of step 2.2b (SymbiYosys,
// tb/formal/px_core_b01.sby; DECISIONS.md D-033 items 3 and 11).
//
// D-033 drops the grant term (hold_grant) from ex_trap and ex_redirect. This harness
// proves, for every reachable state, that the term was redundant: an instruction held in
// EX by hold_grant alone neither traps in EX nor redirects. Together with
// scripts/core_equiv.sh (every other signal pair of px_core proven equal to the reference
// core) this shows that the change does not alter behaviour.
//
// Environment: every px_core input is free in every cycle (instruction and data words,
// grants, responses, errors, the interrupt request); reset in the first cycle only.
//
// Properties
//   P1  the EX decode register never holds a memory access that is also a branch, JALR,
//       FENCE.I or MRET (it is loaded only from px_decoder, or reset to zero)
//   P2  an instruction in EX held by hold_grant is a memory access without exception, so
//       none of the ex_trap / ex_redirect conditions is true
// prove: k-induction (P1 makes P2 inductive); cover: hold_grant while an interrupt is
// eligible and while EX is valid.

`timescale 1ns/1ps

module px_core_b01 (
  input logic        clk_i,
  input logic        instr_gnt_i,
  input logic        instr_rvalid_i,
  input logic [31:0] instr_rdata_i,
  input logic        instr_err_i,
  input logic        data_gnt_i,
  input logic        data_rvalid_i,
  input logic [31:0] data_rdata_i,
  input logic        data_err_i,
  input logic        irq_req_i,
  input logic [5:0]  irq_id_i
);

  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = !init;

  /* verilator lint_off PINCONNECTEMPTY */
  px_core dut (
    .clk_i, .rst_ni,
    .instr_req_o(), .instr_gnt_i, .instr_addr_o(),
    .instr_rvalid_i, .instr_rdata_i, .instr_err_i,
    .data_req_o(), .data_gnt_i, .data_addr_o(), .data_we_o(), .data_be_o(), .data_wdata_o(),
    .data_rvalid_i, .data_rdata_i, .data_err_i,
    .irq_req_i, .irq_id_i, .irq_ack_o(), .irq_ack_id_o(),
    .rvfi_valid_o(), .rvfi_pc_o(), .rvfi_insn_o(), .rvfi_rd_addr_o(), .rvfi_rd_wdata_o(),
    .rvfi_mem_addr_o(), .rvfi_mem_rmask_o(), .rvfi_mem_wmask_o(), .rvfi_mem_rdata_o(),
    .rvfi_mem_wdata_o(), .rvfi_csr_we_o(), .rvfi_csr_addr_o(), .rvfi_csr_wdata_o(),
    .trap_valid_o(), .trap_irq_o(), .trap_cause_o(), .trap_pc_o(), .trap_tval_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic ex_mem, ex_flow;
  assign ex_mem  = dut.ex_dec_q.is_load || dut.ex_dec_q.is_store;
  assign ex_flow = dut.ex_dec_q.is_branch || dut.ex_dec_q.is_jalr ||
                   dut.ex_dec_q.is_fence_i || dut.ex_dec_q.is_mret;

  always_comb begin
    if (rst_ni) begin
      assert (!(ex_mem && ex_flow));                                           // P1
      if (dut.ex_valid_q && dut.hold_grant)                                    // P2
        assert (!(dut.ex_exc || dut.br_taken || ex_flow));
    end
  end

  always_comb begin
    if (rst_ni) cover (dut.ex_valid_q && dut.hold_grant && !dut.hold_older);
  end

endmodule
