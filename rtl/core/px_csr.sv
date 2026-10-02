// px_csr: machine-mode CSR file, trap entry and MRET state (Phase 1, step 1.6).
//
// Implements IMPLEMENTATION_GUIDE.md step 1.6 and IMPLEMENTATION_CONTRACTS.md § 1 (RISC-V
// privileged manual release 20240411, machine mode only; Zicsr 2.0). Field choices,
// reset values and counter semantics are recorded in DECISIONS.md D-022.
//
// Implemented CSRs (every other address raises illegal instruction):
//   mstatus   0x300  MIE (3) and MPIE (7) writable; MPP (12:11) reads 11 (M is the only
//                    mode); MPRV, TW, SUM, MXR, TVM, TSR, FS, VS, XS, SD read-only 0
//   misa      0x301  0x4000_1104: MXL = 32, I, M and C (M since step 1.7, D-023);
//                    writes are ignored (WARL, fixed value)
//   mie, mip  0x304, 0x344  read-only 0: no interrupt can become pending before the
//                    Phase 2 CLIC ("bits of mie that are not writable must be read-only
//                    zero"); writes are ignored, not illegal
//   mtvec     0x305  BASE[31:2] writable; MODE reads 0 (Direct only; CLIC mode is Phase 2)
//   mstatush  0x310  read-only 0 (little-endian only: MBE = SBE = 0)
//   mscratch  0x340  32-bit read/write
//   mepc      0x341  bit 0 reads 0 (IALIGN = 16, C is always enabled)
//   mcause    0x342  interrupt bit 31 and exception code [4:0] kept (WLRL), others read 0
//   mtval     0x343  32-bit read/write
//   mcycle(h), minstret(h)  0xB00/0xB80, 0xB02/0xB82: 64-bit counters, see below
//   mhpmcounter3..31(h), mhpmevent3..31: read-only 0, writes ignored (legal per spec)
//   pmpcfg0..15, pmpaddr0..63  0x3A0..0x3AF, 0x3B0..0x3EF: read-only 0 (zero PMP entries
//                    until Phase 2 step 2.6; "all PMP CSR fields are WARL and may be
//                    read-only zero"), writes ignored
//   mvendorid, marchid, mimpid, mhartid, mconfigptr  0xF11..0xF15: read-only;
//                    0, 0, MIMPID, 0, 0. Any write attempt is illegal (addr[11:10] = 11)
//
// Legality (id_*): checked in ID on the decoded address, so an illegal access is an
// ordinary illegal-instruction trap in EX with mtval = instruction bits. An access is
// illegal when the address is not implemented, or when a write is attempted (decoder
// csr_write: always for CSRRW/CSRRWI, and for CSRRS/CSRRC(I) with a nonzero rs1 field or
// zimm, independent of the register's runtime value) to a read-only address.
//
// Access (ex_*): combinational read of the addressed CSR as seen by the instruction in
// EX; the write happens on the clock edge when ex_commit_i is set (the instruction has
// passed every older instruction and cannot trap any more), so each access has its
// side effects exactly once. The value written is RW: operand, RS: old | operand,
// RC: old & ~operand, then legalized per register.
//
// Counters (privileged manual: "Any CSR write takes effect after the writing instruction
// has otherwise completed"; Zicsr: a CSR write to instret "is done instead of the
// increment", so the value written is the value the following instruction reads):
//   mcycle   counts every clock cycle after reset. In a cycle where mcycle or mcycleh is
//            written, the written half takes the new value, the other half keeps its
//            value and there is no increment.
//   minstret counts retired instructions (retire_i, from WB). Reads in EX include an
//            older instruction retiring in the same cycle (program order). A write is
//            applied on top of that older increment; the writing instruction's own
//            retirement is not counted (the core suppresses it with ex_noinc_o).
//   The high halves carry from the low halves; writing one half never changes the other
//   except through that carry.
//
// Traps: trap_i writes mepc = trap_pc_i, mcause, mtval, MPIE = MIE, MIE = 0. MRET
// (mret_i) sets MIE = MPIE, MPIE = 1 (MPP stays M). trap_i, mret_i and ex_commit_i are
// mutually exclusive by construction in px_core; otherwise trap_i wins, then mret_i, and
// the CSR write is dropped (counters then count normally).
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
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] trap_pc_i,      // bit 0 is always 0 (IALIGN = 16); mepc[0] reads 0
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] trap_tval_i,
  input  logic        mret_i,

  output logic [31:0] mtvec_o,        // trap target (Direct mode: BASE)
  output logic [31:0] mepc_o,         // MRET target
  output logic        mstatus_mie_o   // for Phase 2 interrupt gating
);

  import px_pkg::*;

  // ---------------------------------------------------------------------------
  // Address decode (one function, used for the ID legality check and the EX read)
  // ---------------------------------------------------------------------------
  function automatic logic csr_exists(input logic [11:0] a);
    logic e;
    e = 1'b0;
    case (a)
      CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MTVEC, CSR_MSTATUSH,
      CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP,
      CSR_MCYCLE, CSR_MINSTRET, CSR_MCYCLEH, CSR_MINSTRETH,
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID, CSR_MCONFIGPTR: e = 1'b1;
      default: e = 1'b0;
    endcase
    if (a >= CSR_MHPMCOUNTER3  && a <= CSR_MHPMCOUNTER31)  e = 1'b1;
    if (a >= CSR_MHPMCOUNTER3H && a <= CSR_MHPMCOUNTER31H) e = 1'b1;
    if (a >= CSR_MHPMEVENT3    && a <= CSR_MHPMEVENT31)    e = 1'b1;
    if (a >= CSR_PMPCFG0       && a <= CSR_PMPADDR63)      e = 1'b1;
    return e;
  endfunction

  // Read-only address space (privileged manual: addr[11:10] = 11)
  assign id_illegal_o = !csr_exists(id_addr_i) || (id_write_i && id_addr_i[11:10] == 2'b11);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        mie_q, mpie_q;
  logic [29:0] mtvec_base_q;
  logic [31:0] mscratch_q, mtval_q;
  logic [30:0] mepc_q;          // mepc[31:1]
  logic        mcause_irq_q;
  logic [4:0]  mcause_code_q;
  logic [31:0] mcycle_lo_q, mcycle_hi_q, minstret_lo_q, minstret_hi_q;

  // Counter increments, split per half so the high adder waits only for an AND tree.
  logic [31:0] mcycle_lo_inc, mcycle_hi_inc, minstret_lo_inc, minstret_hi_inc;
  assign mcycle_lo_inc   = mcycle_lo_q + 32'd1;
  assign mcycle_hi_inc   = mcycle_hi_q + {31'd0, &mcycle_lo_q};
  assign minstret_lo_inc = minstret_lo_q + 32'd1;
  assign minstret_hi_inc = minstret_hi_q + {31'd0, &minstret_lo_q};

  // minstret including an older instruction retiring this cycle (program order)
  logic [31:0] instret_lo, instret_hi;
  assign instret_lo = retire_i ? minstret_lo_inc : minstret_lo_q;
  assign instret_hi = retire_i ? minstret_hi_inc : minstret_hi_q;

  logic [31:0] mstatus_val;
  assign mstatus_val = {19'd0, 2'b11, 3'd0, mpie_q, 3'd0, mie_q, 3'd0};

  // ---------------------------------------------------------------------------
  // EX read
  // ---------------------------------------------------------------------------
  always_comb begin
    case (ex_addr_i)
      CSR_MSTATUS:   ex_rdata_o = mstatus_val;
      CSR_MISA:      ex_rdata_o = 32'h4000_1104;
      CSR_MTVEC:     ex_rdata_o = {mtvec_base_q, 2'b00};
      CSR_MSCRATCH:  ex_rdata_o = mscratch_q;
      CSR_MEPC:      ex_rdata_o = {mepc_q, 1'b0};
      CSR_MCAUSE:    ex_rdata_o = {mcause_irq_q, 26'd0, mcause_code_q};
      CSR_MTVAL:     ex_rdata_o = mtval_q;
      CSR_MCYCLE:    ex_rdata_o = mcycle_lo_q;
      CSR_MCYCLEH:   ex_rdata_o = mcycle_hi_q;
      CSR_MINSTRET:  ex_rdata_o = instret_lo;
      CSR_MINSTRETH: ex_rdata_o = instret_hi;
      CSR_MIMPID:    ex_rdata_o = MIMPID;
      // mie, mip, mstatush, hpm counters/events, PMP, mvendorid, marchid, mhartid,
      // mconfigptr: 0 (unimplemented addresses never commit: they trap)
      default:       ex_rdata_o = 32'd0;
    endcase
  end

  // Value to write
  logic [31:0] wval;
  always_comb begin
    case (ex_op_i)
      CSR_RS:  wval = ex_rdata_o | ex_operand_i;
      CSR_RC:  wval = ex_rdata_o & ~ex_operand_i;
      default: wval = ex_operand_i;               // CSR_RW
    endcase
  end

  // Priority trap > MRET > write (never simultaneous in px_core; defined for every input).
  logic we;
  assign we = ex_commit_i && ex_write_i && !trap_i && !mret_i;

  assign ex_noinc_o = ex_write_i && (ex_addr_i == CSR_MINSTRET || ex_addr_i == CSR_MINSTRETH);

  // Legalized fields of the written value (continuous assigns: guide § 3.3)
  logic        w_mie, w_mpie, w_irq;
  logic [29:0] w_base;
  logic [30:0] w_epc;
  logic [4:0]  w_code;
  assign w_mie  = wval[MSTATUS_MIE];
  assign w_mpie = wval[MSTATUS_MPIE];
  assign w_base = wval[31:2];
  assign w_epc  = wval[31:1];
  assign w_irq  = wval[31];
  assign w_code = wval[4:0];

  // Value of the written CSR after the write, as a read would return it (WARL legalization
  // as in the update below; counters take the written value; ignored writes read back the
  // unchanged constant). Reported on the retirement interface (rvfi_csr_*).
  always_comb begin
    case (ex_addr_i)
      CSR_MSTATUS:   ex_wdata_o = {19'd0, 2'b11, 3'd0, w_mpie, 3'd0, w_mie, 3'd0};
      CSR_MISA:      ex_wdata_o = 32'h4000_1104;
      CSR_MTVEC:     ex_wdata_o = {w_base, 2'b00};
      CSR_MSCRATCH:  ex_wdata_o = wval;
      CSR_MEPC:      ex_wdata_o = {w_epc, 1'b0};
      CSR_MCAUSE:    ex_wdata_o = {w_irq, 26'd0, w_code};
      CSR_MTVAL:     ex_wdata_o = wval;
      CSR_MCYCLE, CSR_MCYCLEH, CSR_MINSTRET, CSR_MINSTRETH: ex_wdata_o = wval;
      default:       ex_wdata_o = 32'd0;    // read-only zero registers
    endcase
  end

  logic [30:0] trap_epc;
  assign trap_epc = trap_pc_i[31:1];

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mie_q         <= 1'b0;
      mpie_q        <= 1'b0;
      mtvec_base_q  <= MTVEC_RESET[31:2];
      mscratch_q    <= 32'd0;
      mepc_q        <= 31'd0;
      mcause_irq_q  <= 1'b0;
      mcause_code_q <= 5'd0;
      mtval_q       <= 32'd0;
    end else if (trap_i) begin
      mpie_q        <= mie_q;
      mie_q         <= 1'b0;
      mepc_q        <= trap_epc;
      mcause_irq_q  <= trap_irq_i;
      mcause_code_q <= trap_cause_i;
      mtval_q       <= trap_tval_i;
    end else if (mret_i) begin
      mie_q         <= mpie_q;
      mpie_q        <= 1'b1;
    end else if (we) begin
      // Other implemented addresses (misa, mie, mip, mstatush, hpm, PMP) ignore writes.
      case (ex_addr_i)
        CSR_MSTATUS:  begin mie_q <= w_mie; mpie_q <= w_mpie; end
        CSR_MTVEC:    mtvec_base_q <= w_base;
        CSR_MSCRATCH: mscratch_q   <= wval;
        CSR_MEPC:     mepc_q       <= w_epc;
        CSR_MCAUSE:   begin mcause_irq_q <= w_irq; mcause_code_q <= w_code; end
        CSR_MTVAL:    mtval_q      <= wval;
        default: ;
      endcase
    end
  end

  logic w_mcycle, w_mcycleh, w_minstret, w_minstreth;
  assign w_mcycle    = we && ex_addr_i == CSR_MCYCLE;
  assign w_mcycleh   = we && ex_addr_i == CSR_MCYCLEH;
  assign w_minstret  = we && ex_addr_i == CSR_MINSTRET;
  assign w_minstreth = we && ex_addr_i == CSR_MINSTRETH;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcycle_lo_q   <= 32'd0;
      mcycle_hi_q   <= 32'd0;
      minstret_lo_q <= 32'd0;
      minstret_hi_q <= 32'd0;
    end else begin
      if (w_mcycle)       mcycle_lo_q <= wval;
      else if (w_mcycleh) mcycle_hi_q <= wval;
      else begin
        mcycle_lo_q <= mcycle_lo_inc;
        mcycle_hi_q <= mcycle_hi_inc;
      end
      minstret_lo_q <= w_minstret  ? wval : instret_lo;
      minstret_hi_q <= w_minstreth ? wval : instret_hi;
    end
  end

  assign mtvec_o       = {mtvec_base_q, 2'b00};
  assign mepc_o        = {mepc_q, 1'b0};
  assign mstatus_mie_o = mie_q;

endmodule
