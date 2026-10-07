// px_csr: CSR file top: sub-units, legality, read/write-data selection, trap/MRET routing
// and cross-unit side writes (Phase 1 step 1.6; split into sub-units in Phase 2 step 2.2a;
// CLIC unit added in step 2.2d).
//
// Implements PHASE2_ARCHITECTURE.md § 5 (CSR sub-unit interface, audit B-04) with the
// choices of DECISIONS.md D-032 and D-035; the machine CSRs follow D-022, the CLIC CSRs the
// pinned CLIC draft 0.9 (PHASE2_CLIC_MATRIX.md § 3). In CLINT mode (mtvec.mode = 00, the
// reset state) and for programs that never access the CLIC CSRs, behaviour is identical,
// cycle for cycle, to the step 2.2c px_csr (proven by tb/formal/px_csr_clint_equiv.sby under
// the assumption stated there, D-035 item 8).
//
// Sub-units (NU = 2; each owns a set of addresses and their state):
//   0  px_csr_m     mstatus, misa, mie/mip, mstatush, mscratch, mepc, mtval, counters, hpm,
//                   PMP (read-only 0), IDs (D-022)
//   1  px_csr_clic  mtvec, mtvt, mcause, mnxti, mintthresh, mscratchcswl, mintstatus
//                   (D-035); mscratchcsw (0x348) has no owner until step 2.6
// Later steps add px_csr_px (2.3), px_csr_hwlp (2.5d), px_csr_pmp (2.6).
//
// Combining rules (D-032):
//   - exactly one unit hits an implemented address, none hits any other address (checked
//     in tb_px_csr over all 4096 addresses and by property H1 of tb/formal/px_csr_fv.sv);
//   - id_illegal_o: no unit hits, or the hitting unit rejects the access (a write attempt
//     to a read-only address, reserved instruction forms of mnxti and mscratchcswl);
//   - ex_rdata_o, ex_wdata_o: OR over the units; every unit drives 0 at the addresses it
//     does not own (checked by tb_px_csr and property H2 of px_csr_fv), so this is the
//     value of the hitting unit (0 when no unit hits);
//   - trap > MRET > write for every unit: the units see ex_commit_i && !trap_i && !mret_i
//     as their commit; trap_i/mret_i go to every unit holding trap state;
//   - side writes (D-035 item 2): px_csr_clic requests writes of mstatus.MIE, mstatus.MPIE
//     and mscratch in px_csr_m; the top qualifies them with the same commit and routes them.
//
// Legality (id_*): decided in ID on the decoded encoding (address, write attempt, form
// fields), so an illegal access is an ordinary illegal-instruction trap in EX with mtval =
// instruction bits.
//
// Access (ex_*): combinational read of the addressed CSR as seen by the instruction in
// EX; the write happens on the clock edge when ex_commit_i is set (the instruction has
// passed every older instruction and cannot trap any more). trap_i, mret_i and ex_commit_i
// are mutually exclusive by construction in px_core; otherwise trap_i wins, then mret_i,
// and the CSR write (with its side writes and the mnxti claim) is dropped.
//
// Retirement trace (D-035 item 12): ex_wdata_o is the addressed CSR after the write;
// side_we_o/side_wdata_o report writes to other CSRs in four fixed slots, slot k in
// side_wdata_o[32k +: 32]: 0 mstatus, 1 mscratch, 2 mcause, 3 mintstatus. Like ex_wdata_o
// they describe what the instruction in EX writes if it commits.
//
// Latency: reads are combinational; every update is visible on the next cycle, i.e. to
// the next instruction in EX. mtvec_o, mepc_o, mstatus_mie_o, clic_mode_o, mil_o,
// mintthresh_o and minhv_o are register outputs.

