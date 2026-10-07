// tb_px_csr: self-checking unit test for px_csr (step 1.6, DECISIONS.md D-022; CLIC CSRs
// since step 2.2d, D-035).
//
// A reference model written from the privileged manual and, for the CLIC CSRs, from the
// pinned CLIC draft's CSR chapter and PHASE2_CLIC_MATRIX.md § 3 (64-bit counters as single
// 64-bit variables, fields kept as whole registers with legalization masks) is compared
// with the DUT every cycle, just before the clock edge: the EX read port, the value after a
// write (retirement trace), the side-write trace slots, the ID legality output, noinc,
// mtvec_o, mepc_o, MIE, the CLIC outputs (mode, mil, mintthresh, minhv, table address) and
// the mnxti claim. Directed tests also compare against explicit constants, so a mistake
// shared by the RTL and the model is still caught.
//
//   T1 reset values of every implemented CSR (explicit constants), counters held in reset
//   T2 legality of all 4096 addresses, with and without a write, against an explicit list;
//      the mnxti and mscratchcswl form rules for every form, rd and rs1/uimm value (K-36);
//      sub-unit ownership (step 2.2a, D-032): for all 4096 addresses exactly one bit of
//      the top's per-unit hit vectors is set for an implemented address and none for any
//      other, on the ID and on the EX side; in every compared cycle, a unit that does not
//      own the EX address drives 0 on its read and write-back data (both counted
//      separately from the checks)
//   T3 every writable field (PMP CSRs: read-only 0): all-ones/all-zeros through RW, RS, RC, walking ones; reserved
//      and read-only bits read 0; WARL registers ignore writes
//   T4 no commit, no change: a write that does not commit leaves every CSR unchanged
//   T5 counters: mcycle every cycle, write of either half (no increment in that cycle),
//      carry into the high half, minstret with retirement, read including a retirement in
//      the same cycle, write on top of a same-cycle retirement, carry, noinc
//   T6 trap entry and MRET: all MIE/MPIE combinations, mepc bit 0, mcause interrupt bit,
//      priority trap > MRET > write
//   T8 CLIC CSRs (step 2.2d): mtvec mode WARL and switching (K-30, K-31), mtvt (K-32),
//      mcause CLIC/CLINT formats, the mpp/mpie aliases and the zeroing when CLIC mode is
//      left (K-34), mintstatus and mintthresh in both modes (K-38, K-39), mnxti read value,
//      claim and side effects for every reason a winner is or is not returned (K-35, K-37,
//      K-75), mscratchcswl swap rule (K-41), CLIC-mode trap entry (interrupt, exception,
//      table fault) and MRET (K-54, K-56, K-57), trap > MRET > mnxti claim
//   T7 random stimulus against the model (addresses near every implemented CSR, values
//      near counter wrap, simultaneous commit/retire/trap/MRET, both interrupt modes,
//      random CLIC winners)
// Functional coverage bins must all be hit, otherwise the test fails.
//
// Run: scripts/run_unit.sh tb_px_csr [+vcd]

