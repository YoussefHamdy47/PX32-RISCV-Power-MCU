// px_csr_fv: formal harness for px_csr (SymbiYosys, tb/formal/px_csr.sby; audit D-10).
//
// Environment: every px_csr input is arbitrary in every cycle (trap_i, mret_i and the
// commit may coincide: px_csr defines trap > MRET > write for every input), except
//   E1  ex_op_i is one of the three Zicsr operations (the decoder emits nothing else)
//   E2  (step 2.2d) an mnxti write is CSRRSI or CSRRCI with a legal uimm, and an
//       mscratchcswl write is CSRRW: the other forms are illegal in ID (K-36) and never
//       reach EX as a write that can commit
// Reset in the first cycle only.
//
// Reference model: the CSR file of DECISIONS.md D-022, written in this harness from the
// decision text (field positions from the privileged manual 20240411), not from px_csr:
// mstatus MIE/MPIE, mtvec, mscratch, mepc (bit 0 zero), mcause, mtval, 64-bit mcycle/minstret
// with the D-022 write/increment rules, constants for every read-only or read-only-zero
// address. Since step 2.2d also the CLIC CSRs, written from PHASE2_CLIC_MATRIX.md § 3
// (K-30..K-41) and D-035 items 4, 5 and 10: mtvec mode WARL {00, 11}, mtvt, mcause in CLIC
// and CLINT format with the mpp/mpie aliases and the zeroing of mpil/minhv when CLIC mode is
// left, mnxti, mintthresh, mscratchcswl, mintstatus, CLIC-mode trap entry and MRET. Register
// numbers are written as literals.
//
// Properties
//   A1  every implemented address reads as the model (ex_rdata_o)
//   A2  mtvec_o, mepc_o, mstatus_mie_o and the CLIC outputs (clic_mode_o, mil_o,
//       mintthresh_o, minhv_o, tbl_addr_o) equal the model
//   A3  id_illegal_o is exactly "address not implemented, or a write attempt to an
//       address with bits 11:10 = 11, or a reserved form of mnxti or mscratchcswl"
//   A4  ex_wdata_o (the retirement-trace value) is the value the CSR holds after the
//       write, as the model legalizes it, for every implemented address that can be
//       written (a write attempt to bits 11:10 = 11 is illegal and never retires)
//   A5  ex_noinc_o exactly for a write attempt to minstret/minstreth
//   B1  mepc_o[0] = 0, mtvec_o[1:0] = 0, and a read of mepc/mtvec/mcause shows the same
//   B2  read-only CSRs are constant: misa 0x4000_1106, mimpid MIMPID, the rest 0; mstatus
//       reads MPP = 11 and 0 outside MIE, MPIE, MPP
//   B3  no architectural CSR changes unless a commit with a write, a trap or an MRET
//       happened in the cycle before (the counters excepted)
//   B4  trap > MRET > write: after trap_i, mepc/mcause/mtval hold the trap values,
//       MIE = 0 and MPIE = the old MIE, whatever MRET or commit did; after mret_i without
//       trap_i, MIE = the old MPIE and MPIE = 1, and the write is dropped
//   C1  (step 2.2d) claim_o exactly for a committed mnxti write (no trap, no MRET) while
//       the model's mnxti condition holds, with claim_id_o = the presented id; whenever it
//       claims, the value for rd is TBASE + 4 * claim id (the read value and the claim name
//       the same winner, D-035 item 10)
//   C2  (step 2.2d) the side-write trace slots (side_we_o, side_wdata_o) report exactly
//       the other CSRs the instruction in EX writes, with their values after the write
//   C3  (step 2.2d) in CLINT mode mnxti reads 0 and never claims, mintthresh reads 0 and
//       mscratchcswl never swaps
//   H1  (step 2.2a, D-032) sub-unit ownership: at most one bit of the top's per-unit hit
//       vectors (dut.id_hit_u, dut.ex_hit_u) is set, and one is set exactly when the
//       model implements the address (ID and EX side)
//   H2  (step 2.2a, D-032) a sub-unit that does not own the EX address drives 0 on its
//       read and write-back data (the top ORs the units' values)
// B1-B4 and C3 follow from A1-A2 and are kept as separate, model-free statements. The prove
// task (k-induction) also asserts that px_csr's state registers equal the model (I1), which
// makes the induction step hold, so the result is unbounded.
// Since step 2.2a px_csr is a top with sub-units (D-032); since step 2.2d (D-035) mtvec and
// mcause live in px_csr_clic (instance dut.u_clic), the other D-022 state in px_csr_m
// (dut.u_m).
// Tasks: bmc (depth 12), prove (k-induction), cover (a committed write of each writable
// CSR, a trap, an MRET, both counter carries, minstret written while an older instruction
// retires; CLIC mode entered and left, an mnxti claim, a swap, a CLIC-mode interrupt entry,
// a table-fault trap, a CLIC-mode MRET).

