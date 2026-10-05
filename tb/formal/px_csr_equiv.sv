// px_csr_equiv: equivalence miter for the step 2.2a CSR split (SymbiYosys,
// tb/formal/px_csr_equiv.sby; DECISIONS.md D-032 item 5).
//
// u_new is the current px_csr (top plus sub-units). u_ref is the Phase 1 px_csr as it was
// before the split: scripts/formal.sh extracts rtl/core/px_csr.sv from the commit named in
// the .sby file's "formal-ref" line and renames the module px_csr_ref
// (sim/formal/ref/px_csr_ref.sv).
//
// Environment: every input is free in every cycle and shared by both instances, with no
// assumption at all (ex_op_i = 3, simultaneous trap/MRET/commit, any address). Reset is
// asserted in the first cycle; after that rst_ni is a free input too, so a reset at any
// time is included. Both instances get the same parameters: the core's defaults, or with
// ALT an MTVEC_RESET with its two low bits set and a nonzero MIMPID.
//
// Properties (every cycle, reset cycles included)
//   E1  all seven outputs are equal: id_illegal_o, ex_rdata_o, ex_wdata_o, ex_noinc_o,
//       mtvec_o, mepc_o, mstatus_mie_o
//   E2  (INDUCTION only) state correspondence: every register of u_ref equals the register
//       it was moved to in u_new.u_m. E2 makes the k-induction step hold, so the prove
//       task's result is unbounded; the bmc task checks E1 alone.

`timescale 1ns/1ps

module px_csr_equiv (
  input logic        clk_i,
  input logic        rst_free,
  input logic [11:0] id_addr_i,
  input logic        id_write_i,
  input logic [11:0] ex_addr_i,
  input logic [1:0]  ex_op_i,
  input logic [31:0] ex_operand_i,
  input logic        ex_write_i,
  input logic        ex_commit_i,
  input logic        retire_i,
  input logic        trap_i,
  input logic        trap_irq_i,
  input logic [4:0]  trap_cause_i,
  input logic [31:0] trap_pc_i,
  input logic [31:0] trap_tval_i,
  input logic        mret_i
);

`ifdef ALT
  localparam logic [31:0] RESET_VEC = 32'h8765_4323;
  localparam logic [31:0] IMPID     = 32'h5A5A_A5A5;
`else
  localparam logic [31:0] RESET_VEC = 32'h1000_0040;
  localparam logic [31:0] IMPID     = 32'd0;
`endif

  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = init ? 1'b0 : rst_free;

  logic        n_illegal, n_noinc, n_mie, r_illegal, r_noinc, r_mie;
  logic [31:0] n_rdata, n_wdata, n_mtvec, n_mepc, r_rdata, r_wdata, r_mtvec, r_mepc;

  px_csr #(.MTVEC_RESET(RESET_VEC), .MIMPID(IMPID)) u_new (
    .clk_i, .rst_ni,
    .id_addr_i, .id_write_i, .id_illegal_o(n_illegal),
    .ex_addr_i, .ex_op_i, .ex_operand_i, .ex_write_i, .ex_commit_i,
    .ex_rdata_o(n_rdata), .ex_wdata_o(n_wdata), .ex_noinc_o(n_noinc),
    .retire_i,
    .trap_i, .trap_irq_i, .trap_cause_i, .trap_pc_i, .trap_tval_i, .mret_i,
    .mtvec_o(n_mtvec), .mepc_o(n_mepc), .mstatus_mie_o(n_mie)
  );

  px_csr_ref #(.MTVEC_RESET(RESET_VEC), .MIMPID(IMPID)) u_ref (
    .clk_i, .rst_ni,
    .id_addr_i, .id_write_i, .id_illegal_o(r_illegal),
    .ex_addr_i, .ex_op_i, .ex_operand_i, .ex_write_i, .ex_commit_i,
    .ex_rdata_o(r_rdata), .ex_wdata_o(r_wdata), .ex_noinc_o(r_noinc),
    .retire_i,
    .trap_i, .trap_irq_i, .trap_cause_i, .trap_pc_i, .trap_tval_i, .mret_i,
    .mtvec_o(r_mtvec), .mepc_o(r_mepc), .mstatus_mie_o(r_mie)
  );

  always_comb begin
    // E1
    assert (n_illegal == r_illegal);
    assert (n_rdata   == r_rdata);
    assert (n_wdata   == r_wdata);
    assert (n_noinc   == r_noinc);
    assert (n_mtvec   == r_mtvec);
    assert (n_mepc    == r_mepc);
    assert (n_mie     == r_mie);
`ifdef INDUCTION
    // E2
    assert (u_new.u_m.mie_q         == u_ref.mie_q);
    assert (u_new.u_m.mpie_q        == u_ref.mpie_q);
    assert (u_new.u_m.mtvec_base_q  == u_ref.mtvec_base_q);
    assert (u_new.u_m.mscratch_q    == u_ref.mscratch_q);
    assert (u_new.u_m.mepc_q        == u_ref.mepc_q);
    assert (u_new.u_m.mcause_irq_q  == u_ref.mcause_irq_q);
    assert (u_new.u_m.mcause_code_q == u_ref.mcause_code_q);
    assert (u_new.u_m.mtval_q       == u_ref.mtval_q);
    assert (u_new.u_m.mcycle_lo_q   == u_ref.mcycle_lo_q);
    assert (u_new.u_m.mcycle_hi_q   == u_ref.mcycle_hi_q);
    assert (u_new.u_m.minstret_lo_q == u_ref.minstret_lo_q);
    assert (u_new.u_m.minstret_hi_q == u_ref.minstret_hi_q);
`endif
  end

  // Reachability of the interesting cases (the cover task)
  always_comb begin
    cover (!init && !rst_free);                    // a reset after the first cycle
    if (rst_ni) begin
      cover (ex_commit_i && ex_write_i && !trap_i && !mret_i && ex_addr_i == 12'hB02 && retire_i);
      cover (trap_i && mret_i && ex_commit_i && ex_write_i);
      cover (u_ref.mcycle_hi_q != 32'd0);          // a carry into mcycleh
    end
  end

endmodule