`timescale 1ns/1ps

module tb_px_csr;

  localparam logic [31:0] MTVEC_RESET = 32'h1000_0040;
  localparam logic [31:0] MIMPID      = 32'hABCD_0106;
  localparam int          NUM_RANDOM  = 60000;

  logic        clk = 1'b0;
  logic        rst_n;
  logic [11:0] id_addr, ex_addr;
  logic        id_write, id_illegal, id_rd_zero;
  logic [2:0]  id_op;
  logic [4:0]  id_imm;
  logic [1:0]  ex_op;
  logic [31:0] ex_operand, ex_rdata, ex_wdata;
  logic        ex_write, ex_commit, ex_noinc;
  logic [3:0]  side_we;
  logic [127:0] side_wdata;
  logic        retire, trap, trap_irq, trap_minhv, mret;
  logic [5:0]  trap_cause;
  logic [31:0] trap_pc, trap_tval, mtvec_o, mepc_o, tbl_o;
  logic        mie_o, clic_o, minhv_o, claim_o;
  logic [7:0]  mil_o, th_o;
  logic [5:0]  claim_id_o;
  logic        irq_valid, irq_shv;
  logic [5:0]  irq_id;
  logic [7:0]  irq_level;

  px_csr #(.MTVEC_RESET(MTVEC_RESET), .MIMPID(MIMPID)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .id_addr_i(id_addr), .id_write_i(id_write), .id_op_i(id_op), .id_rd_zero_i(id_rd_zero),
    .id_imm_i(id_imm), .id_illegal_o(id_illegal),
    .ex_addr_i(ex_addr), .ex_op_i(ex_op), .ex_operand_i(ex_operand), .ex_write_i(ex_write),
    .ex_commit_i(ex_commit), .ex_rdata_o(ex_rdata), .ex_wdata_o(ex_wdata), .ex_noinc_o(ex_noinc),
    .side_we_o(side_we), .side_wdata_o(side_wdata),
    .retire_i(retire),
    .trap_i(trap), .trap_irq_i(trap_irq), .trap_cause_i(trap_cause), .trap_minhv_i(trap_minhv),
    .trap_pc_i(trap_pc), .trap_tval_i(trap_tval), .mret_i(mret),
    .irq_valid_i(irq_valid), .irq_id_i(irq_id), .irq_level_i(irq_level), .irq_shv_i(irq_shv),
    .mtvec_o(mtvec_o), .mepc_o(mepc_o), .mstatus_mie_o(mie_o), .clic_mode_o(clic_o),
    .mil_o(mil_o), .mintthresh_o(th_o), .minhv_o(minhv_o), .tbl_addr_o(tbl_o),
    .claim_o(claim_o), .claim_id_o(claim_id_o)
  );

  always #5 clk = ~clk;

  localparam logic [1:0] OP_RW = 2'd0, OP_RS = 2'd1, OP_RC = 2'd2;

  int checks = 0;
  int unit_checks = 0;
  int posedges = 0;
  always @(posedge clk) if (rst_n) posedges++;
  int errors = 0;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("ERROR %0t: %s", $time, msg);
  endtask

  // ---------------------------------------------------------------------------
  // Independent list of implemented CSRs (privileged manual table, D-022 subset; CLIC CSRs
  // of the draft's "CLIC CSRs" table, M-mode, without mscratchcsw: D-035 item 1)
  // ---------------------------------------------------------------------------
  bit implemented [0:4095];
  initial begin
    for (int a = 0; a < 4096; a++) implemented[a] = 0;
    implemented['h300] = 1; implemented['h301] = 1; implemented['h304] = 1;
    implemented['h305] = 1; implemented['h310] = 1;
    implemented['h340] = 1; implemented['h341] = 1; implemented['h342] = 1;
    implemented['h343] = 1; implemented['h344] = 1;
    implemented['hB00] = 1; implemented['hB02] = 1;
    implemented['hB80] = 1; implemented['hB82] = 1;
    for (int n = 3; n <= 31; n++) begin
      implemented['hB00 + n] = 1;        // mhpmcounterN
      implemented['hB80 + n] = 1;        // mhpmcounterNh
      implemented['h320 + n] = 1;        // mhpmeventN
    end
    for (int a = 'hF11; a <= 'hF15; a++) implemented[a] = 1;
    for (int n = 0; n < 16; n++) implemented['h3A0 + n] = 1;   // pmpcfgN
    for (int n = 0; n < 64; n++) implemented['h3B0 + n] = 1;   // pmpaddrN
    // CLIC: mtvt, mnxti, mintthresh, mscratchcswl, mintstatus
    implemented['h307] = 1; implemented['h345] = 1; implemented['h347] = 1;
    implemented['h349] = 1; implemented['hFB1] = 1;
  end

  // Form rules (draft: mnxti only CSRR = CSRRS rd, mnxti, x0, CSRRSI, CSRRCI, uimm bits 0, 2,
  // 4 reserved; mscratchcswl only CSRRW with rd and rs1 not x0). op3 = {imm form, op}.
  function automatic bit form_ok(input logic [11:0] a, input logic [2:0] op3, input logic rdz,
                                 input logic [4:0] imm);
    if (a == 12'h345) begin
      if (op3 == 3'b001) return imm == 5'd0;                          // CSRRS rd, mnxti, x0
      if (op3 == 3'b101 || op3 == 3'b110) return (imm & 5'b10101) == 5'd0;   // CSRRSI, CSRRCI
      return 1'b0;
    end
    if (a == 12'h349) return op3 == 3'b000 && !rdz && imm != 5'd0;
    return 1'b1;
  endfunction

  function automatic bit model_illegal(input logic [11:0] a, input logic w, input logic [2:0] op3,
                                       input logic rdz, input logic [4:0] imm);
    return !implemented[a] || (w && a[11:10] == 2'b11) || !form_ok(a, op3, rdz, imm);
  endfunction

  // ---------------------------------------------------------------------------
  // Reference model state
  // ---------------------------------------------------------------------------
  logic        m_mie, m_mpie;
  logic [31:0] m_mtvec, m_mscratch, m_mepc, m_mtval, m_mtvt;
  logic [63:0] m_cycle, m_instret;
  // mcause fields (draft "Changes to cause CSRs"): interrupt, inhv, pil, exccode (6 bits kept)
  logic        c_irq, c_inhv;
  logic [7:0]  c_pil;
  logic [5:0]  c_code;
  logic [7:0]  m_mil, m_th;

  task automatic model_reset();
    m_mie = 0; m_mpie = 0;
    m_mtvec = MTVEC_RESET & 32'hFFFF_FFFC;
    m_mscratch = 0; m_mepc = 0; m_mtval = 0; m_mtvt = 0;
    c_irq = 0; c_inhv = 0; c_pil = 0; c_code = 0; m_mil = 0; m_th = 0;
    m_cycle = 0; m_instret = 0;
  endtask

  function automatic bit m_clic();
    return m_mtvec[1:0] == 2'b11;
  endfunction

  function automatic logic [31:0] mcause_val();
    if (m_clic()) return {c_irq, c_inhv, 2'b11, m_mpie, 3'b000, c_pil, 10'd0, c_code};
    return {c_irq, 26'd0, c_code[4:0]};
  endfunction

  // mnxti: highest interrupt present, not vectored, above mpil and mintthresh, CLIC mode
  function automatic bit nxti_ok();
    return m_clic() && irq_valid && !irq_shv && irq_level > c_pil && irq_level > m_th;
  endfunction
  function automatic logic [31:0] tbl_addr();
    return m_mtvt + {24'd0, irq_id, 2'b00};
  endfunction
  function automatic bit cswl_swap();
    return m_clic() && ((c_pil == 8'd0) != (m_mil == 8'd0));
  endfunction

  function automatic logic [31:0] model_read(input logic [11:0] a, input logic ret);
    logic [63:0] ir;
    ir = m_instret + (ret ? 64'd1 : 64'd0);
    case (a)
      12'h300: return 32'h0000_1800 | (m_mpie ? 32'h80 : 0) | (m_mie ? 32'h8 : 0);
      12'h301: return 32'h4000_1106;
      12'h305: return m_mtvec;
      12'h307: return m_mtvt;
      12'h340: return m_mscratch;
      12'h341: return m_mepc;
      12'h342: return mcause_val();
      12'h343: return m_mtval;
      12'h345: return nxti_ok() ? tbl_addr() : 32'd0;
      12'h347: return m_clic() ? {24'd0, m_th} : 32'd0;
      12'h349: return cswl_swap() ? m_mscratch : ex_operand;
      12'hFB1: return {m_mil, 24'd0};
      12'hB00: return m_cycle[31:0];
      12'hB80: return m_cycle[63:32];
      12'hB02: return ir[31:0];
      12'hB82: return ir[63:32];
      12'hF13: return MIMPID;
      default: return 32'd0;
    endcase
  endfunction

  // value written by the instruction in EX (read-modify-write of the read value)
  function automatic logic [31:0] wvalue();
    logic [31:0] old;
    old = model_read(ex_addr, retire);
    case (ex_op)
      OP_RS:   return old | ex_operand;
      OP_RC:   return old & ~ex_operand;
      default: return ex_operand;
    endcase
  endfunction

  // mtvec after a write of v (WARL {00, 11}; CLIC mode: base [31:6], submode 0000)
  function automatic logic [31:0] mtvec_legal(input logic [31:0] v);
    if (v[1:0] == 2'b11) return (v & 32'hFFFF_FFC0) | 32'd3;
    return v & 32'hFFFF_FFFC;
  endfunction

  // mnxti: mstatus.MIE after the read-modify-write with uimm
  function automatic logic nxti_mie();
    if (ex_op == OP_RC) return m_mie && !ex_operand[3];
    return m_mie || ex_operand[3];
  endfunction

  // Value of the addressed CSR after a write (retirement trace), as a read would return it
  function automatic logic [31:0] model_after(input logic [11:0] a, input logic [31:0] v);
    case (a)
      12'h300: return 32'h0000_1800 | (v & 32'h88);
      12'h305: return mtvec_legal(v);
      12'h307: return v & 32'hFFFF_FFC0;
      12'h341: return v & 32'hFFFF_FFFE;
      12'h342: return m_clic() ? ((v & 32'hC8FF_003F) | 32'h3000_0000) : (v & 32'h8000_001F);
      12'h347: return m_clic() ? (v & 32'hFF) : 32'd0;
      12'h345, 12'h349: return 32'd0;
      12'h340, 12'h343, 12'hB00, 12'hB80, 12'hB02, 12'hB82: return v;
      default: return model_read(a, retire);     // constants: writes are ignored
    endcase
  endfunction

  // Coverage
  int cov_write [0:15];      // per written register kind
  int cov_op [0:2];
  int cov_cyc_carry, cov_ins_carry, cov_ret_write_lo, cov_ret_write_hi, cov_read_ret;
  int cov_trap_combo [0:3], cov_mret_combo [0:3], cov_trap_irq, cov_prio_trap, cov_prio_mret;
  int cov_nocommit;
  // CLIC (T8, T7): 0 enter CLIC mode, 1 leave it, 2 mtvt write, 3 mcause write CLIC, 4 mcause
  // write CLINT, 5 mintthresh write, 6 mnxti claim, 7 mnxti write without winner, 8 mnxti in
  // CLINT mode, 9 swap, 10 no swap in CLIC mode, 11 interrupt trap in CLIC mode, 12 exception
  // in CLIC mode, 13 table-fault trap (minhv) in CLIC mode, 14 MRET in CLIC mode, 15 trap
  // in CLINT mode with minhv set (ignored), 16-19 mnxti not returned because: shv, level <=
  // mpil, level <= mintthresh, no valid winner
  localparam int NCC = 20;
  int cov_clic [0:NCC-1];

  // Model update at the clock edge, from the inputs of this cycle
  task automatic model_step();
    logic [31:0] old, wv;
    logic [63:0] ir;
    bit          we, clic, ok, swap;
    ir   = m_instret + (retire ? 64'd1 : 64'd0);
    old  = model_read(ex_addr, retire);
    wv   = wvalue();
    clic = m_clic();
    ok   = nxti_ok();
    swap = cswl_swap();
    we = ex_commit && ex_write && !trap && !mret;
    if (ex_commit && ex_write && trap) cov_prio_trap++;
    if (ex_commit && ex_write && mret && !trap) cov_prio_mret++;
    if (ex_write && !ex_commit) cov_nocommit++;
    if (ex_addr == 12'h345 && ex_write && we) begin
      if (!clic) cov_clic[8]++;
      else if (!irq_valid) cov_clic[19]++;
      else if (irq_shv) cov_clic[16]++;
      else if (irq_level <= c_pil) cov_clic[17]++;
      else if (irq_level <= m_th) cov_clic[18]++;
    end
    if (trap) begin
      cov_trap_combo[{m_mie, m_mpie}]++;
      if (trap_irq) cov_trap_irq++;
      m_mpie = m_mie; m_mie = 0;
      m_mepc = trap_pc & 32'hFFFF_FFFE;
      m_mtval = trap_tval;
      c_irq = trap_irq; c_code = trap_cause;
      if (clic) begin
        c_inhv = trap_minhv;
        c_pil  = m_mil;
        if (trap_irq) m_mil = irq_level;
        if (trap_irq) cov_clic[11]++; else if (trap_minhv) cov_clic[13]++; else cov_clic[12]++;
      end else if (trap_minhv) cov_clic[15]++;
    end else if (mret) begin
      cov_mret_combo[{m_mie, m_mpie}]++;
      m_mie = m_mpie; m_mpie = 1;
      if (clic) begin m_mil = c_pil; cov_clic[14]++; end
    end else if (we) begin
      cov_op[ex_op]++;
      case (ex_addr)
        12'h300: begin m_mie = wv[3]; m_mpie = wv[7]; cov_write[0]++; end
        12'h305: begin
          m_mtvec = mtvec_legal(wv); cov_write[1]++;
          if (clic && wv[1:0] != 2'b11) begin c_pil = 0; c_inhv = 0; cov_clic[1]++; end
          if (!clic && wv[1:0] == 2'b11) cov_clic[0]++;
        end
        12'h307: begin m_mtvt = wv & 32'hFFFF_FFC0; cov_clic[2]++; end
        12'h340: begin m_mscratch = wv;                cov_write[2]++; end
        12'h341: begin m_mepc = wv & 32'hFFFF_FFFE;    cov_write[3]++; end
        12'h342: begin
          cov_write[4]++;
          c_irq = wv[31];
          if (clic) begin
            c_inhv = wv[30]; c_pil = wv[23:16]; c_code = wv[5:0]; m_mpie = wv[27]; cov_clic[3]++;
          end else begin
            c_code = {1'b0, wv[4:0]}; cov_clic[4]++;
          end
        end
        12'h343: begin m_mtval = wv;                   cov_write[5]++; end
        12'h345: begin
          m_mie = nxti_mie();
          if (ok) begin m_mil = irq_level; c_code = irq_id; c_irq = 1; cov_clic[6]++; end
          else if (clic) cov_clic[7]++;
        end
        12'h347: begin m_th = wv[7:0]; cov_clic[5]++; end
        12'h349: begin
          if (swap) begin m_mscratch = ex_operand; cov_clic[9]++; end
          else if (clic) cov_clic[10]++;
        end
        12'h301, 12'h304, 12'h344, 12'h310: cov_write[6]++;
        default: ;
      endcase
    end
    // counters
    if (we && ex_addr == 12'hB00) begin
      m_cycle[31:0] = wv; cov_write[7]++;
    end else if (we && ex_addr == 12'hB80) begin
      m_cycle[63:32] = wv; cov_write[8]++;
    end else begin
      if (m_cycle[31:0] == 32'hFFFF_FFFF) cov_cyc_carry++;
      m_cycle = m_cycle + 64'd1;
    end
    if (retire && m_instret[31:0] == 32'hFFFF_FFFF) cov_ins_carry++;
    if (we && ex_addr == 12'hB02) begin
      ir[31:0] = wv; cov_write[9]++;
      if (retire) cov_ret_write_lo++;
    end else if (we && ex_addr == 12'hB82) begin
      ir[63:32] = wv; cov_write[10]++;
      if (retire) cov_ret_write_hi++;
    end
    if (retire && (ex_addr == 12'hB02 || ex_addr == 12'hB82)) cov_read_ret++;
    m_instret = ir;
  endtask

  // Compare every output with the model (inputs stable, before the edge)
  task automatic compare(input string where);
    logic [31:0] exp, wv, e_st, e_mc;
    logic [3:0]  e_side;
    bit          ok, e_claim;
    checks++;
    if (id_illegal !== model_illegal(id_addr, id_write, id_op, id_rd_zero, id_imm))
      fail($sformatf("%s: id_illegal %b for addr %03h write %b form %b rdz %b imm %h", where, id_illegal,
                     id_addr, id_write, id_op, id_rd_zero, id_imm));
    exp = model_read(ex_addr, retire);
    if (ex_rdata !== exp)
      fail($sformatf("%s: read %03h = %08h, model %08h", where, ex_addr, ex_rdata, exp));
    wv = wvalue();
    if (ex_write && implemented[ex_addr] && ex_addr[11:10] != 2'b11 && ex_wdata !== model_after(ex_addr, wv))
      fail($sformatf("%s: value after write of %03h = %08h, model %08h", where, ex_addr, ex_wdata,
                     model_after(ex_addr, wv)));
    if (ex_noinc !== (ex_write && (ex_addr == 12'hB02 || ex_addr == 12'hB82)))
      fail($sformatf("%s: noinc %b for addr %03h write %b", where, ex_noinc, ex_addr, ex_write));
    if (mtvec_o !== (m_mtvec & 32'hFFFF_FFFC)) fail($sformatf("%s: mtvec_o %08h, model %08h", where, mtvec_o, m_mtvec));
    if (mepc_o  !== m_mepc)  fail($sformatf("%s: mepc_o %08h, model %08h", where, mepc_o, m_mepc));
    if (mie_o   !== m_mie)   fail($sformatf("%s: MIE %b, model %b", where, mie_o, m_mie));
    if (clic_o !== m_clic() || mil_o !== m_mil || th_o !== m_th || minhv_o !== c_inhv)
      fail($sformatf("%s: CLIC outputs mode %b mil %02h th %02h minhv %b, model %b %02h %02h %b", where,
                     clic_o, mil_o, th_o, minhv_o, m_clic(), m_mil, m_th, c_inhv));
    if (tbl_o !== tbl_addr()) fail($sformatf("%s: table address %08h, model %08h", where, tbl_o, tbl_addr()));
    // mnxti claim (O3: only for a valid presented winner, with its id) and side-write slots
    ok = nxti_ok();
    e_claim = ex_commit && ex_write && !trap && !mret && ex_addr == 12'h345 && ok;
    if (claim_o !== e_claim || (e_claim && claim_id_o !== irq_id))
      fail($sformatf("%s: claim %b id %0d, model %b id %0d", where, claim_o, claim_id_o, e_claim, irq_id));
    e_side = 4'd0;
    if (ex_write) begin
      e_side[0] = ex_addr == 12'h345 || (ex_addr == 12'h342 && m_clic());
      e_side[1] = ex_addr == 12'h349 && cswl_swap();
      e_side[2] = (ex_addr == 12'h345 && ok) || (ex_addr == 12'h305 && m_clic() && wv[1:0] != 2'b11);
      e_side[3] = ex_addr == 12'h345 && ok;
    end
    if (side_we !== e_side) fail($sformatf("%s: side slots %b, model %b (addr %03h)", where, side_we, e_side, ex_addr));
    e_st = 32'h0000_1800 | ((ex_addr == 12'h342 ? wv[27] : m_mpie) ? 32'h80 : 0) |
           ((ex_addr == 12'h345 ? nxti_mie() : m_mie) ? 32'h8 : 0);
    e_mc = (ex_addr == 12'h345) ? {1'b1, c_inhv, 2'b11, m_mpie, 3'b000, c_pil, 10'd0, irq_id}
                                : {c_irq, 26'd0, c_code[4:0]};
    if ((e_side[0] && side_wdata[31:0] !== e_st) || (e_side[1] && side_wdata[63:32] !== ex_operand) ||
        (e_side[2] && side_wdata[95:64] !== e_mc) || (e_side[3] && side_wdata[127:96] !== {irq_level, 24'd0}))
      fail($sformatf("%s: side slot values %h, model mstatus %08h mscratch %08h mcause %08h mintstatus %08h",
                     where, side_wdata, e_st, ex_operand, e_mc, {irq_level, 24'd0}));
    // D-032: a sub-unit that does not own the EX address drives 0 (the top ORs the units)
    for (int k = 0; k < $bits(dut.ex_hit_u); k++) begin
      unit_checks++;
      if (!dut.ex_hit_u[k] && (dut.ex_rdata_u[k] !== 32'd0 || dut.ex_wdata_u[k] !== 32'd0))
        fail($sformatf("%s: unit %0d drives data at %03h, which it does not own", where, k, ex_addr));
    end
  endtask

  // One cycle: inputs were set before; compare, then step the model at the edge
  task automatic cycle(input string where);
    #1;
    compare(where);
    @(posedge clk);
    if (rst_n) model_step();
    #1;
  endtask

  task automatic idle();
    ex_commit = 0; ex_write = 0; retire = 0; trap = 0; mret = 0; trap_irq = 0; trap_minhv = 0;
    ex_op = OP_RW; ex_operand = 0;
  endtask

  // Directed helpers (read compares against an explicit constant as well as the model)
  task automatic expect_read(input logic [11:0] a, input logic [31:0] val, input string what);
    idle();
    ex_addr = a;
    #1;
    checks++;
    if (ex_rdata !== val) fail($sformatf("%s: read %03h = %08h, expected %08h", what, a, ex_rdata, val));
    cycle(what);
  endtask

  task automatic csr_write(input logic [11:0] a, input logic [1:0] op, input logic [31:0] v);
    idle();
    ex_addr = a; ex_op = op; ex_operand = v; ex_write = 1; ex_commit = 1;
    cycle("write");
    idle();
  endtask

  // An mnxti access: op RS/RC with uimm (write when uimm != 0); expect the read value
  task automatic nxti(input logic [1:0] op, input logic [4:0] uimm, input logic [31:0] val,
                      input string what);
    idle();
    ex_addr = 12'h345; ex_op = op; ex_operand = {27'd0, uimm}; ex_write = uimm != 5'd0; ex_commit = 1;
    #1;
    checks++;
    if (ex_rdata !== val) fail($sformatf("%s: mnxti read %08h, expected %08h", what, ex_rdata, val));
    cycle(what);
    idle();
  endtask

  task automatic winner(input logic v, input logic [5:0] id, input logic [7:0] lvl, input logic shv);
    irq_valid = v; irq_id = id; irq_level = lvl; irq_shv = shv;
  endtask

  // Reads that must hold whatever cycle count has passed: compare with the model only
  task automatic read_model(input logic [11:0] a);
    idle();
    ex_addr = a;
    cycle("read");
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  logic [11:0] rw_list [0:9];
  initial begin
    logic [31:0] v, lo;
    int          p2;
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_csr.vcd");
      $dumpvars(0, tb_px_csr);
    end
    for (int k = 0; k < 16; k++) cov_write[k] = 0;
    for (int k = 0; k < 3; k++) cov_op[k] = 0;
    for (int k = 0; k < 4; k++) begin cov_trap_combo[k] = 0; cov_mret_combo[k] = 0; end
    for (int k = 0; k < NCC; k++) cov_clic[k] = 0;
    cov_cyc_carry = 0; cov_ins_carry = 0; cov_ret_write_lo = 0; cov_ret_write_hi = 0;
    cov_read_ret = 0; cov_trap_irq = 0; cov_prio_trap = 0; cov_prio_mret = 0; cov_nocommit = 0;

    idle();
    id_addr = 12'h300; id_write = 0; id_op = 3'b001; id_rd_zero = 0; id_imm = 5'd0;
    ex_addr = 12'h300;
    trap_cause = 0; trap_pc = 0; trap_tval = 0;
    winner(1'b0, 6'd0, 8'h0F, 1'b0);
    rst_n = 0;
    model_reset();

    // ---- T1: reset ----
    repeat (3) @(posedge clk);
    #1;
    ex_addr = 12'hB00; #1;
    if (ex_rdata !== 32'd0) fail("T1: mcycle counts during reset");
    ex_addr = 12'hB02; retire = 1;      // a retirement input during reset is not counted
    @(posedge clk); #1;
    retire = 0; #1;
    if (ex_rdata !== 32'd0) fail("T1: minstret counted a retirement during reset");
    idle();
    @(negedge clk);
    rst_n = 1;
    expect_read(12'h300, 32'h0000_1800, "T1 mstatus");
    expect_read(12'h301, 32'h4000_1106, "T1 misa");
    expect_read(12'h304, 32'd0, "T1 mie");
    expect_read(12'h305, 32'h1000_0040, "T1 mtvec");
    expect_read(12'h310, 32'd0, "T1 mstatush");
    expect_read(12'h340, 32'd0, "T1 mscratch");
    expect_read(12'h341, 32'd0, "T1 mepc");
    expect_read(12'h342, 32'd0, "T1 mcause");
    expect_read(12'h343, 32'd0, "T1 mtval");
    expect_read(12'h344, 32'd0, "T1 mip");
    expect_read(12'hB80, 32'd0, "T1 mcycleh");
    expect_read(12'hB02, 32'd0, "T1 minstret");
    expect_read(12'hB82, 32'd0, "T1 minstreth");
    expect_read(12'hF11, 32'd0, "T1 mvendorid");
    expect_read(12'hF12, 32'd0, "T1 marchid");
    expect_read(12'hF13, MIMPID, "T1 mimpid");
    expect_read(12'hF14, 32'd0, "T1 mhartid");
    expect_read(12'hF15, 32'd0, "T1 mconfigptr");
    // mcycle: 18 reads above, one cycle each, starting in the first cycle after release
    expect_read(12'hB00, 32'd18, "T1 mcycle after 18 cycles");
    for (int n = 3; n <= 31; n++) begin
      expect_read(12'hB00 + n, 32'd0, "T1 mhpmcounter");
      expect_read(12'hB80 + n, 32'd0, "T1 mhpmcounterh");
      expect_read(12'h320 + n, 32'd0, "T1 mhpmevent");
    end
    // CLIC CSRs (K-32, K-38, K-39, K-35): reset 0, CLINT mode
    expect_read(12'h307, 32'd0, "T1 mtvt");
    expect_read(12'h347, 32'd0, "T1 mintthresh");
    expect_read(12'hFB1, 32'd0, "T1 mintstatus");
    winner(1'b1, 6'd5, 8'hFF, 1'b0);
    expect_read(12'h345, 32'd0, "T1 mnxti reads 0 in CLINT mode");
    winner(1'b0, 6'd0, 8'h0F, 1'b0);
    if (clic_o !== 1'b0 || mil_o !== 8'd0 || th_o !== 8'd0 || minhv_o !== 1'b0)
      fail("T1: CLIC outputs not at their reset values");
    checks++;

    // ---- T2: legality, exhaustive (combinational; the model catches up on mcycle) ----
    p2 = posedges;
    for (int a = 0; a < 4096; a++) begin
      for (int w = 0; w < 2; w++) begin
        id_addr = a; id_write = w;
        // forms that are legal for every implemented address (CSRRS / CSRRW with registers)
        id_op = w ? 3'b000 : 3'b001; id_rd_zero = 0; id_imm = w ? 5'd7 : 5'd0;
        #1;
        checks++;
        if (id_illegal !== model_illegal(a, w, id_op, id_rd_zero, id_imm) ||
            id_illegal !== !(implemented[a] && !(w && a[11:10] == 2'b11) &&
                             (a != 12'h345 || !w) && (a != 12'h349 || w)))
          fail($sformatf("T2: addr %03h write %0d: illegal %b", a, w, id_illegal));
      end
    end
    // form rules of mnxti and mscratchcswl: every form, rd and rs1/uimm field (K-36)
    for (int a2 = 0; a2 < 2; a2++) begin
      for (int f = 0; f < 8; f++) begin
        for (int r = 0; r < 2; r++) begin
          for (int i = 0; i < 32; i++) begin
            id_addr = a2 ? 12'h349 : 12'h345; id_op = f; id_rd_zero = r; id_imm = i;
            id_write = (f[1:0] == 2'b00) || (i != 0);      // the decoder's csr_write
            #1;
            checks++;
            if (id_illegal !== model_illegal(id_addr, id_write, id_op, id_rd_zero, id_imm))
              fail($sformatf("T2: form %b rd0 %0d imm %h at %03h: illegal %b", f, r, i, id_addr, id_illegal));
          end
        end
      end
    end
    // explicit spot checks independent of the list
    id_op = 3'b001; id_rd_zero = 0; id_imm = 5'd0;
    id_addr = 12'hC00; id_write = 1; #1; if (!id_illegal) fail("T2: cycle write accepted");
    id_addr = 12'hC00; id_write = 0; #1; if (!id_illegal) fail("T2: cycle (Zicntr) accepted");
    id_addr = 12'hF14; id_write = 0; #1; if (id_illegal)  fail("T2: mhartid read rejected");
    id_addr = 12'hF14; id_write = 1; #1; if (!id_illegal) fail("T2: mhartid write accepted");
    id_addr = 12'h301; id_write = 1; #1; if (id_illegal)  fail("T2: misa write rejected");
    id_addr = 12'h320; id_write = 0; #1; if (!id_illegal) fail("T2: mcountinhibit accepted");
    id_addr = 12'h306; id_write = 0; #1; if (!id_illegal) fail("T2: mcounteren accepted");
    id_addr = 12'hB01; id_write = 0; #1; if (!id_illegal) fail("T2: 0xB01 accepted");
    id_addr = 12'h001; id_write = 0; #1; if (!id_illegal) fail("T2: fflags accepted");
    id_addr = 12'h348; id_write = 0; #1; if (!id_illegal) fail("T2: mscratchcsw accepted before U-mode");
    id_addr = 12'hFB1; id_write = 0; #1; if (id_illegal)  fail("T2: mintstatus read rejected");
    id_addr = 12'hFB1; id_write = 1; #1; if (!id_illegal) fail("T2: mintstatus write accepted");
    id_addr = 12'h345; id_op = 3'b101; id_imm = 5'd8; id_write = 1; #1;
    if (id_illegal) fail("T2: csrrsi mnxti, 8 rejected");
    id_addr = 12'h345; id_op = 3'b110; id_imm = 5'd10; id_write = 1; #1;
    if (id_illegal) fail("T2: csrrci mnxti, 10 rejected");
    id_addr = 12'h345; id_op = 3'b101; id_imm = 5'd9; id_write = 1; #1;
    if (!id_illegal) fail("T2: csrrsi mnxti with uimm bit 0 accepted");
    id_addr = 12'h345; id_op = 3'b000; id_imm = 5'd0; id_write = 1; #1;
    if (!id_illegal) fail("T2: csrrw mnxti accepted");
    id_addr = 12'h345; id_op = 3'b010; id_imm = 5'd0; id_write = 0; #1;
    if (!id_illegal) fail("T2: csrrc mnxti accepted");
    id_addr = 12'h349; id_op = 3'b000; id_imm = 5'd2; id_rd_zero = 0; id_write = 1; #1;
    if (id_illegal) fail("T2: csrrw sp, mscratchcswl, sp rejected");
    id_addr = 12'h349; id_op = 3'b000; id_imm = 5'd2; id_rd_zero = 1; id_write = 1; #1;
    if (!id_illegal) fail("T2: mscratchcswl with rd = x0 accepted");
    id_addr = 12'h349; id_op = 3'b100; id_imm = 5'd2; id_rd_zero = 0; id_write = 1; #1;
    if (!id_illegal) fail("T2: csrrwi mscratchcswl accepted");
    checks += 19;
    // sub-unit ownership (D-032): exactly one unit for an implemented address, none otherwise
    begin
      logic [11:0] ex_save;
      ex_save = ex_addr;
      for (int a = 0; a < 4096; a++) begin
        id_addr = a; ex_addr = a;
        #1;
        unit_checks += 2;
        if ($countones(dut.id_hit_u) != (implemented[a] ? 1 : 0))
          fail($sformatf("T2: addr %03h: %0d units hit in ID", a, $countones(dut.id_hit_u)));
        if ($countones(dut.ex_hit_u) != (implemented[a] ? 1 : 0))
          fail($sformatf("T2: addr %03h: %0d units hit in EX", a, $countones(dut.ex_hit_u)));
      end
      ex_addr = ex_save;
    end
    @(posedge clk); #1;
    m_cycle = m_cycle + (posedges - p2);
    id_addr = 12'h300; id_write = 0; id_op = 3'b001; id_rd_zero = 0; id_imm = 5'd0;

    // ---- T3: fields ----
    csr_write(12'h300, OP_RW, 32'hFFFF_FFFF); expect_read(12'h300, 32'h0000_1888, "T3 mstatus ones");
    csr_write(12'h300, OP_RC, 32'h0000_0008); expect_read(12'h300, 32'h0000_1880, "T3 mstatus clear MIE");
    csr_write(12'h300, OP_RC, 32'hFFFF_FFFF); expect_read(12'h300, 32'h0000_1800, "T3 mstatus zeros");
    csr_write(12'h300, OP_RS, 32'h0000_0080); expect_read(12'h300, 32'h0000_1880, "T3 mstatus set MPIE");
    csr_write(12'h300, OP_RW, 32'h0000_0000); expect_read(12'h300, 32'h0000_1800, "T3 mstatus MPP fixed");
    csr_write(12'h301, OP_RW, 32'h0000_0000); expect_read(12'h301, 32'h4000_1106, "T3 misa fixed");
    csr_write(12'h304, OP_RW, 32'hFFFF_FFFF); expect_read(12'h304, 32'd0, "T3 mie read-only 0");
    csr_write(12'h344, OP_RS, 32'hFFFF_FFFF); expect_read(12'h344, 32'd0, "T3 mip read-only 0");
    csr_write(12'h310, OP_RW, 32'hFFFF_FFFF); expect_read(12'h310, 32'd0, "T3 mstatush 0");
    csr_write(12'h305, OP_RW, 32'hFFFF_FFFE); expect_read(12'h305, 32'hFFFF_FFFC, "T3 mtvec ones, mode 10 -> 00");
    csr_write(12'h305, OP_RW, 32'h1234_5679); expect_read(12'h305, 32'h1234_5678, "T3 mtvec mode 01 -> 00");
    // (step 2.2d: mode 11 selects CLIC mode, D-035 item 4; was "legalized to 00" before)
    csr_write(12'h305, OP_RW, 32'h1000_0047); expect_read(12'h305, 32'h1000_0043, "T3 mtvec mode 11: CLIC, submode 0000");
    csr_write(12'h305, OP_RW, 32'h1000_0040); expect_read(12'h305, 32'h1000_0040, "T3 mtvec back to mode 00");
    csr_write(12'h341, OP_RW, 32'hFFFF_FFFF); expect_read(12'h341, 32'hFFFF_FFFE, "T3 mepc ones");
    csr_write(12'h341, OP_RW, 32'h1000_0002); expect_read(12'h341, 32'h1000_0002, "T3 mepc halfword");
    csr_write(12'h342, OP_RW, 32'hFFFF_FFFF); expect_read(12'h342, 32'h8000_001F, "T3 mcause ones");
    csr_write(12'h342, OP_RC, 32'h8000_0000); expect_read(12'h342, 32'h0000_001F, "T3 mcause clear irq");
    csr_write(12'h343, OP_RW, 32'hFFFF_FFFF); expect_read(12'h343, 32'hFFFF_FFFF, "T3 mtval ones");
    csr_write(12'h343, OP_RC, 32'h0F0F_0F0F); expect_read(12'h343, 32'hF0F0_F0F0, "T3 mtval RC");
    csr_write(12'h307, OP_RW, 32'hFFFF_FFFF); expect_read(12'h307, 32'hFFFF_FFC0, "T3 mtvt ones");
    csr_write(12'h307, OP_RC, 32'h0F00_0040); expect_read(12'h307, 32'hF0FF_FF80, "T3 mtvt RC");
    csr_write(12'h307, OP_RW, 32'h0000_0000);
    csr_write(12'h347, OP_RW, 32'hFFFF_FFFF); expect_read(12'h347, 32'd0, "T3 mintthresh reads 0 in CLINT mode");
    csr_write(12'h340, OP_RW, 32'h0000_0000);
    for (int b = 0; b < 32; b++) begin
      csr_write(12'h340, OP_RS, 32'd1 << b);
      expect_read(12'h340, (32'd2 << b) - 32'd1, "T3 mscratch walking set");
    end
    for (int b = 0; b < 32; b++) begin
      csr_write(12'h340, OP_RC, 32'd1 << b);
      expect_read(12'h340, ~((32'd2 << b) - 32'd1), "T3 mscratch walking clear");
    end
    for (int n = 3; n <= 31; n++) begin
      csr_write(12'hB00 + n, OP_RW, 32'hFFFF_FFFF); expect_read(12'hB00 + n, 32'd0, "T3 hpm 0");
      csr_write(12'h320 + n, OP_RS, 32'hFFFF_FFFF); expect_read(12'h320 + n, 32'd0, "T3 hpmevent 0");
    end
    for (int n = 0; n < 80; n++) begin
      csr_write(12'h3A0 + n, OP_RW, 32'hFFFF_FFFF); expect_read(12'h3A0 + n, 32'd0, "T3 PMP 0");
    end

    // ---- T4: no commit, no change ----
    csr_write(12'h340, OP_RW, 32'h5A5A_5A5A);
    rw_list[0] = 12'h300; rw_list[1] = 12'h305; rw_list[2] = 12'h340; rw_list[3] = 12'h341;
    rw_list[4] = 12'h342; rw_list[5] = 12'h343; rw_list[6] = 12'hB02; rw_list[7] = 12'hB82;
    rw_list[8] = 12'hB80; rw_list[9] = 12'h301;
    for (int k = 0; k < 10; k++) begin
      for (int op = 0; op < 3; op++) begin
        idle();
        ex_addr = rw_list[k]; ex_op = op; ex_operand = 32'hFFFF_FFFF; ex_write = 1; ex_commit = 0;
        cycle("T4 uncommitted write");
      end
    end
    expect_read(12'h340, 32'h5A5A_5A5A, "T4 mscratch unchanged");
    expect_read(12'h341, 32'h1000_0002, "T4 mepc unchanged");

    // ---- T5: counters ----
    // mcycle: write is the next read, no increment in the write cycle, carry into the high half
    csr_write(12'hB80, OP_RW, 32'h0000_0007);
    csr_write(12'hB00, OP_RW, 32'hFFFF_FFFD);
    expect_read(12'hB00, 32'hFFFF_FFFD, "T5 mcycle = written value");
    expect_read(12'hB00, 32'hFFFF_FFFE, "T5 mcycle + 1");
    expect_read(12'hB80, 32'h0000_0007, "T5 mcycleh before carry");
    expect_read(12'hB80, 32'h0000_0008, "T5 mcycleh after carry");
    expect_read(12'hB00, 32'h0000_0001, "T5 mcycle after carry");
    // writing the high half holds the low half for that cycle
    idle(); ex_addr = 12'hB00; #1; lo = ex_rdata;
    csr_write(12'hB80, OP_RW, 32'h0000_0100);
    expect_read(12'hB00, lo, "T5 mcycle held while mcycleh is written");
    expect_read(12'hB80, 32'h0000_0100, "T5 mcycleh written");
    // mcycle RS on the running counter uses the value read in that cycle
    idle(); ex_addr = 12'hB00; #1; lo = ex_rdata;
    csr_write(12'hB00, OP_RS, 32'h8000_0000);
    expect_read(12'hB00, lo | 32'h8000_0000, "T5 mcycle RS");
    // minstret: counts retire only
    csr_write(12'hB02, OP_RW, 32'd100);
    csr_write(12'hB82, OP_RW, 32'd0);
    expect_read(12'hB02, 32'd100, "T5 minstret = written value");
    idle(); retire = 1; ex_addr = 12'hB02; #1;
    checks++;
    if (ex_rdata !== 32'd101) fail("T5: minstret read misses a same-cycle retirement");
    cycle("T5 retire");
    expect_read(12'hB02, 32'd101, "T5 minstret after one retirement");
    // write on top of a same-cycle older retirement: low half written, carry kept
    csr_write(12'hB02, OP_RW, 32'hFFFF_FFFF);
    idle(); retire = 1; ex_addr = 12'hB02; ex_op = OP_RW; ex_operand = 32'h0000_0010;
    ex_write = 1; ex_commit = 1;
    #1; checks++;
    if (ex_rdata !== 32'd0) fail("T5: minstret read with retirement did not wrap");
    cycle("T5 write lo with retire");
    expect_read(12'hB02, 32'h0000_0010, "T5 minstret written");
    expect_read(12'hB82, 32'h0000_0001, "T5 minstreth got the older carry");
    idle(); retire = 1; ex_addr = 12'hB82; ex_op = OP_RW; ex_operand = 32'h0000_0020;
    ex_write = 1; ex_commit = 1;
    cycle("T5 write hi with retire");
    expect_read(12'hB02, 32'h0000_0011, "T5 minstret kept the older increment");
    expect_read(12'hB82, 32'h0000_0020, "T5 minstreth written");
    // carry by retirement
    csr_write(12'hB02, OP_RW, 32'hFFFF_FFFE);
    idle(); retire = 1; ex_addr = 12'hB02; cycle("T5 retire");
    idle(); retire = 1; ex_addr = 12'hB82; #1; checks++;
    if (ex_rdata !== 32'h0000_0021) fail("T5: minstreth read misses the same-cycle carry");
    cycle("T5 retire carry");
    expect_read(12'hB02, 32'd0, "T5 minstret wrapped");
    expect_read(12'hB82, 32'h0000_0021, "T5 minstreth carried");
    // mcycle keeps counting while minstret is written and vice versa
    idle(); ex_addr = 12'hB00; #1; lo = ex_rdata;
    csr_write(12'hB02, OP_RW, 32'd5);
    expect_read(12'hB00, lo + 32'd1, "T5 mcycle unaffected by minstret write");

    // ---- T6: trap entry and MRET (CLINT mode) ----
    for (int c = 0; c < 4; c++) begin
      csr_write(12'h300, OP_RW, {24'd0, c[1], 3'd0, c[0], 3'd0});   // MPIE = c[1], MIE = c[0]
      idle(); trap = 1; trap_cause = 6'd11; trap_pc = 32'h1000_1233; trap_tval = 32'hDEAD_0000 + c;
      trap_irq = (c == 3);
      cycle("T6 trap");
      idle();
      expect_read(12'h300, {19'd0, 2'b11, 3'd0, c[0], 3'd0, 1'b0, 3'd0}, "T6 mstatus after trap");
      expect_read(12'h341, 32'h1000_1232, "T6 mepc");
      expect_read(12'h342, (c == 3) ? 32'h8000_000B : 32'h0000_000B, "T6 mcause");
      expect_read(12'h343, 32'hDEAD_0000 + c, "T6 mtval");
      csr_write(12'h300, OP_RW, {24'd0, c[1], 3'd0, c[0], 3'd0});
      idle(); mret = 1;
      cycle("T6 mret");
      idle();
      expect_read(12'h300, {19'd0, 2'b11, 3'd0, 1'b1, 3'd0, c[1], 3'd0}, "T6 mstatus after mret");
    end
    // CLINT mode: a trap with minhv set and an interrupt with a level change nothing else
    winner(1'b1, 6'd33, 8'h7F, 1'b0);
    idle(); trap = 1; trap_irq = 1; trap_cause = 6'd33; trap_minhv = 1; trap_pc = 32'h40; trap_tval = 0;
    cycle("T6 CLINT-mode trap with minhv and level");
    expect_read(12'h342, 32'h8000_0001, "T6 CLINT mcause shows code bits 4:0");
    expect_read(12'hFB1, 32'd0, "T6 CLINT trap leaves mil");
    if (minhv_o !== 1'b0) fail("T6: minhv set by a CLINT-mode trap");
    winner(1'b0, 6'd0, 8'h0F, 1'b0);
    // priority: trap over a write, MRET over a write
    csr_write(12'h343, OP_RW, 32'h1111_1111);
    idle(); trap = 1; trap_cause = 6'd2; trap_pc = 32'h4; trap_tval = 32'h2222_2222;
    ex_addr = 12'h343; ex_op = OP_RW; ex_operand = 32'h3333_3333; ex_write = 1; ex_commit = 1;
    cycle("T6 trap and write");
    expect_read(12'h343, 32'h2222_2222, "T6 trap wins over write");
    idle(); mret = 1;
    ex_addr = 12'h340; ex_op = OP_RW; ex_operand = 32'h4444_4444; ex_write = 1; ex_commit = 1;
    cycle("T6 mret and write");
    expect_read(12'h340, 32'h5A5A_5A5A, "T6 MRET drops the write");

    // ---- T8: CLIC CSRs (D-035) ----
    // mtvec: enter CLIC mode, submode legalized, mtvec_o = NBASE
    csr_write(12'h305, OP_RW, 32'h2000_017F);
    expect_read(12'h305, 32'h2000_0143, "T8 mtvec CLIC mode, bits 5:2 read 0");
    if (clic_o !== 1'b1 || mtvec_o !== 32'h2000_0140) fail("T8: CLIC mode / NBASE output");
    checks++;
    csr_write(12'h305, OP_RS, 32'h0000_003C);
    expect_read(12'h305, 32'h2000_0143, "T8 mtvec RS of submode bits stays 0000");
    expect_read(12'h342, 32'h3800_0002, "T8 mcause in CLIC format (mpp 11, mpie 1, code 2)");
    // mcause CLIC format: every field; the mpie alias writes mstatus.MPIE
    csr_write(12'h342, OP_RW, 32'hFFFF_FFFF);
    expect_read(12'h342, 32'hF8FF_003F, "T8 mcause ones in CLIC mode");
    expect_read(12'h300, 32'h0000_1880 | (m_mie ? 32'h8 : 32'h0), "T8 mstatus.MPIE written through mcause");
    if (minhv_o !== 1'b1) fail("T8: minhv output");
    checks++;
    csr_write(12'h342, OP_RW, 32'h0000_0000);
    expect_read(12'h342, 32'h3000_0000, "T8 mcause zeros (mpp reads 11)");
    expect_read(12'h300, 32'h0000_1800 | (m_mie ? 32'h8 : 32'h0), "T8 mstatus.MPIE cleared through mcause");
    csr_write(12'h342, OP_RW, 32'h4855_0025);       // minhv, mpie, mpil 0x55, code 37
    expect_read(12'h342, 32'h7855_0025, "T8 mcause fields");
    // leaving CLIC mode zeroes mpil and minhv; mpp/mpie read 0 in the CLINT format
    csr_write(12'h305, OP_RW, 32'h2000_0140);
    expect_read(12'h342, 32'h0000_0005, "T8 mcause CLINT format after leaving CLIC mode");
    expect_read(12'h300, 32'h0000_1880 | (m_mie ? 32'h8 : 32'h0), "T8 mstatus.MPIE kept when leaving");
    csr_write(12'h305, OP_RW, 32'h2000_0143);
    expect_read(12'h342, 32'h3800_0025, "T8 mpil and minhv were zeroed");
    // mintthresh: 8 bits; reads 0 in CLINT mode, state kept
    csr_write(12'h347, OP_RW, 32'hFFFF_FFFF);  expect_read(12'h347, 32'h0000_00FF, "T8 mintthresh ones");
    csr_write(12'h347, OP_RW, 32'h0000_0123);  expect_read(12'h347, 32'h0000_0023, "T8 mintthresh 8 bits");
    csr_write(12'h305, OP_RW, 32'h2000_0140);  expect_read(12'h347, 32'd0, "T8 mintthresh 0 in CLINT mode");
    csr_write(12'h305, OP_RW, 32'h2000_0143);  expect_read(12'h347, 32'h0000_0023, "T8 mintthresh kept");
    csr_write(12'h347, OP_RW, 32'h0000_0000);
    // mintstatus is read-only: an (illegal, here forced) write changes nothing
    csr_write(12'hFB1, OP_RW, 32'hFFFF_FFFF); expect_read(12'hFB1, 32'd0, "T8 mintstatus unchanged");
    // interrupt entry in CLIC mode: mil = level, mpil = old mil, minhv from the input
    csr_write(12'h300, OP_RW, 32'h0000_0008);       // MIE = 1
    winner(1'b1, 6'd42, 8'h5F, 1'b0);
    idle(); trap = 1; trap_irq = 1; trap_cause = 6'd42; trap_pc = 32'h1000_2000; trap_tval = 0;
    cycle("T8 interrupt entry");
    expect_read(12'h342, 32'hB800_002A, "T8 mcause after interrupt (mpie 1, mpil 0, id 42)");
    expect_read(12'hFB1, 32'h5F00_0000, "T8 mil = level");
    // synchronous exception at mil 0x5F: horizontal, level kept
    idle(); trap = 1; trap_irq = 0; trap_cause = 6'd2; trap_pc = 32'h1000_2004; trap_tval = 32'h13;
    cycle("T8 exception in CLIC mode");
    expect_read(12'h342, 32'h305F_0002, "T8 mcause after exception (mpil 0x5F)");
    expect_read(12'hFB1, 32'h5F00_0000, "T8 exception keeps mil");
    // table fetch fault: minhv = 1, cause 1
    idle(); trap = 1; trap_irq = 0; trap_cause = 6'd1; trap_minhv = 1; trap_pc = 32'h1000_8008; trap_tval = 32'h1000_8008;
    cycle("T8 table fault");
    expect_read(12'h342, 32'h705F_0001, "T8 mcause after table fault (minhv)");
    // MRET in CLIC mode: mil = mpil, mpil unchanged
    csr_write(12'h342, OP_RW, 32'h0012_0000);       // mpil 0x12, minhv 0
    idle(); mret = 1; cycle("T8 MRET");
    expect_read(12'hFB1, 32'h1200_0000, "T8 MRET mil = mpil");
    expect_read(12'h342, 32'h3812_0000, "T8 MRET keeps mpil");
    // mnxti: mtvt 0x0000_8040, winners above/below mpil and mintthresh, shv, invalid
    csr_write(12'h307, OP_RW, 32'h0000_8040);
    csr_write(12'h342, OP_RW, 32'h0030_0000);       // mpil 0x30
    csr_write(12'h300, OP_RW, 32'h0000_0000);       // MIE = 0
    winner(1'b1, 6'd63, 8'h3F, 1'b0);
    nxti(OP_RS, 5'd0, 32'h0000_813C, "T8 mnxti csrr: id 63 level 0x3F > mpil 0x30");
    expect_read(12'hFB1, 32'h1200_0000, "T8 csrr mnxti claims nothing");
    winner(1'b1, 6'd3, 8'h2F, 1'b0);
    nxti(OP_RS, 5'd8, 32'h0, "T8 mnxti level <= mpil");
    expect_read(12'h300, 32'h0000_1808, "T8 mnxti sets MIE without a winner");
    winner(1'b1, 6'd3, 8'h3F, 1'b1);
    nxti(OP_RC, 5'd8, 32'h0, "T8 mnxti shv winner");
    expect_read(12'h300, 32'h0000_1800, "T8 mnxti csrrci clears MIE");
    winner(1'b0, 6'd3, 8'h3F, 1'b0);
    nxti(OP_RS, 5'd8, 32'h0, "T8 mnxti no valid winner");
    csr_write(12'h347, OP_RW, 32'h0000_003F);
    winner(1'b1, 6'd17, 8'h3F, 1'b0);
    nxti(OP_RS, 5'd8, 32'h0, "T8 mnxti level <= mintthresh");
    csr_write(12'h347, OP_RW, 32'h0000_0000);
    winner(1'b1, 6'd17, 8'h4F, 1'b0);
    idle(); ex_addr = 12'h345; ex_op = OP_RS; ex_operand = 32'd8; ex_write = 1; ex_commit = 1; #1;
    if (claim_o !== 1'b1 || claim_id_o !== 6'd17 || ex_rdata !== 32'h0000_8084) fail("T8: mnxti claim");
    checks++;
    cycle("T8 mnxti claim");
    idle();
    expect_read(12'hFB1, 32'h4F00_0000, "T8 claim mil = level");
    expect_read(12'h342, 32'hB030_0011, "T8 claim mcause interrupt and id, mpil kept");
    expect_read(12'h300, 32'h0000_1808, "T8 claim sets MIE");
    // trap > MRET > mnxti: no claim, no side effect
    winner(1'b1, 6'd20, 8'hEF, 1'b0);
    idle(); trap = 1; trap_irq = 0; trap_cause = 6'd3; trap_pc = 32'h8; trap_tval = 0;
    ex_addr = 12'h345; ex_op = OP_RS; ex_operand = 32'd8; ex_write = 1; ex_commit = 1; #1;
    if (claim_o !== 1'b0) fail("T8: claim in a trap cycle");
    checks++;
    cycle("T8 trap and mnxti");
    idle(); mret = 1;
    ex_addr = 12'h345; ex_op = OP_RS; ex_operand = 32'd8; ex_write = 1; ex_commit = 1; #1;
    if (claim_o !== 1'b0) fail("T8: claim in an MRET cycle");
    checks++;
    cycle("T8 MRET and mnxti");
    // mnxti in CLINT mode: reads 0, MIE update proceeds, no mil/mcause update
    csr_write(12'h305, OP_RW, 32'h2000_0140);
    csr_write(12'h300, OP_RW, 32'h0000_0000);
    winner(1'b1, 6'd20, 8'hEF, 1'b0);
    nxti(OP_RS, 5'd8, 32'h0, "T8 CLINT mnxti");
    expect_read(12'h300, 32'h0000_1808, "T8 CLINT mnxti sets MIE");
    // mscratchcswl: (mpil == 0) != (mil == 0) in CLIC mode only
    csr_write(12'h305, OP_RW, 32'h2000_0143);
    csr_write(12'h340, OP_RW, 32'h1234_5678);
    for (int c = 0; c < 4; c++) begin
      csr_write(12'h342, OP_RW, c[0] ? 32'h0000_0000 : 32'h0011_0000);   // mpil 0 or 0x11
      // mil: an interrupt entry sets it (level 0x8F) or an MRET restores mpil = 0
      if (c[1]) begin
        winner(1'b1, 6'd2, 8'h8F, 1'b0);
        idle(); trap = 1; trap_irq = 1; trap_cause = 6'd2; trap_pc = 32'h10; cycle("T8 entry");
        csr_write(12'h342, OP_RW, c[0] ? 32'h0000_0000 : 32'h0011_0000);
      end else begin
        csr_write(12'h342, OP_RW, 32'h0000_0000); idle(); mret = 1; cycle("T8 mil 0");
        csr_write(12'h342, OP_RW, c[0] ? 32'h0000_0000 : 32'h0011_0000);
      end
      idle(); ex_addr = 12'h349; ex_op = OP_RW; ex_operand = 32'hA000_0000 + c; ex_write = 1; ex_commit = 1;
      #1; checks++;
      // swap when exactly one of mpil, mil is 0: c = 0 (mpil 0x11, mil 0) and c = 3 (mpil 0, mil 0x8F)
      if ((c == 0 || c == 3) ? (ex_rdata !== model_read(12'h340, 1'b0)) : (ex_rdata !== 32'hA000_0000 + c))
        fail($sformatf("T8: mscratchcswl case %0d read %08h", c, ex_rdata));
      cycle("T8 mscratchcswl");
      idle();
    end
    // CLINT mode: no swap
    csr_write(12'h305, OP_RW, 32'h2000_0140);
    idle(); ex_addr = 12'h349; ex_op = OP_RW; ex_operand = 32'h7777_7777; ex_write = 1; ex_commit = 1;
    #1; checks++;
    if (ex_rdata !== 32'h7777_7777) fail("T8: mscratchcswl swaps in CLINT mode");
    cycle("T8 CLINT mscratchcswl");
    idle();
    winner(1'b0, 6'd0, 8'h0F, 1'b0);
    csr_write(12'h307, OP_RW, 32'h0000_0000);

    // ---- T7: random against the model ----
    for (int i = 0; i < NUM_RANDOM; i++) begin
      int k;
      idle();
      k = $urandom % 100;
      if (k < 75) begin
        case ($urandom % 24)
          0: ex_addr = 12'h300;  1: ex_addr = 12'h301;  2: ex_addr = 12'h304;  3: ex_addr = 12'h305;
          4: ex_addr = 12'h340;  5: ex_addr = 12'h341;  6: ex_addr = 12'h342;  7: ex_addr = 12'h343;
          8: ex_addr = 12'hB00;  9: ex_addr = 12'hB80; 10: ex_addr = 12'hB02; 11: ex_addr = 12'hB82;
          12: ex_addr = 12'h344; 13: ex_addr = 12'h310; 14: ex_addr = 12'hF13;
          15: ex_addr = 12'h307; 16, 17: ex_addr = 12'h345; 18: ex_addr = 12'h347;
          19, 20: ex_addr = 12'h349; 21: ex_addr = 12'hFB1; 22: ex_addr = 12'h305;
          default: ex_addr = 12'hB00 + ($urandom % 32);
        endcase
      end else ex_addr = $urandom;
      ex_op = $urandom % 3;
      case ($urandom % 6)
        0: ex_operand = 32'hFFFF_FFFF;
        1: ex_operand = 32'hFFFF_FFFF - ($urandom % 4);
        2: ex_operand = 32'd0;
        3: ex_operand = 32'd1 << ($urandom % 32);
        default: ex_operand = $urandom;
      endcase
      // mtvec writes: often a mode switch (bits 1:0 = 11 or 00)
      if (ex_addr == 12'h305 && ($urandom % 2)) ex_operand[1:0] = ($urandom % 2) ? 2'b11 : 2'b00;
      ex_write  = ($urandom % 3) != 0;
      // reachable forms only (illegal forms never commit in the core): mnxti CSRRS/CSRRC with
      // a legal uimm (write = uimm != 0), mscratchcswl CSRRW
      if (ex_addr == 12'h345) begin
        ex_op = ($urandom % 2) ? OP_RS : OP_RC;
        ex_operand = {27'd0, 5'($urandom) & 5'b01010};
        ex_write = ex_operand != 32'd0;
      end
      if (ex_addr == 12'h349) begin ex_op = OP_RW; ex_write = 1; end
      ex_commit = ($urandom % 2) != 0;
      retire    = ($urandom % 2) != 0;
      trap      = ($urandom % 16) == 0;
      mret      = ($urandom % 16) == 0;
      trap_irq  = $urandom % 2;
      trap_minhv = ($urandom % 4) == 0;
      trap_cause = $urandom; trap_pc = $urandom; trap_tval = $urandom;
      // presented winner: often valid, levels around mpil/mintthresh
      irq_valid = ($urandom % 4) != 0;
      irq_id    = $urandom;
      irq_shv   = ($urandom % 4) == 0;
      irq_level = ($urandom % 2) ? {4'($urandom), 4'hF} : 8'($urandom);
      id_addr = ($urandom % 2) ? ex_addr : $urandom;
      id_write = $urandom % 2;
      id_op = $urandom; id_rd_zero = $urandom; id_imm = $urandom;
      if (($urandom % 5000) == 0) begin
        // asynchronous reset between edges
        #2 rst_n = 0; #1;
        model_reset();
        compare("T7 in reset");
        @(negedge clk); rst_n = 1; #1;
        idle();
      end
      cycle("T7");
    end

    // ---- coverage ----
    begin
      int holes;
      holes = 0;
      for (int k = 0; k <= 10; k++) if (cov_write[k] == 0) begin holes++; $display("hole: write kind %0d", k); end
      for (int k = 0; k < 3; k++)   if (cov_op[k] == 0)    begin holes++; $display("hole: op %0d", k); end
      for (int k = 0; k < 4; k++) begin
        if (cov_trap_combo[k] == 0) begin holes++; $display("hole: trap with MIE/MPIE %0d", k); end
        if (cov_mret_combo[k] == 0) begin holes++; $display("hole: mret with MIE/MPIE %0d", k); end
      end
      for (int k = 0; k < NCC; k++) if (cov_clic[k] < 2) begin holes++; $display("hole: CLIC case %0d", k); end
      if (cov_cyc_carry == 0)    begin holes++; $display("hole: mcycle carry"); end
      if (cov_ins_carry < 2)     begin holes++; $display("hole: minstret carry"); end
      if (cov_ret_write_lo == 0) begin holes++; $display("hole: retire + minstret write"); end
      if (cov_ret_write_hi == 0) begin holes++; $display("hole: retire + minstreth write"); end
      if (cov_read_ret == 0)     begin holes++; $display("hole: minstret read with retire"); end
      if (cov_trap_irq == 0)     begin holes++; $display("hole: interrupt bit"); end
      if (cov_prio_trap == 0)    begin holes++; $display("hole: trap and write"); end
      if (cov_prio_mret == 0)    begin holes++; $display("hole: mret and write"); end
      if (cov_nocommit == 0)     begin holes++; $display("hole: uncommitted write"); end
      if (holes != 0) fail($sformatf("%0d coverage holes", holes));
    end

    if (errors == 0)
      $display("PASS tb_px_csr (%0d checks, 4096 addresses x 2 legality and 1024 mnxti/mscratchcswl forms, %0d sub-unit ownership checks, %0d random cycles, full functional coverage)",
               checks, unit_checks, NUM_RANDOM);
    else begin
      $display("FAIL tb_px_csr (%0d errors, %0d checks)", errors, checks);
      $fatal(1, "tb_px_csr failed");
    end
    $finish;
  end

  initial begin
    #50_000_000;
    $display("FAIL tb_px_csr (TIMEOUT)");
    $fatal(1, "timeout");
  end

endmodule
