// px_csr_fv: formal harness for px_csr (SymbiYosys, tb/formal/px_csr.sby; audit D-10).
//
// Environment: every px_csr input is arbitrary in every cycle (trap_i, mret_i and the
// commit may coincide: px_csr defines trap > MRET > write for every input), except
//   E1  ex_op_i is one of the three Zicsr operations (the decoder emits nothing else)
// Reset in the first cycle only.
//
// Reference model: the CSR file of DECISIONS.md D-022, written in this harness from the
// decision text (field positions from the privileged manual 20240411), not from px_csr:
// mstatus MIE/MPIE, mtvec (Direct), mscratch, mepc (bit 0 zero), mcause (bit 31 and code
// [4:0]), mtval, 64-bit mcycle/minstret with the D-022 write/increment rules, constants for
// every read-only or read-only-zero address. Register numbers are written as literals.
//
// Properties
//   A1  every implemented address reads as the model (ex_rdata_o)
//   A2  mtvec_o, mepc_o and mstatus_mie_o equal the model
//   A3  id_illegal_o is exactly "address not implemented, or a write attempt to an
//       address with bits 11:10 = 11"
//   A4  ex_wdata_o (the retirement-trace value) is the value the CSR holds after the
//       write, as the model legalizes it, for every implemented address that can be
//       written (a write attempt to bits 11:10 = 11 is illegal and never retires)
//   A5  ex_noinc_o exactly for a write attempt to minstret/minstreth
//   B1  mepc_o[0] = 0, mtvec_o[1:0] = 0, and a read of mepc/mtvec/mcause shows the same
//   B2  read-only CSRs are constant: misa 0x4000_1104, mimpid MIMPID, the rest 0; mstatus
//       reads MPP = 11 and 0 outside MIE, MPIE, MPP
//   B3  no architectural CSR changes unless a commit with a write, a trap or an MRET
//       happened in the cycle before (the counters excepted)
//   B4  trap > MRET > write: after trap_i, mepc/mcause/mtval hold the trap values,
//       MIE = 0 and MPIE = the old MIE, whatever MRET or commit did; after mret_i without
//       trap_i, MIE = the old MPIE and MPIE = 1, and the write is dropped
// B1-B4 follow from A1-A2 and are kept as separate, model-free statements of the audit's
// list. The prove task (k-induction) also asserts that px_csr's state registers equal the
// model (I1), which makes the induction step hold, so the result is unbounded.
// Tasks: bmc (depth 12), prove (k-induction), cover (a committed write of each writable
// CSR, a trap, an MRET, both counter carries, minstret written while an older instruction
// retires).