`timescale 1ns/1ps

module px_csr #(
  parameter logic [31:0] MTVEC_RESET = 32'h1000_0040,
  parameter logic [31:0] MIMPID      = 32'd0
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ID: legality of the decoded access
  input  logic [11:0] id_addr_i,
  input  logic        id_write_i,
  input  logic [2:0]  id_op_i,        // {immediate form, csr_op}
  input  logic        id_rd_zero_i,
  input  logic [4:0]  id_imm_i,       // instruction bits 19:15 (rs1 field or uimm)
  output logic        id_illegal_o,

  // EX: access by the CSR instruction in EX
  input  logic [11:0] ex_addr_i,
  input  logic [1:0]  ex_op_i,        // px_pkg::csr_op_e (plain bits: Icarus enum ports)
  input  logic [31:0] ex_operand_i,   // rs1 value or zimm
  input  logic        ex_write_i,     // decoder csr_write
  input  logic        ex_commit_i,    // the access completes this cycle
  output logic [31:0] ex_rdata_o,
  output logic [31:0] ex_wdata_o,     // value the CSR holds after this write (legalized;
                                      // for the retirement trace, meaningful when written)
  output logic        ex_noinc_o,     // this access writes minstret/minstreth
  output logic [3:0]  side_we_o,      // writes of other CSRs (trace slots, see above)
  output logic [127:0] side_wdata_o,

  // WB: an instruction retires and counts in minstret
  input  logic        retire_i,

  // Trap entry and return
  input  logic        trap_i,
  input  logic        trap_irq_i,     // interrupt bit of mcause
  input  logic [5:0]  trap_cause_i,   // exception code or interrupt id
  input  logic        trap_minhv_i,   // vector table fetch fault (smclicshv)
  input  logic [31:0] trap_pc_i,      // bit 0 is always 0 (IALIGN = 16); mepc[0] reads 0
  input  logic [31:0] trap_tval_i,
  input  logic        mret_i,

  // Presented winner of the CLIC (px_clic register outputs: mnxti, mil at a take)
  input  logic        irq_valid_i,
  input  logic [5:0]  irq_id_i,
  input  logic [7:0]  irq_level_i,
  input  logic        irq_shv_i,

  output logic [31:0] mtvec_o,        // trap target (OBASE, or NBASE in CLIC mode)
  output logic [31:0] mepc_o,         // MRET target
  output logic        mstatus_mie_o,  // interrupt eligibility
  output logic        clic_mode_o,    // mtvec.mode = 11
  output logic [7:0]  mil_o,
  output logic [7:0]  mintthresh_o,
  output logic        minhv_o,        // MRET refetches the vector table entry at mepc
  output logic [31:0] tbl_addr_o,     // TBASE + 4 * irq_id_i
  output logic        claim_o,        // a committed mnxti write claimed the winner
  output logic [5:0]  claim_id_o
);

  // ---------------------------------------------------------------------------
  // Per-unit signals (D-032): index 0 = px_csr_m, 1 = px_csr_clic
  // ---------------------------------------------------------------------------
  localparam int NU = 2;

  logic [NU-1:0]       id_hit_u, id_ill_u;
  logic [NU-1:0][31:0] ex_rdata_u, ex_wdata_u;
  // EX ownership: read only by the ownership checks (tb_px_csr, px_csr_fv H1/H2)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NU-1:0]       ex_hit_u;
  /* verilator lint_on UNUSEDSIGNAL */

  // Commit seen by every unit: trap > MRET > write
  logic commit_u;
  assign commit_u = ex_commit_i && !trap_i && !mret_i;

  // Side writes (requested by px_csr_clic, applied in px_csr_m with the commit)
  logic        s_mie_we, s_mie, s_mpie_we, s_mpie, s_msc_we;
  logic [31:0] s_msc, s_mstatus, s_mcause, s_mintstatus;
  logic        s_mcause_we, s_mintstatus_we;
  logic        m_mpie;
  logic [31:0] m_mscratch;

  // ---------------------------------------------------------------------------
  // Unit 0: machine-mode CSRs (D-022)
  // ---------------------------------------------------------------------------
  px_csr_m #(.MIMPID(MIMPID)) u_m (
    .clk_i, .rst_ni,
    .id_addr_i,
    .id_write_i,
    .id_hit_o      (id_hit_u[0]),
    .id_illegal_o  (id_ill_u[0]),
    .ex_addr_i,
    .ex_op_i,
    .ex_operand_i,
    .ex_write_i,
    .ex_commit_i   (commit_u),
    .ex_hit_o      (ex_hit_u[0]),
    .ex_rdata_o    (ex_rdata_u[0]),
    .ex_wdata_o    (ex_wdata_u[0]),
    .ex_noinc_o,
    .retire_i,
    .trap_i,
    .trap_pc_i,
    .trap_tval_i,
    .mret_i,
    .side_mie_we_i      (commit_u && s_mie_we),
    .side_mie_i         (s_mie),
    .side_mpie_we_i     (commit_u && s_mpie_we),
    .side_mpie_i        (s_mpie),
    .side_mscratch_we_i (commit_u && s_msc_we),
    .side_mscratch_i    (s_msc),
    .mepc_o,
    .mstatus_mie_o,
    .mstatus_mpie_o     (m_mpie),
    .mscratch_o         (m_mscratch)
  );

  // ---------------------------------------------------------------------------
  // Unit 1: CLIC CSRs (D-035)
  // ---------------------------------------------------------------------------
  px_csr_clic #(.MTVEC_RESET(MTVEC_RESET)) u_clic (
    .clk_i, .rst_ni,
    .id_addr_i,
    .id_write_i,
    .id_op_i,
    .id_rd_zero_i,
    .id_imm_i,
    .id_hit_o      (id_hit_u[1]),
    .id_illegal_o  (id_ill_u[1]),
    .ex_addr_i,
    .ex_op_i,
    .ex_operand_i,
    .ex_write_i,
    .ex_commit_i   (commit_u),
    .ex_hit_o      (ex_hit_u[1]),
    .ex_rdata_o    (ex_rdata_u[1]),
    .ex_wdata_o    (ex_wdata_u[1]),
    .m_mie_i       (mstatus_mie_o),
    .m_mpie_i      (m_mpie),
    .m_mscratch_i  (m_mscratch),
    .side_mie_we_o      (s_mie_we),
    .side_mie_o         (s_mie),
    .side_mpie_we_o     (s_mpie_we),
    .side_mpie_o        (s_mpie),
    .side_mscratch_we_o (s_msc_we),
    .side_mscratch_o    (s_msc),
    .side_mcause_we_o     (s_mcause_we),
    .side_mcause_o        (s_mcause),
    .side_mintstatus_we_o (s_mintstatus_we),
    .side_mintstatus_o    (s_mintstatus),
    .trap_i,
    .trap_irq_i,
    .trap_cause_i,
    .trap_minhv_i,
    .mret_i,
    .irq_valid_i,
    .irq_id_i,
    .irq_level_i,
    .irq_shv_i,
    .mtvec_o,
    .clic_mode_o,
    .mil_o,
    .mintthresh_o,
    .minhv_o,
    .tbl_addr_o,
    .claim_o,
    .claim_id_o
  );

  // ---------------------------------------------------------------------------
  // Combining
  // ---------------------------------------------------------------------------
  // No unit owns the address: illegal; otherwise the owning unit's verdict.
  assign id_illegal_o = !(|id_hit_u) || |(id_hit_u & id_ill_u);

  // Value of the unit that hits the EX address: a unit drives 0 at every address it does not
  // own, so the OR of all units is the owner's value (0 when no unit owns the address). No
  // hit qualification here: it would add a gate level to the CSR read path into WB (D-032).
  always_comb begin
    ex_rdata_o = 32'd0;
    ex_wdata_o = 32'd0;
    for (int k = 0; k < NU; k++) begin
      ex_rdata_o = ex_rdata_o | ex_rdata_u[k];
      ex_wdata_o = ex_wdata_o | ex_wdata_u[k];
    end
  end

  // Trace slots of the side writes (D-035 item 12); mstatus as it reads after the write
  assign s_mstatus    = {19'd0, 2'b11, 3'd0, s_mpie_we ? s_mpie : m_mpie, 3'd0,
                         s_mie_we ? s_mie : mstatus_mie_o, 3'd0};
  assign side_we_o    = {s_mintstatus_we, s_mcause_we, s_msc_we, s_mie_we || s_mpie_we};
  assign side_wdata_o = {s_mintstatus, s_mcause, s_msc, s_mstatus};

endmodule
