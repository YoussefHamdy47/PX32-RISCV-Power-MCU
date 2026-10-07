// px_csr_clic: CLIC CSR sub-unit of px_csr (Phase 2 step 2.2d).
//
// Implements the CSR side of the PX32 CLIC profile: pinned CLIC draft 0.9 (clic.adoc at
// 514ddb112c8f9418ca6850d90292d4c1f9807049, sections "CLIC CSRs", "CLIC Interrupt
// Operation", "smclicshv"), PHASE2_CLIC_MATRIX.md rows K-30..K-41, PHASE2_ARCHITECTURE.md
// §§ 1.2, 4.4, 4.6, 4.8 and § 5 (sub-unit interface). Choices and deviations: DECISIONS.md
// D-035 items 1-6 and 10 (cited below as D-035.n); the sub-unit rules are D-032's.
//
// Owned CSRs (this unit hits exactly these addresses):
//   mtvec        0x305  mode WARL {00, 11} (01, 10 -> 00); mode 00: base [31:2]; mode 11
//                       (CLIC mode): base [31:6], bits 5:2 read 0 (submode 0000). Reset:
//                       MTVEC_RESET[31:2], mode 00 (CLINT mode, K-05). In mode 11 the stored
//                       bits 5:2 are 0, so mtvec_o is OBASE or NBASE without a mode mux.
//   mtvt         0x307  [31:6] writable, [5:0] read 0; readable in both modes (K-32)
//   mcause       0x342  CLIC mode: {interrupt, minhv, mpp = 11, mpie = mstatus.MPIE, 000,
//                       mpil, 0000, 000000, exccode[5:0]}; CLINT mode: the D-022 format
//                       {interrupt, 26'd0, exccode[4:0]} (K-34). A CLIC-mode write of mpie is a
//                       side write of mstatus.MPIE (px_csr_m); mpp writes are ignored (M only).
//   mnxti        0x345  read: TBASE + 4 * id of the presented winner if it is valid, not
//                       vectored, above mpil and above mintthresh, in CLIC mode; else 0. With
//                       a write (CSRRSI/CSRRCI, uimm != 0): mstatus.MIE |= / &= ~uimm[3]
//                       (side write, also in CLINT mode), and with such a winner: mil = its
//                       level, mcause.exccode = its id, mcause.interrupt = 1, claim (K-35,
//                       K-37, K-75; D-035.10)
//   mintthresh   0x347  th [7:0]; reads 0 in CLINT mode (state kept) (K-39)
//   mscratchcswl 0x349  csrrw only: if CLIC mode and (mpil == 0) != (mil == 0), rd = mscratch
//                       and mscratch = rs1 (side write); else rd = rs1 (K-41)
//   mintstatus   0xFB1  {mil, 24'd0}, read-only (K-38); mil resets to 0
//
// ID legality (decided from the encoding, K-36): mnxti only as CSRRS rd, mnxti, x0, CSRRSI
// or CSRRCI with uimm bits 0, 2, 4 clear; mscratchcswl only as CSRRW with rd and rs1 not x0;
// a write attempt to mintstatus (address bits 11:10 = 11) is illegal.
//
// Traps and returns (K-54, K-56, K-57; D-035.5): in CLIC mode a trap writes mcause =
// {interrupt, minhv = trap_minhv_i, mpil = mil, exccode}, and an interrupt also sets
// mil = irq_level_i; in CLINT mode a trap writes interrupt and exccode only. MRET in CLIC
// mode sets mil = mpil (mpil unchanged). A mtvec write that leaves CLIC mode zeroes mpil
// and minhv. trap_i > mret_i > write (the top already removed trap and MRET cycles from
// ex_commit_i).
//
// Cross-unit writes (D-035.2): side_*_o request writes of mstatus.MIE, mstatus.MPIE and
// mscratch in px_csr_m. They are what the instruction in EX would write (not qualified with
// the commit); the top qualifies them. Trace slots (D-035.12): side_trace_we_o[k] and
// side_trace_*_o give the value after the write of mcause (slot 2) and mintstatus (slot 3);
// slots 0 (mstatus) and 1 (mscratch) are completed by the top from px_csr_m.
//
// Outputs to the core and the CLIC: mtvec_o, clic_mode_o, mil_o, mintthresh_o and minhv_o are
// register outputs (D-034 obligation O1: px_clic's request depends on mil, mintthresh and the
// mode combinationally); tbl_addr_o = TBASE + 4 * irq_id_i from the mtvt register and the
// CLIC's winner register; claim_o/claim_id_o: a committed mnxti write that found a winner,
// with that winner's id (O3).
//
// Latency: reads are combinational; every update is visible to the next instruction in EX.

