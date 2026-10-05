// px_csr: CSR file top: sub-units, legality, read/write-data selection and trap/MRET
// routing (Phase 1 step 1.6; split into sub-units in Phase 2 step 2.2a).
//
// Implements PHASE2_ARCHITECTURE.md § 5 (CSR sub-unit interface, audit B-04) with the
// choices of DECISIONS.md D-032; the CSRs themselves follow D-022 (IMPLEMENTATION_GUIDE.md
// step 1.6, IMPLEMENTATION_CONTRACTS.md § 1: privileged manual 20240411, machine mode only;
// Zicsr 2.0). Behaviour is identical, cycle for cycle, to the Phase 1 px_csr (proven by
// tb/formal/px_csr_equiv.sby).
//
// Sub-units (NU = 1 now; each owns a set of addresses and their state):
//   0  px_csr_m   every D-022 CSR: mstatus, misa, mie/mip, mtvec, mstatush, mscratch, mepc,
//                 mcause, mtval, counters, hpm, PMP (read-only 0), IDs
// Later steps add px_csr_clic (2.2d), px_csr_px (2.3), px_csr_hwlp (2.5d), px_csr_pmp
// (2.6): one instance each, entry k of the per-unit vectors, NU + 1.
//
// Combining rules (D-032):
//   - exactly one unit hits an implemented address, none hits any other address (checked
//     in tb_px_csr over all 4096 addresses and by property H1 of tb/formal/px_csr_fv.sv);
//   - id_illegal_o: no unit hits, or the hitting unit rejects the access (a write attempt
//     to a read-only address, later reserved forms and privilege);
//   - ex_rdata_o, ex_wdata_o: OR over the units of the unit's value qualified by its EX
//     hit, i.e. the value of the hitting unit (0 when no unit hits);
//   - trap > MRET > write for every unit: the units see ex_commit_i && !trap_i && !mret_i
//     as their commit; trap_i/mret_i go to every unit holding trap state;
//   - mtvec_o, mepc_o, mstatus_mie_o, ex_noinc_o come from the owning unit (px_csr_m).
//
// Legality (id_*): decided in ID on the decoded address, so an illegal access is an
// ordinary illegal-instruction trap in EX with mtval = instruction bits.
//
// Access (ex_*): combinational read of the addressed CSR as seen by the instruction in
// EX; the write happens on the clock edge when ex_commit_i is set (the instruction has
// passed every older instruction and cannot trap any more). trap_i, mret_i and ex_commit_i
// are mutually exclusive by construction in px_core; otherwise trap_i wins, then mret_i,
// and the CSR write is dropped (counters then count normally).
//
// Latency: reads are combinational; every update is visible on the next cycle, i.e. to
// the next instruction in EX. Outputs mtvec_o and mepc_o are register outputs.

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

  // WB: an instruction retires and counts in minstret
  input  logic        retire_i,

  // Trap entry and return
  input  logic        trap_i,
  input  logic        trap_irq_i,     // interrupt bit of mcause (0 in Phase 1)
  input  logic [4:0]  trap_cause_i,
  input  logic [31:0] trap_pc_i,      // bit 0 is always 0 (IALIGN = 16); mepc[0] reads 0
  input  logic [31:0] trap_tval_i,
  input  logic        mret_i,

  output logic [31:0] mtvec_o,        // trap target (Direct mode: BASE)
  output logic [31:0] mepc_o,         // MRET target
  output logic        mstatus_mie_o   // for Phase 2 interrupt gating
);

  // ---------------------------------------------------------------------------
  // Per-unit signals (D-032): index 0 = px_csr_m
  // ---------------------------------------------------------------------------
  localparam int NU = 1;

  logic [NU-1:0]       id_hit_u, id_ill_u, ex_hit_u;
  logic [NU-1:0][31:0] ex_rdata_u, ex_wdata_u;

  // Commit seen by every unit: trap > MRET > write
  logic commit_u;
  assign commit_u = ex_commit_i && !trap_i && !mret_i;

  // ---------------------------------------------------------------------------
  // Unit 0: machine-mode CSRs (D-022)
  // ---------------------------------------------------------------------------
  px_csr_m #(.MTVEC_RESET(MTVEC_RESET), .MIMPID(MIMPID)) u_m (
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
    .trap_irq_i,
    .trap_cause_i,
    .trap_pc_i,
    .trap_tval_i,
    .mret_i,
    .mtvec_o,
    .mepc_o,
    .mstatus_mie_o
  );

  // ---------------------------------------------------------------------------
  // Combining
  // ---------------------------------------------------------------------------
  // No unit owns the address: illegal; otherwise the owning unit's verdict.
  assign id_illegal_o = !(|id_hit_u) || |(id_hit_u & id_ill_u);

  // Value of the unit that hits the EX address (0 when none does)
  always_comb begin
    ex_rdata_o = 32'd0;
    ex_wdata_o = 32'd0;
    for (int k = 0; k < NU; k++) begin
      if (ex_hit_u[k]) begin
        ex_rdata_o = ex_rdata_o | ex_rdata_u[k];
        ex_wdata_o = ex_wdata_o | ex_wdata_u[k];
      end
    end
  end

endmodule
