// px_csr_clint_equiv: CLINT-mode equivalence miter for the step 2.2d CSR file (SymbiYosys,
// tb/formal/px_csr_clint_equiv.sby; DECISIONS.md D-035 item 8).
//
// u_new is the current px_csr (top, px_csr_m, px_csr_clic). u_ref is the step 2.2c px_csr:
// scripts/formal.sh extracts rtl/core/px_csr.sv and rtl/core/px_csr_m.sv from the commit
// named in the .sby file's "formal-ref" lines and renames the modules px_csr_ref and
// px_csr_m_ref (sim/formal/ref/).
//
// Environment: every input is free in every cycle and shared by both instances (u_ref gets
// trap cause bits 4:0; the inputs only u_new has, the CLIC winner, minhv and the
// instruction-form fields, are free as well). Reset is asserted in the first cycle; after
// that rst_ni is a free input too. Both instances get the same parameters: the core's
// defaults, or with ALT an MTVEC_RESET with its two low bits set and a nonzero MIMPID.
//
// Assumption A (the programs the claim is about: those that stay in CLINT mode and never use
// the CLIC CSRs):
//   A1  no ID address and no EX address is one of the new CSRs 0x307, 0x345, 0x347, 0x349,
//       0xFB1 (in the core, csr_addr is 0 for every non-CSR instruction, so this is "no CSR
//       instruction addresses them")
//   A2  no committed write of mtvec (no trap, no MRET in that cycle) writes the value 11 to
//       bits 1:0: CSRRW/CSRRWI or CSRRS/CSRRSI with operand bits 1:0 = 11 (in CLINT mode
//       mtvec reads 00 in those bits, so CSRRC(I) never produces 11)
// The necessity tasks drop one of them (define NO_A1 or NO_A2) and must fail (expect fail).
//
// Properties (every cycle, reset cycles included)
//   E1  the seven outputs both versions have are equal: id_illegal_o, ex_rdata_o,
//       ex_wdata_o, ex_noinc_o, mtvec_o, mepc_o, mstatus_mie_o; ex_wdata_o (the trace value
//       of a write, recorded only when the write commits) except for a mode-11 mtvec write
//       in EX, which A2 keeps from committing
//   E3  u_new's new outputs hold their CLINT values: clic_mode_o = 0, mil_o = 0,
//       mintthresh_o = 0, minhv_o = 0, claim_o = 0, no side-write slot
//   E2  (INDUCTION only) state correspondence: every register of u_ref equals the register
//       it moved to in u_new, and the new CLIC state is at its reset value (mode 00, mtvt,
//       mpil, minhv, mil, mintthresh 0). E2 makes the k-induction step hold, so the prove
//       task's result is unbounded; the bmc tasks check E1 and E3 alone.

`timescale 1ns/1ps

module px_csr_clint_equiv (
  input logic        clk_i,
  input logic        rst_free,
  input logic [11:0] id_addr_i,
  input logic        id_write_i,
  input logic [2:0]  id_op_i,
  input logic        id_rd_zero_i,
  input logic [4:0]  id_imm_i,
  input logic [11:0] ex_addr_i,
  input logic [1:0]  ex_op_i,
  input logic [31:0] ex_operand_i,
  input logic        ex_write_i,
  input logic        ex_commit_i,
  input logic        retire_i,
  input logic        trap_i,
  input logic        trap_irq_i,
  input logic [5:0]  trap_cause_i,
  input logic        trap_minhv_i,
  input logic [31:0] trap_pc_i,
  input logic [31:0] trap_tval_i,
  input logic        mret_i,
  input logic        irq_valid_i,
  input logic [5:0]  irq_id_i,
  input logic [7:0]  irq_level_i,
  input logic        irq_shv_i
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

  // ---- assumption A ----
  function automatic logic is_new(input logic [11:0] a);
    return a == 12'h307 || a == 12'h345 || a == 12'h347 || a == 12'h349 || a == 12'hFB1;
  endfunction
  always_comb begin
`ifndef NO_A1
    assume (!is_new(id_addr_i) && !is_new(ex_addr_i));
`endif
`ifndef NO_A2
    assume (!(ex_commit_i && !trap_i && !mret_i && ex_write_i && ex_addr_i == 12'h305 &&
              ex_op_i != 2'd2 && ex_operand_i[1:0] == 2'b11));