`timescale 1ns/1ps

module px_csr_clic #(
  parameter logic [31:0] MTVEC_RESET = 32'h1000_0040
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ID: ownership and legality of the decoded access
  input  logic [11:0] id_addr_i,
  input  logic        id_write_i,
  input  logic [2:0]  id_op_i,        // {immediate form, px_pkg::csr_op_e}
  input  logic        id_rd_zero_i,
  input  logic [4:0]  id_imm_i,       // instruction bits 19:15: rs1 field or uimm
  output logic        id_hit_o,
  output logic        id_illegal_o,

  // EX: access by the CSR instruction in EX
  input  logic [11:0] ex_addr_i,
  input  logic [1:0]  ex_op_i,        // px_pkg::csr_op_e (plain bits: Icarus enum ports)
  input  logic [31:0] ex_operand_i,   // rs1 value or zimm
  input  logic        ex_write_i,     // decoder csr_write
  input  logic        ex_commit_i,    // the access completes this cycle (no trap, no MRET)
  output logic        ex_hit_o,
  output logic [31:0] ex_rdata_o,
  output logic [31:0] ex_wdata_o,     // value the addressed CSR holds after the write

  // px_csr_m state read by this unit, and the writes this unit requests there
  input  logic        m_mie_i,
  input  logic        m_mpie_i,
  input  logic [31:0] m_mscratch_i,
  output logic        side_mie_we_o,
  output logic        side_mie_o,
  output logic        side_mpie_we_o,
  output logic        side_mpie_o,
  output logic        side_mscratch_we_o,
  output logic [31:0] side_mscratch_o,
  // trace slots 2 (mcause) and 3 (mintstatus): written by this instruction, value after
  output logic        side_mcause_we_o,
  output logic [31:0] side_mcause_o,
  output logic        side_mintstatus_we_o,
  output logic [31:0] side_mintstatus_o,

  // Trap entry and return
  input  logic        trap_i,
  input  logic        trap_irq_i,
  input  logic [5:0]  trap_cause_i,
  input  logic        trap_minhv_i,   // table fetch fault (smclicshv)
  input  logic        mret_i,

  // Presented winner of the CLIC (px_clic register outputs)
  input  logic        irq_valid_i,
  input  logic [5:0]  irq_id_i,
  input  logic [7:0]  irq_level_i,
  input  logic        irq_shv_i,

  output logic [31:0] mtvec_o,        // trap target: OBASE (mode 00) or NBASE (mode 11)
  output logic        clic_mode_o,
  output logic [7:0]  mil_o,
  output logic [7:0]  mintthresh_o,
  output logic        minhv_o,
  output logic [31:0] tbl_addr_o,     // TBASE + 4 * irq_id_i
  output logic        claim_o,
  output logic [5:0]  claim_id_o
);

  import px_pkg::*;

  // ---------------------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------------------
  function automatic logic owns(input logic [11:0] a);
    return a == CSR_MTVEC || a == CSR_MTVT || a == CSR_MCAUSE || a == CSR_MNXTI ||
           a == CSR_MINTTHRESH || a == CSR_MSCRATCHCSWL || a == CSR_MINTSTATUS;
  endfunction

  assign id_hit_o = owns(id_addr_i);
  assign ex_hit_o = owns(ex_addr_i);

  // ID form rules (K-36, D-035.3)
  logic       id_imm_form;
  logic [1:0] id_cop;
  logic       mnxti_ok, cswl_ok;
  assign id_imm_form = id_op_i[2];
  assign id_cop      = id_op_i[1:0];
  assign mnxti_ok = (!id_imm_form && id_cop == CSR_RS && id_imm_i == 5'd0) ||
                    ( id_imm_form && (id_cop == CSR_RS || id_cop == CSR_RC) &&
                      !id_imm_i[0] && !id_imm_i[2] && !id_imm_i[4]);
  assign cswl_ok  = !id_imm_form && id_cop == CSR_RW && !id_rd_zero_i && id_imm_i != 5'd0;

  logic id_ro;                                    // read-only space (mintstatus)
  assign id_ro = id_addr_i[11:10] == 2'b11;

  always_comb begin
    case (id_addr_i)
      CSR_MNXTI:        id_illegal_o = !mnxti_ok;
      CSR_MSCRATCHCSWL: id_illegal_o = !cswl_ok;
      default:          id_illegal_o = id_write_i && id_ro;
    endcase
  end

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [29:0] base_q;          // mtvec[31:2]; bits 5:2 (base_q[3:0]) are 0 in CLIC mode
  logic        mode_q;          // 1 = CLIC mode (mtvec.mode = 11)
  logic [25:0] mtvt_q;          // mtvt[31:6]
  logic        mc_irq_q, minhv_q;
  logic [7:0]  mpil_q;
  logic [5:0]  exccode_q;
  logic [7:0]  mil_q, th_q;

  // ---------------------------------------------------------------------------
  // Derived values
  // ---------------------------------------------------------------------------
  // TBASE + 4 * id (mtvt is 64-byte aligned, the table spans 256 bytes)
  logic [25:0] tbl_hi;
  assign tbl_hi     = mtvt_q + {24'd0, irq_id_i[5:4]};
  assign tbl_addr_o = {tbl_hi, irq_id_i[3:0], 2'b00};

  // mnxti: one presented winner, compared with mpil (not mil) and mintthresh (D-035.10)
  logic nxt_ok;
  assign nxt_ok = mode_q && irq_valid_i && !irq_shv_i &&
                  (irq_level_i > mpil_q) && (irq_level_i > th_q);

  // mscratchcswl swap condition (in CLINT mode mil and mpil read as 0: no swap)
  logic cswl_swap;
  assign cswl_swap = mode_q && ((mpil_q == 8'd0) != (mil_q == 8'd0));

  // mcause as read: CLIC format {interrupt, minhv, mpp = 11, mpie, 000, mpil, 0000, 000000,
  // exccode} or CLINT format {interrupt, 26'd0, exccode[4:0]} (part-selects in continuous
  // assigns: IMPLEMENTATION_GUIDE.md § 3.3)
  logic [4:0]  exc5;
  logic [31:0] rd_mcause;
  assign exc5      = exccode_q[4:0];
  assign rd_mcause = mode_q ? {mc_irq_q, minhv_q, 2'b11, m_mpie_i, 3'b000, mpil_q, 10'd0, exccode_q}
                            : {mc_irq_q, 26'd0, exc5};

  // ---------------------------------------------------------------------------
  // EX read
  // ---------------------------------------------------------------------------
  always_comb begin
    case (ex_addr_i)
      CSR_MTVEC:        ex_rdata_o = {base_q, {2{mode_q}}};
      CSR_MTVT:         ex_rdata_o = {mtvt_q, 6'd0};
      CSR_MCAUSE:       ex_rdata_o = rd_mcause;
      CSR_MNXTI:        ex_rdata_o = nxt_ok ? tbl_addr_o : 32'd0;
      CSR_MINTTHRESH:   ex_rdata_o = mode_q ? {24'd0, th_q} : 32'd0;
      CSR_MSCRATCHCSWL: ex_rdata_o = cswl_swap ? m_mscratch_i : ex_operand_i;
      CSR_MINTSTATUS:   ex_rdata_o = {mil_q, 24'd0};
      default:          ex_rdata_o = 32'd0;     // other units' and unimplemented addresses
    endcase
  end

  // Value to write (read-modify-write of the read value; mnxti's target is mstatus, below)
  logic [31:0] wval;
  always_comb begin
    case (ex_op_i)
      CSR_RS:  wval = ex_rdata_o | ex_operand_i;
      CSR_RC:  wval = ex_rdata_o & ~ex_operand_i;
      default: wval = ex_operand_i;               // CSR_RW
    endcase
  end

  // Fields of the written value
  logic        w_clic;                            // a mtvec write selects CLIC mode
  logic [29:0] w_base;
  logic [25:0] w_hi6;                             // value[31:6]
  logic        w_irq, w_inhv, w_mpie;
  logic [7:0]  w_pil, w_th;
  logic [5:0]  w_code;
  logic [4:0]  w_code5;
  assign w_clic  = wval[1:0] == 2'b11;
  assign w_hi6   = wval[31:6];
  assign w_base  = w_clic ? {w_hi6, 4'b0000} : wval[31:2];
  assign w_irq   = wval[31];
  assign w_inhv  = wval[30];
  assign w_mpie  = wval[27];
  assign w_pil   = wval[23:16];
  assign w_th    = wval[7:0];
  assign w_code  = wval[5:0];
  assign w_code5 = wval[4:0];

  // mcause after a write (as a read returns it), after an mnxti claim, and as it reads now
  logic [31:0] wd_mcause, claim_mcause;
  assign wd_mcause    = mode_q ? {w_irq, w_inhv, 2'b11, w_mpie, 3'b000, w_pil, 10'd0, w_code}
                               : {w_irq, 26'd0, w_code5};
  assign claim_mcause = {1'b1, minhv_q, 2'b11, m_mpie_i, 3'b000, mpil_q, 10'd0, irq_id_i};

  // mnxti: mstatus.MIE after the read-modify-write with uimm (only uimm bit 3 reaches MIE)
  logic nxt_mie;
  assign nxt_mie = (ex_op_i == CSR_RC) ? (m_mie_i && !ex_operand_i[3]) : (m_mie_i || ex_operand_i[3]);

  logic is_mtvec, is_mcause, is_mnxti, is_cswl;
  assign is_mtvec  = ex_addr_i == CSR_MTVEC;
  assign is_mcause = ex_addr_i == CSR_MCAUSE;
  assign is_mnxti  = ex_addr_i == CSR_MNXTI;
  assign is_cswl   = ex_addr_i == CSR_MSCRATCHCSWL;

  // Value of the addressed CSR after the write, as a read returns it (retirement trace);
  // mnxti and mscratchcswl have no state of their own: 0 (D-035.12)
  always_comb begin
    case (ex_addr_i)
      CSR_MTVEC:      ex_wdata_o = {w_base, {2{w_clic}}};
      CSR_MTVT:       ex_wdata_o = {w_hi6, 6'd0};
      CSR_MCAUSE:     ex_wdata_o = wd_mcause;
      CSR_MINTTHRESH: ex_wdata_o = mode_q ? {24'd0, w_th} : 32'd0;
      CSR_MINTSTATUS: ex_wdata_o = {mil_q, 24'd0};          // read-only (a write is illegal)
      default:        ex_wdata_o = 32'd0;
    endcase
  end

  // Side writes (what this instruction writes in px_csr_m if it commits) and trace slots
  logic nxt_claim;                                // an mnxti write that claims the winner
  logic leave_clic;                               // a mtvec write that leaves CLIC mode
  assign nxt_claim  = ex_write_i && is_mnxti && nxt_ok;
  assign leave_clic = ex_write_i && is_mtvec && mode_q && !w_clic;

  assign side_mie_we_o      = ex_write_i && is_mnxti;
  assign side_mie_o         = nxt_mie;
  assign side_mpie_we_o     = ex_write_i && is_mcause && mode_q;
  assign side_mpie_o        = w_mpie;
  assign side_mscratch_we_o = ex_write_i && is_cswl && cswl_swap;
  assign side_mscratch_o    = ex_operand_i;

  assign side_mcause_we_o     = nxt_claim || leave_clic;
  assign side_mcause_o        = nxt_claim ? claim_mcause : {mc_irq_q, 26'd0, exc5};   // CLINT format after leaving
  assign side_mintstatus_we_o = nxt_claim;
  assign side_mintstatus_o    = {irq_level_i, 24'd0};

  logic we;
  assign we = ex_commit_i && ex_write_i;

  assign claim_o    = we && is_mnxti && nxt_ok;
  assign claim_id_o = irq_id_i;

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      base_q    <= MTVEC_RESET[31:2];
      mode_q    <= 1'b0;
      mtvt_q    <= 26'd0;
      mc_irq_q  <= 1'b0;
      minhv_q   <= 1'b0;
      mpil_q    <= 8'd0;
      exccode_q <= 6'd0;
      mil_q     <= 8'd0;
      th_q      <= 8'd0;
    end else if (trap_i) begin
      mc_irq_q  <= trap_irq_i;
      exccode_q <= trap_cause_i;
      if (mode_q) begin
        minhv_q <= trap_minhv_i;
        mpil_q  <= mil_q;
        if (trap_irq_i) mil_q <= irq_level_i;
      end
    end else if (mret_i) begin
      if (mode_q) mil_q <= mpil_q;
    end else if (we) begin
      case (ex_addr_i)
        CSR_MTVEC: begin
          base_q <= w_base;
          mode_q <= w_clic;
          if (mode_q && !w_clic) begin     // leaving CLIC mode zeroes pil and inhv
            mpil_q  <= 8'd0;
            minhv_q <= 1'b0;
          end
        end
        CSR_MTVT:       mtvt_q <= w_hi6;
        CSR_MCAUSE: begin
          mc_irq_q <= w_irq;
          if (mode_q) begin
            minhv_q   <= w_inhv;
            mpil_q    <= w_pil;
            exccode_q <= w_code;
          end else begin
            exccode_q <= {1'b0, w_code5};
          end
        end
        CSR_MNXTI: if (nxt_ok) begin
          mil_q     <= irq_level_i;
          exccode_q <= irq_id_i;
          mc_irq_q  <= 1'b1;
        end
        CSR_MINTTHRESH: th_q <= w_th;
        default: ;                          // mscratchcswl: side write only; mintstatus: read-only
      endcase
    end
  end

  assign mtvec_o      = {base_q, 2'b00};
  assign clic_mode_o  = mode_q;
  assign mil_o        = mil_q;
  assign mintthresh_o = th_q;
  assign minhv_o      = minhv_q;

endmodule