`timescale 1ns/1ps

module px_csr_fv (
  input logic        clk_i,
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

  localparam logic [31:0] RESET_VEC = 32'h1000_0040;
  localparam logic [31:0] IMPID     = 32'h0000_5A5A;   // nonzero, so it is observable
  // px_csr's number of sub-units (its localparam NU, D-032); keep equal when a unit is
  // added (yosys-slang does not accept $bits on the hierarchical dut.ex_hit_u)
  localparam int          NU        = 2;

  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = !init;

  logic         id_illegal, noinc, mie_o, clic_o, minhv_o, claim_o;
  logic [31:0]  rdata, wdata, mtvec_o, mepc_o, tbl_o;
  logic [7:0]   mil_o, th_o;
  logic [5:0]   claim_id_o;
  logic [3:0]   side_we;
  logic [127:0] side_wd;

  px_csr #(.MTVEC_RESET(RESET_VEC), .MIMPID(IMPID)) dut (
    .clk_i, .rst_ni,
    .id_addr_i, .id_write_i, .id_op_i, .id_rd_zero_i, .id_imm_i, .id_illegal_o(id_illegal),
    .ex_addr_i, .ex_op_i, .ex_operand_i, .ex_write_i, .ex_commit_i,
    .ex_rdata_o(rdata), .ex_wdata_o(wdata), .ex_noinc_o(noinc),
    .side_we_o(side_we), .side_wdata_o(side_wd),
    .retire_i,
    .trap_i, .trap_irq_i, .trap_cause_i, .trap_minhv_i, .trap_pc_i, .trap_tval_i, .mret_i,
    .irq_valid_i, .irq_id_i, .irq_level_i, .irq_shv_i,
    .mtvec_o, .mepc_o, .mstatus_mie_o(mie_o), .clic_mode_o(clic_o), .mil_o, .mintthresh_o(th_o),
    .minhv_o, .tbl_addr_o(tbl_o), .claim_o, .claim_id_o
  );

  // E1, E2
  always_comb begin
    assume (ex_op_i != 2'd3);
    if (ex_addr_i == 12'h345 && ex_write_i)
      assume (ex_op_i != 2'd0 && ex_operand_i[31:5] == 27'd0 && !ex_operand_i[0] &&
              !ex_operand_i[2] && !ex_operand_i[4]);
    if (ex_addr_i == 12'h349 && ex_write_i) assume (ex_op_i == 2'd0);
  end

  // -------------------------------------------------------------------------
  // Reference model (D-022; CLIC CSRs from the matrix and D-035)
  // -------------------------------------------------------------------------
  function automatic logic implemented(input logic [11:0] a);
    return a == 12'h300 || a == 12'h301 || a == 12'h304 || a == 12'h305 || a == 12'h310 ||
           a == 12'h340 || a == 12'h341 || a == 12'h342 || a == 12'h343 || a == 12'h344 ||
           a == 12'hB00 || a == 12'hB02 || a == 12'hB80 || a == 12'hB82 ||
           (a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'hB83 && a <= 12'hB9F) ||
           (a >= 12'h323 && a <= 12'h33F) || (a >= 12'h3A0 && a <= 12'h3EF) ||
           (a >= 12'hF11 && a <= 12'hF15) ||
           a == 12'h307 || a == 12'h345 || a == 12'h347 || a == 12'h349 || a == 12'hFB1;
  endfunction

  // reserved instruction forms (K-36): op = {imm form, csr op}
  function automatic logic reserved_form(input logic [11:0] a, input logic [2:0] op,
                                         input logic rdz, input logic [4:0] imm);
    if (a == 12'h345)
      return !((op == 3'b001 && imm == 5'd0) ||
               ((op == 3'b101 || op == 3'b110) && imm[0] == 1'b0 && imm[2] == 1'b0 && imm[4] == 1'b0));
    if (a == 12'h349)
      return !(op == 3'b000 && !rdz && imm != 5'd0);
    return 1'b0;
  endfunction

  logic        m_mie, m_mpie, m_irq, m_inhv, m_clic;
  logic [31:0] m_mtvec, m_mscratch, m_mepc, m_mtval, m_mtvt;
  logic [5:0]  m_code;
  logic [7:0]  m_pil, m_mil, m_th;
  logic [63:0] m_cycle, m_instret;

  logic [63:0] instret_now;                       // includes an older retirement this cycle
  assign instret_now = m_instret + {63'd0, retire_i};

  // mnxti condition and table address (draft smclicshv pseudo-code; D-035 item 10)
  logic        m_nxt;
  logic [31:0] m_tbl;
  logic        m_swap;
  assign m_nxt  = m_clic && irq_valid_i && !irq_shv_i && irq_level_i > m_pil && irq_level_i > m_th;
  assign m_tbl  = m_mtvt + {24'd0, irq_id_i, 2'b00};
  assign m_swap = m_clic && ((m_pil == 8'd0) != (m_mil == 8'd0));

  logic [31:0] m_mcause;
  assign m_mcause = m_clic ? {m_irq, m_inhv, 2'b11, m_mpie, 3'b000, m_pil, 10'd0, m_code}
                           : {m_irq, 26'd0, m_code[4:0]};

  function automatic logic [31:0] m_read(input logic [11:0] a);
    case (a)
      12'h300: return {19'd0, 2'b11, 3'd0, m_mpie, 3'd0, m_mie, 3'd0};
      12'h301: return 32'h4000_1106;
      12'h305: return m_mtvec;
      12'h307: return m_mtvt;
      12'h340: return m_mscratch;
      12'h341: return m_mepc;
      12'h342: return m_mcause;
      12'h343: return m_mtval;
      12'h345: return m_nxt ? m_tbl : 32'd0;
      12'h347: return m_clic ? {24'd0, m_th} : 32'd0;
      12'h349: return m_swap ? m_mscratch : ex_operand_i;
      12'hFB1: return {m_mil, 24'd0};
      12'hB00: return m_cycle[31:0];
      12'hB80: return m_cycle[63:32];
      12'hB02: return instret_now[31:0];
      12'hB82: return instret_now[63:32];
      12'hF13: return IMPID;
      default: return 32'd0;
    endcase
  endfunction

  logic [31:0] old, v;                            // read value, value written
  assign old = m_read(ex_addr_i);
  assign v   = ex_op_i == 2'd1 ? (old | ex_operand_i) :
               ex_op_i == 2'd2 ? (old & ~ex_operand_i) : ex_operand_i;

  // mtvec WARL (K-30, K-31)
  logic [31:0] v_mtvec;
  assign v_mtvec = v[1:0] == 2'b11 ? {v[31:6], 6'b000011} : {v[31:2], 2'b00};
  // mnxti: the read-modify-write target is mstatus (MIE = uimm bit 3)
  logic n_mie;
  assign n_mie = ex_op_i == 2'd2 ? (m_mie & ~ex_operand_i[3]) : (m_mie | ex_operand_i[3]);

  // value the CSR holds after a write of v, as a read returns it
  function automatic logic [31:0] m_after(input logic [11:0] a, input logic [31:0] x);
    case (a)
      12'h300: return {19'd0, 2'b11, 3'd0, x[7], 3'd0, x[3], 3'd0};
      12'h305: return v_mtvec;
      12'h307: return {x[31:6], 6'd0};
      12'h341: return {x[31:1], 1'b0};
      12'h342: return m_clic ? {x[31], x[30], 2'b11, x[27], 3'b000, x[23:16], 10'd0, x[5:0]}
                             : {x[31], 26'd0, x[4:0]};
      12'h347: return m_clic ? {24'd0, x[7:0]} : 32'd0;
      12'h345, 12'h349: return 32'd0;               // no state of their own
      12'h340, 12'h343, 12'hB00, 12'hB80, 12'hB02, 12'hB82: return x;
      default: return m_read(a);                  // constants: writes are ignored
    endcase
  endfunction

  logic m_we;
  assign m_we = ex_commit_i && ex_write_i && !trap_i && !mret_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      m_mie <= 1'b0; m_mpie <= 1'b0; m_irq <= 1'b0; m_code <= 6'd0; m_inhv <= 1'b0;
      m_pil <= 8'd0; m_mil <= 8'd0; m_th <= 8'd0; m_clic <= 1'b0; m_mtvt <= 32'd0;
      m_mtvec <= {RESET_VEC[31:2], 2'b00}; m_mscratch <= 32'd0; m_mepc <= 32'd0; m_mtval <= 32'd0;
      m_cycle <= 64'd0; m_instret <= 64'd0;
    end else begin
      if (trap_i) begin
        m_mpie <= m_mie;
        m_mie  <= 1'b0;
        m_mepc <= {trap_pc_i[31:1], 1'b0};
        m_irq  <= trap_irq_i;
        m_code <= trap_cause_i;
        m_mtval <= trap_tval_i;
        if (m_clic) begin                             // CLIC-mode entry (K-54, K-56, K-73)
          m_inhv <= trap_minhv_i;
          m_pil  <= m_mil;
          if (trap_irq_i) m_mil <= irq_level_i;
        end
      end else if (mret_i) begin
        m_mie  <= m_mpie;
        m_mpie <= 1'b1;
        if (m_clic) m_mil <= m_pil;                   // K-57
      end else if (m_we) begin
        case (ex_addr_i)
          12'h300: begin m_mie <= v[3]; m_mpie <= v[7]; end
          12'h305: begin
            m_mtvec <= v_mtvec;
            m_clic  <= v[1:0] == 2'b11;
            if (m_clic && v[1:0] != 2'b11) begin m_pil <= 8'd0; m_inhv <= 1'b0; end
          end
          12'h307: m_mtvt <= {v[31:6], 6'd0};
          12'h340: m_mscratch <= v;
          12'h341: m_mepc <= {v[31:1], 1'b0};
          12'h342: begin
            m_irq <= v[31];
            if (m_clic) begin
              m_inhv <= v[30]; m_pil <= v[23:16]; m_code <= v[5:0]; m_mpie <= v[27];
            end else begin
              m_code <= {1'b0, v[4:0]};
            end
          end
          12'h343: m_mtval <= v;
          12'h345: begin
            m_mie <= n_mie;
            if (m_nxt) begin m_mil <= irq_level_i; m_code <= irq_id_i; m_irq <= 1'b1; end
          end
          12'h347: m_th <= v[7:0];
          12'h349: if (m_swap) m_mscratch <= ex_operand_i;
          default: ;
        endcase
      end
      // mcycle: every cycle, unless a half is written (that half takes the value, the
      // other half holds, no increment)
      if (m_we && ex_addr_i == 12'hB00)      m_cycle <= {m_cycle[63:32], v};
      else if (m_we && ex_addr_i == 12'hB80) m_cycle <= {v, m_cycle[31:0]};
      else                                   m_cycle <= m_cycle + 64'd1;
      // minstret: retirements; a write lands on top of an older retirement this cycle
      if (m_we && ex_addr_i == 12'hB02)      m_instret <= {instret_now[63:32], v};
      else if (m_we && ex_addr_i == 12'hB82) m_instret <= {v, instret_now[31:0]};
      else                                   m_instret <= instret_now;
    end
  end

  // side-write slots expected for the instruction in EX (C2)
  logic [3:0]  e_side;
  logic [31:0] e_st, e_mc;
  assign e_side[0] = ex_write_i && (ex_addr_i == 12'h345 || (ex_addr_i == 12'h342 && m_clic));
  assign e_side[1] = ex_write_i && ex_addr_i == 12'h349 && m_swap;
  assign e_side[2] = ex_write_i && ((ex_addr_i == 12'h345 && m_nxt) ||
                                    (ex_addr_i == 12'h305 && m_clic && v[1:0] != 2'b11));
  assign e_side[3] = ex_write_i && ex_addr_i == 12'h345 && m_nxt;
  assign e_st = {19'd0, 2'b11, 3'd0, (ex_addr_i == 12'h342) ? v[27] : m_mpie, 3'd0,
                 (ex_addr_i == 12'h345) ? n_mie : m_mie, 3'd0};
  assign e_mc = (ex_addr_i == 12'h345) ? {1'b1, m_inhv, 2'b11, m_mpie, 3'b000, m_pil, 10'd0, irq_id_i}
                                       : {m_irq, 26'd0, m_code[4:0]};

  // -------------------------------------------------------------------------
  // Properties
  // -------------------------------------------------------------------------
  logic        p_valid, p_cause;                  // previous cycle
  logic        p_trap, p_mret, p_mie, p_mpie;
  logic [31:0] p_pc, p_tval, p_mtvec, p_mepc;
  logic [5:0]  p_code;
  logic        p_irq;
  logic        p_clic;
  logic [7:0]  p_mil, p_th;
  always_ff @(posedge clk_i) begin
    p_valid <= rst_ni;
    p_cause <= m_we || trap_i || mret_i;
    p_trap  <= trap_i;
    p_mret  <= mret_i;
    p_pc    <= trap_pc_i;
    p_tval  <= trap_tval_i;
    p_code  <= trap_cause_i;
    p_irq   <= trap_irq_i;
    p_mie   <= mie_o;
    p_mpie  <= dut.u_m.mpie_q;
    p_mtvec <= mtvec_o;
    p_mepc  <= mepc_o;
    p_clic  <= clic_o;
    p_mil   <= mil_o;
    p_th    <= th_o;
  end

  always_comb begin
    if (rst_ni) begin
      // A1-A5
      if (implemented(ex_addr_i)) begin
        assert (rdata == m_read(ex_addr_i));
        // (a write attempt to bits 11:10 = 11 is illegal and never retires: no trace value)
        if (ex_write_i && ex_addr_i[11:10] != 2'b11) assert (wdata == m_after(ex_addr_i, v));
      end
      assert (mtvec_o == {m_mtvec[31:2], 2'b00});
      assert (mepc_o == m_mepc);
      assert (mie_o == m_mie);
      assert (clic_o == m_clic && mil_o == m_mil && th_o == m_th && minhv_o == m_inhv);
      assert (tbl_o == m_tbl);
      assert (id_illegal == (!implemented(id_addr_i) || (id_write_i && id_addr_i[11:10] == 2'b11) ||
                             reserved_form(id_addr_i, id_op_i, id_rd_zero_i, id_imm_i)));
      assert (noinc == (ex_write_i && (ex_addr_i == 12'hB02 || ex_addr_i == 12'hB82)));
      // B1
      assert (mepc_o[0] == 1'b0 && mtvec_o[1:0] == 2'b00);
      if (ex_addr_i == 12'h341) assert (rdata[0] == 1'b0);
      if (ex_addr_i == 12'h305) assert (rdata[1:0] == {2{clic_o}} && (!clic_o || rdata[5:2] == 4'd0));
      if (ex_addr_i == 12'h342 && !clic_o) assert (rdata[30:5] == 26'd0);
      // B2
      if (ex_addr_i == 12'h301) assert (rdata == 32'h4000_1106);
      if (ex_addr_i == 12'hF13) assert (rdata == IMPID);
      if (ex_addr_i == 12'h304 || ex_addr_i == 12'h344 || ex_addr_i == 12'h310 ||
          (ex_addr_i >= 12'hB03 && ex_addr_i <= 12'hB1F) || (ex_addr_i >= 12'hB83 && ex_addr_i <= 12'hB9F) ||
          (ex_addr_i >= 12'h323 && ex_addr_i <= 12'h33F) || (ex_addr_i >= 12'h3A0 && ex_addr_i <= 12'h3EF) ||
          ex_addr_i == 12'hF11 || ex_addr_i == 12'hF12 || ex_addr_i == 12'hF14 || ex_addr_i == 12'hF15)
        assert (rdata == 32'd0);
      if (ex_addr_i == 12'h300) assert (rdata[12:11] == 2'b11 && (rdata & ~32'h0000_1888) == 32'd0);
      // C1
      assert (claim_o == (m_we && ex_addr_i == 12'h345 && m_nxt));
      if (claim_o) assert (claim_id_o == irq_id_i && rdata == m_mtvt + {24'd0, claim_id_o, 2'b00});
      // C2
      assert (side_we == e_side);
      if (e_side[0]) assert (side_wd[31:0]   == e_st);
      if (e_side[1]) assert (side_wd[63:32]  == ex_operand_i);
      if (e_side[2]) assert (side_wd[95:64]  == e_mc);
      if (e_side[3]) assert (side_wd[127:96] == {irq_level_i, 24'd0});
      // C3
      if (!clic_o) begin
        assert (!claim_o && !side_we[1] && !side_we[2] && !side_we[3]);
        if (ex_addr_i == 12'h345) assert (rdata == 32'd0);
        if (ex_addr_i == 12'h347) assert (rdata == 32'd0);
        if (ex_addr_i == 12'h349) assert (rdata == ex_operand_i);
      end
      // H1
      assert ((dut.id_hit_u & (dut.id_hit_u - 1'b1)) == '0);
      assert ((dut.id_hit_u != '0) == implemented(id_addr_i));
      assert ((dut.ex_hit_u & (dut.ex_hit_u - 1'b1)) == '0);
      assert ((dut.ex_hit_u != '0) == implemented(ex_addr_i));
      // H2
      for (int k = 0; k < NU; k++)
        if (!dut.ex_hit_u[k]) assert (dut.ex_rdata_u[k] == 32'd0 && dut.ex_wdata_u[k] == 32'd0);
      // B3, B4 (the cycle after)
      if (p_valid && !p_cause) begin
        assert (mtvec_o == p_mtvec && mepc_o == p_mepc && mie_o == p_mie && dut.u_m.mpie_q == p_mpie);
        assert (clic_o == p_clic && mil_o == p_mil && th_o == p_th);
      end
      if (p_valid && p_trap) begin
        assert (mepc_o == {p_pc[31:1], 1'b0});
        assert (dut.u_clic.mc_irq_q == p_irq && dut.u_clic.exccode_q == p_code && dut.u_m.mtval_q == p_tval);
        assert (mie_o == 1'b0 && dut.u_m.mpie_q == p_mie);
      end
      if (p_valid && p_mret && !p_trap) begin
        assert (mie_o == p_mpie && dut.u_m.mpie_q == 1'b1);
        assert (mtvec_o == p_mtvec && mepc_o == p_mepc);
      end
`ifdef INDUCTION
      // I1: px_csr's state equals the model (makes the induction step hold)
      assert (dut.u_m.mie_q == m_mie && dut.u_m.mpie_q == m_mpie);
      assert ({dut.u_clic.base_q, dut.u_clic.mode_q, dut.u_clic.mode_q} == m_mtvec);
      assert (dut.u_clic.mode_q == m_clic && dut.u_m.mscratch_q == m_mscratch);
      assert ({dut.u_m.mepc_q, 1'b0} == m_mepc && dut.u_m.mtval_q == m_mtval);
      assert (dut.u_clic.mc_irq_q == m_irq && dut.u_clic.exccode_q == m_code);
      assert (dut.u_clic.minhv_q == m_inhv && dut.u_clic.mpil_q == m_pil);
      assert (dut.u_clic.mil_q == m_mil && dut.u_clic.th_q == m_th);
      assert ({dut.u_clic.mtvt_q, 6'd0} == m_mtvt);
      assert ({dut.u_m.mcycle_hi_q, dut.u_m.mcycle_lo_q} == m_cycle);
      assert ({dut.u_m.minstret_hi_q, dut.u_m.minstret_lo_q} == m_instret);
      // model invariants: CLIC-mode mtvec has submode 0000 and mode 11; CLINT mode has mode 00
      assert (m_clic ? (m_mtvec[5:0] == 6'b000011) : (m_mtvec[1:0] == 2'b00));
      assert (m_mtvt[5:0] == 6'd0 && m_mepc[0] == 1'b0);
`endif
    end
  end

  // -------------------------------------------------------------------------
  // Cover
  // -------------------------------------------------------------------------
  always_comb begin
    if (rst_ni) begin
      cover (m_we && ex_addr_i == 12'h300 && v[3] && v[7]);
      cover (m_we && ex_addr_i == 12'h305);
      cover (m_we && ex_addr_i == 12'h340);
      cover (m_we && ex_addr_i == 12'h341);
      cover (m_we && ex_addr_i == 12'h342);
      cover (m_we && ex_addr_i == 12'h343);
      cover (trap_i && mie_o);
      cover (mret_i && !trap_i && dut.u_m.mpie_q);
      cover (m_cycle[31:0] == 32'hFFFF_FFFF && !m_we);
      cover (m_instret[31:0] == 32'hFFFF_FFFF && retire_i && !m_we);
      cover (m_we && ex_addr_i == 12'hB02 && retire_i);
      cover (p_valid && p_trap && p_mret);
      // step 2.2d
      cover (m_we && ex_addr_i == 12'h305 && !m_clic && v[1:0] == 2'b11);
      cover (m_we && ex_addr_i == 12'h305 && m_clic && v[1:0] != 2'b11 && m_pil != 8'd0);
      cover (claim_o);
      cover (m_we && ex_addr_i == 12'h349 && m_swap);
      cover (trap_i && trap_irq_i && m_clic && m_mil != 8'd0);
      cover (trap_i && trap_minhv_i && m_clic);
      cover (mret_i && !trap_i && m_clic && m_pil != m_mil);
    end
  end

endmodule