`endif
  end

  // the instruction in EX would write 11 to mtvec bits 1:0 (its trace value is recorded only
  // when it writes and commits)
  logic m11;
  assign m11 = ex_addr_i == 12'h305 && ex_op_i != 2'd2 && ex_operand_i[1:0] == 2'b11;

  logic         n_illegal, n_noinc, n_mie, r_illegal, r_noinc, r_mie;
  logic [31:0]  n_rdata, n_wdata, n_mtvec, n_mepc, r_rdata, r_wdata, r_mtvec, r_mepc;
  logic         n_clic, n_minhv, n_claim;
  logic [7:0]   n_mil, n_th;
  logic [3:0]   n_side_we;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [127:0] n_side_wd;
  logic [31:0]  n_tbl;
  logic [5:0]   n_claim_id;
  /* verilator lint_on UNUSEDSIGNAL */

  px_csr #(.MTVEC_RESET(RESET_VEC), .MIMPID(IMPID)) u_new (
    .clk_i, .rst_ni,
    .id_addr_i, .id_write_i, .id_op_i, .id_rd_zero_i, .id_imm_i, .id_illegal_o(n_illegal),
    .ex_addr_i, .ex_op_i, .ex_operand_i, .ex_write_i, .ex_commit_i,
    .ex_rdata_o(n_rdata), .ex_wdata_o(n_wdata), .ex_noinc_o(n_noinc),
    .side_we_o(n_side_we), .side_wdata_o(n_side_wd),
    .retire_i,
    .trap_i, .trap_irq_i, .trap_cause_i, .trap_minhv_i, .trap_pc_i, .trap_tval_i, .mret_i,
    .irq_valid_i, .irq_id_i, .irq_level_i, .irq_shv_i,
    .mtvec_o(n_mtvec), .mepc_o(n_mepc), .mstatus_mie_o(n_mie), .clic_mode_o(n_clic),
    .mil_o(n_mil), .mintthresh_o(n_th), .minhv_o(n_minhv), .tbl_addr_o(n_tbl),
    .claim_o(n_claim), .claim_id_o(n_claim_id)
  );

  px_csr_ref #(.MTVEC_RESET(RESET_VEC), .MIMPID(IMPID)) u_ref (
    .clk_i, .rst_ni,
    .id_addr_i, .id_write_i, .id_illegal_o(r_illegal),
    .ex_addr_i, .ex_op_i, .ex_operand_i, .ex_write_i, .ex_commit_i,
    .ex_rdata_o(r_rdata), .ex_wdata_o(r_wdata), .ex_noinc_o(r_noinc),
    .retire_i,
    .trap_i, .trap_irq_i, .trap_cause_i(trap_cause_i[4:0]), .trap_pc_i, .trap_tval_i, .mret_i,
    .mtvec_o(r_mtvec), .mepc_o(r_mepc), .mstatus_mie_o(r_mie)
  );

  always_comb begin
    // E1
    assert (n_illegal == r_illegal);
    assert (n_rdata   == r_rdata);
    // (the trace value of a mode-11 mtvec write differs, but such a write never commits, A2)
    if (!m11) assert (n_wdata == r_wdata);
    assert (n_noinc   == r_noinc);
    assert (n_mtvec   == r_mtvec);
    assert (n_mepc    == r_mepc);
    assert (n_mie     == r_mie);
    // E3
    assert (!n_clic && n_mil == 8'd0 && n_th == 8'd0 && !n_minhv && !n_claim && n_side_we == 4'd0);
`ifdef INDUCTION
    // E2
    assert (u_new.u_m.mie_q         == u_ref.u_m.mie_q);
    assert (u_new.u_m.mpie_q        == u_ref.u_m.mpie_q);
    assert (u_new.u_clic.base_q     == u_ref.u_m.mtvec_base_q);
    assert (u_new.u_m.mscratch_q    == u_ref.u_m.mscratch_q);
    assert (u_new.u_m.mepc_q        == u_ref.u_m.mepc_q);
    assert (u_new.u_clic.mc_irq_q   == u_ref.u_m.mcause_irq_q);
    assert (u_new.u_clic.exccode_q[4:0] == u_ref.u_m.mcause_code_q);
    assert (u_new.u_m.mtval_q       == u_ref.u_m.mtval_q);
    assert (u_new.u_m.mcycle_lo_q   == u_ref.u_m.mcycle_lo_q);
    assert (u_new.u_m.mcycle_hi_q   == u_ref.u_m.mcycle_hi_q);
    assert (u_new.u_m.minstret_lo_q == u_ref.u_m.minstret_lo_q);
    assert (u_new.u_m.minstret_hi_q == u_ref.u_m.minstret_hi_q);
    assert (!u_new.u_clic.mode_q && u_new.u_clic.mtvt_q == 26'd0 && u_new.u_clic.mpil_q == 8'd0 &&
            !u_new.u_clic.minhv_q && u_new.u_clic.mil_q == 8'd0 && u_new.u_clic.th_q == 8'd0);
`endif
  end

  // Reachability of the interesting cases (the cover task)
  always_comb begin
    cover (!init && !rst_free);                    // a reset after the first cycle
    if (rst_ni) begin
      cover (ex_commit_i && ex_write_i && !trap_i && !mret_i && ex_addr_i == 12'hB02 && retire_i);
      cover (trap_i && mret_i && ex_commit_i && ex_write_i);
      cover (u_ref.u_m.mcycle_hi_q != 32'd0);      // a carry into mcycleh
      cover (ex_commit_i && ex_write_i && !trap_i && !mret_i && ex_addr_i == 12'h305 &&
             ex_operand_i[1:0] == 2'b01);          // mode 01 legalized in both
      cover (trap_i && trap_irq_i && trap_cause_i[5] && trap_minhv_i && irq_valid_i);
    end
  end

endmodule