`timescale 1ns/1ps

module px_csr_fv (
  input logic        clk_i,
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

  localparam logic [31:0] RESET_VEC = 32'h1000_0040;
  localparam logic [31:0] IMPID     = 32'h0000_5A5A;   // nonzero, so it is observable

  logic init = 1'b1;
  always_ff @(posedge clk_i) init <= 1'b0;
  logic rst_ni;
  assign rst_ni = !init;

  logic        id_illegal, noinc, mie_o;
  logic [31:0] rdata, wdata, mtvec_o, mepc_o;

  px_csr #(.MTVEC_RESET(RESET_VEC), .MIMPID(IMPID)) dut (
    .clk_i, .rst_ni,
    .id_addr_i, .id_write_i, .id_illegal_o(id_illegal),
    .ex_addr_i, .ex_op_i, .ex_operand_i, .ex_write_i, .ex_commit_i,
    .ex_rdata_o(rdata), .ex_wdata_o(wdata), .ex_noinc_o(noinc),
    .retire_i,
    .trap_i, .trap_irq_i, .trap_cause_i, .trap_pc_i, .trap_tval_i, .mret_i,
    .mtvec_o, .mepc_o, .mstatus_mie_o(mie_o)
  );

  // E1
  always_comb assume (ex_op_i != 2'd3);

  // -------------------------------------------------------------------------
  // Reference model (D-022)
  // -------------------------------------------------------------------------
  function automatic logic implemented(input logic [11:0] a);
    return a == 12'h300 || a == 12'h301 || a == 12'h304 || a == 12'h305 || a == 12'h310 ||
           a == 12'h340 || a == 12'h341 || a == 12'h342 || a == 12'h343 || a == 12'h344 ||
           a == 12'hB00 || a == 12'hB02 || a == 12'hB80 || a == 12'hB82 ||
           (a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'hB83 && a <= 12'hB9F) ||
           (a >= 12'h323 && a <= 12'h33F) || (a >= 12'h3A0 && a <= 12'h3EF) ||
           (a >= 12'hF11 && a <= 12'hF15);
  endfunction

  logic        m_mie, m_mpie, m_irq;
  logic [31:0] m_mtvec, m_mscratch, m_mepc, m_mtval;
  logic [4:0]  m_code;
  logic [63:0] m_cycle, m_instret;

  logic [63:0] instret_now;                       // includes an older retirement this cycle
  assign instret_now = m_instret + {63'd0, retire_i};

  function automatic logic [31:0] m_read(input logic [11:0] a);
    case (a)
      12'h300: return {19'd0, 2'b11, 3'd0, m_mpie, 3'd0, m_mie, 3'd0};
      12'h301: return 32'h4000_1104;
      12'h305: return m_mtvec;
      12'h340: return m_mscratch;
      12'h341: return m_mepc;
      12'h342: return {m_irq, 26'd0, m_code};
      12'h343: return m_mtval;
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

  // value the CSR holds after a write of v, as a read returns it
  function automatic logic [31:0] m_after(input logic [11:0] a, input logic [31:0] x);
    case (a)
      12'h300: return {19'd0, 2'b11, 3'd0, x[7], 3'd0, x[3], 3'd0};
      12'h305: return {x[31:2], 2'b00};
      12'h341: return {x[31:1], 1'b0};
      12'h342: return {x[31], 26'd0, x[4:0]};
      12'h340, 12'h343, 12'hB00, 12'hB80, 12'hB02, 12'hB82: return x;
      default: return m_read(a);                  // constants: writes are ignored
    endcase
  endfunction

  logic m_we;
  assign m_we = ex_commit_i && ex_write_i && !trap_i && !mret_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      m_mie <= 1'b0; m_mpie <= 1'b0; m_irq <= 1'b0; m_code <= 5'd0;
      m_mtvec <= RESET_VEC; m_mscratch <= 32'd0; m_mepc <= 32'd0; m_mtval <= 32'd0;
      m_cycle <= 64'd0; m_instret <= 64'd0;
    end else begin
      if (trap_i) begin
        m_mpie <= m_mie;
        m_mie  <= 1'b0;
        m_mepc <= {trap_pc_i[31:1], 1'b0};
        m_irq  <= trap_irq_i;
        m_code <= trap_cause_i;
        m_mtval <= trap_tval_i;
      end else if (mret_i) begin
        m_mie  <= m_mpie;
        m_mpie <= 1'b1;
      end else if (m_we) begin
        case (ex_addr_i)
          12'h300: begin m_mie <= v[3]; m_mpie <= v[7]; end
          12'h305: m_mtvec <= {v[31:2], 2'b00};
          12'h340: m_mscratch <= v;
          12'h341: m_mepc <= {v[31:1], 1'b0};
          12'h342: begin m_irq <= v[31]; m_code <= v[4:0]; end
          12'h343: m_mtval <= v;
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

  // -------------------------------------------------------------------------
  // Properties
  // -------------------------------------------------------------------------
  logic        p_valid, p_cause;                  // previous cycle
  logic        p_trap, p_mret, p_mie, p_mpie;
  logic [31:0] p_pc, p_tval, p_mtvec, p_mepc;
  logic [4:0]  p_code;
  logic        p_irq;
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
    p_mpie  <= dut.mpie_q;
    p_mtvec <= mtvec_o;
    p_mepc  <= mepc_o;
  end

  always_comb begin
    if (rst_ni) begin
      // A1-A5
      if (implemented(ex_addr_i)) begin
        assert (rdata == m_read(ex_addr_i));
        // (a write attempt to bits 11:10 = 11 is illegal and never retires: no trace value)
        if (ex_write_i && ex_addr_i[11:10] != 2'b11) assert (wdata == m_after(ex_addr_i, v));
      end
      assert (mtvec_o == m_mtvec);
      assert (mepc_o == m_mepc);
      assert (mie_o == m_mie);
      assert (id_illegal == (!implemented(id_addr_i) || (id_write_i && id_addr_i[11:10] == 2'b11)));
      assert (noinc == (ex_write_i && (ex_addr_i == 12'hB02 || ex_addr_i == 12'hB82)));
      // B1
      assert (mepc_o[0] == 1'b0 && mtvec_o[1:0] == 2'b00);
      if (ex_addr_i == 12'h341) assert (rdata[0] == 1'b0);
      if (ex_addr_i == 12'h305) assert (rdata[1:0] == 2'b00);
      if (ex_addr_i == 12'h342) assert (rdata[30:5] == 26'd0);
      // B2
      if (ex_addr_i == 12'h301) assert (rdata == 32'h4000_1104);
      if (ex_addr_i == 12'hF13) assert (rdata == IMPID);
      if (ex_addr_i == 12'h304 || ex_addr_i == 12'h344 || ex_addr_i == 12'h310 ||
          (ex_addr_i >= 12'hB03 && ex_addr_i <= 12'hB1F) || (ex_addr_i >= 12'hB83 && ex_addr_i <= 12'hB9F) ||
          (ex_addr_i >= 12'h323 && ex_addr_i <= 12'h33F) || (ex_addr_i >= 12'h3A0 && ex_addr_i <= 12'h3EF) ||
          ex_addr_i == 12'hF11 || ex_addr_i == 12'hF12 || ex_addr_i == 12'hF14 || ex_addr_i == 12'hF15)
        assert (rdata == 32'd0);
      if (ex_addr_i == 12'h300) assert (rdata[12:11] == 2'b11 && (rdata & ~32'h0000_1888) == 32'd0);
      // B3, B4 (the cycle after)
      if (p_valid && !p_cause) begin
        assert (mtvec_o == p_mtvec && mepc_o == p_mepc && mie_o == p_mie && dut.mpie_q == p_mpie);
      end
      if (p_valid && p_trap) begin
        assert (mepc_o == {p_pc[31:1], 1'b0});
        assert (dut.mcause_irq_q == p_irq && dut.mcause_code_q == p_code && dut.mtval_q == p_tval);
        assert (mie_o == 1'b0 && dut.mpie_q == p_mie);
      end
      if (p_valid && p_mret && !p_trap) begin
        assert (mie_o == p_mpie && dut.mpie_q == 1'b1);
        assert (mtvec_o == p_mtvec && mepc_o == p_mepc);
      end
`ifdef INDUCTION
      // I1: px_csr's state equals the model (makes the induction step hold)
      assert (dut.mie_q == m_mie && dut.mpie_q == m_mpie);
      assert ({dut.mtvec_base_q, 2'b00} == m_mtvec && dut.mscratch_q == m_mscratch);
      assert ({dut.mepc_q, 1'b0} == m_mepc && dut.mtval_q == m_mtval);
      assert (dut.mcause_irq_q == m_irq && dut.mcause_code_q == m_code);
      assert ({dut.mcycle_hi_q, dut.mcycle_lo_q} == m_cycle);
      assert ({dut.minstret_hi_q, dut.minstret_lo_q} == m_instret);
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
      cover (mret_i && !trap_i && dut.mpie_q);
      cover (m_cycle[31:0] == 32'hFFFF_FFFF && !m_we);
      cover (m_instret[31:0] == 32'hFFFF_FFFF && retire_i && !m_we);
      cover (m_we && ex_addr_i == 12'hB02 && retire_i);
      cover (p_valid && p_trap && p_mret);
    end
  end

endmodule
