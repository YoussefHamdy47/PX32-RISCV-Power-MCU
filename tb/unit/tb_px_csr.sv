// tb_px_csr: self-checking unit test for px_csr (step 1.6, DECISIONS.md D-022).
//
// A reference model written from the privileged manual (64-bit counters as single 64-bit
// variables, fields kept as whole registers with legalization masks) is compared with
// the DUT every cycle, just before the clock edge: the EX read port, the ID legality
// output, noinc, mtvec_o, mepc_o and MIE. Directed tests also compare against explicit
// constants, so a mistake shared by the RTL and the model is still caught.
//
//   T1 reset values of every implemented CSR (explicit constants), counters held in reset
//   T2 legality of all 4096 addresses, with and without a write, against an explicit list
//   T3 every writable field (PMP CSRs: read-only 0): all-ones/all-zeros through RW, RS, RC, walking ones; reserved
//      and read-only bits read 0; WARL registers ignore writes
//   T4 no commit, no change: a write that does not commit leaves every CSR unchanged
//   T5 counters: mcycle every cycle, write of either half (no increment in that cycle),
//      carry into the high half, minstret with retirement, read including a retirement in
//      the same cycle, write on top of a same-cycle retirement, carry, noinc
//   T6 trap entry and MRET: all MIE/MPIE combinations, mepc bit 0, mcause interrupt bit,
//      priority trap > MRET > write
//   T7 random stimulus against the model (addresses near every implemented CSR, values
//      near counter wrap, simultaneous commit/retire/trap/MRET)
// Functional coverage bins must all be hit, otherwise the test fails.
//
// Run: scripts/run_unit.sh tb_px_csr [+vcd]

`timescale 1ns/1ps

module tb_px_csr;

  localparam logic [31:0] MTVEC_RESET = 32'h1000_0040;
  localparam logic [31:0] MIMPID      = 32'hABCD_0106;
  localparam int          NUM_RANDOM  = 40000;

  logic        clk = 1'b0;
  logic        rst_n;
  logic [11:0] id_addr, ex_addr;
  logic        id_write, id_illegal;
  logic [1:0]  ex_op;
  logic [31:0] ex_operand, ex_rdata;
  logic        ex_write, ex_commit, ex_noinc;
  logic        retire, trap, trap_irq, mret;
  logic [4:0]  trap_cause;
  logic [31:0] trap_pc, trap_tval, mtvec_o, mepc_o;
  logic        mie_o;

  px_csr #(.MTVEC_RESET(MTVEC_RESET), .MIMPID(MIMPID)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .id_addr_i(id_addr), .id_write_i(id_write), .id_illegal_o(id_illegal),
    .ex_addr_i(ex_addr), .ex_op_i(ex_op), .ex_operand_i(ex_operand), .ex_write_i(ex_write),
    .ex_commit_i(ex_commit), .ex_rdata_o(ex_rdata), .ex_noinc_o(ex_noinc),
    .retire_i(retire),
    .trap_i(trap), .trap_irq_i(trap_irq), .trap_cause_i(trap_cause), .trap_pc_i(trap_pc),
    .trap_tval_i(trap_tval), .mret_i(mret),
    .mtvec_o(mtvec_o), .mepc_o(mepc_o), .mstatus_mie_o(mie_o)
  );

  always #5 clk = ~clk;

  localparam logic [1:0] OP_RW = 2'd0, OP_RS = 2'd1, OP_RC = 2'd2;

  int checks = 0;
  int posedges = 0;
  always @(posedge clk) if (rst_n) posedges++;
  int errors = 0;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("ERROR %0t: %s", $time, msg);
  endtask

  // ---------------------------------------------------------------------------
  // Independent list of implemented CSRs (privileged manual table, D-022 subset)
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
  end

  function automatic bit model_illegal(input logic [11:0] a, input logic w);
    return !implemented[a] || (w && a[11:10] == 2'b11);
  endfunction

  // ---------------------------------------------------------------------------
  // Reference model state
  // ---------------------------------------------------------------------------
  logic        m_mie, m_mpie;
  logic [31:0] m_mtvec, m_mscratch, m_mepc, m_mcause, m_mtval;
  logic [63:0] m_cycle, m_instret;

  task automatic model_reset();
    m_mie = 0; m_mpie = 0;
    m_mtvec = MTVEC_RESET & 32'hFFFF_FFFC;
    m_mscratch = 0; m_mepc = 0; m_mcause = 0; m_mtval = 0;
    m_cycle = 0; m_instret = 0;
  endtask

  function automatic logic [31:0] model_read(input logic [11:0] a, input logic ret);
    logic [63:0] ir;
    ir = m_instret + (ret ? 64'd1 : 64'd0);
    case (a)
      12'h300: return 32'h0000_1800 | (m_mpie ? 32'h80 : 0) | (m_mie ? 32'h8 : 0);
      12'h301: return 32'h4000_1104;
      12'h305: return m_mtvec;
      12'h340: return m_mscratch;
      12'h341: return m_mepc;
      12'h342: return m_mcause;
      12'h343: return m_mtval;
      12'hB00: return m_cycle[31:0];
      12'hB80: return m_cycle[63:32];
      12'hB02: return ir[31:0];
      12'hB82: return ir[63:32];
      12'hF13: return MIMPID;
      default: return 32'd0;
    endcase
  endfunction

  // Coverage
  int cov_write [0:15];      // per written register kind, by op (index = kind*... see below)
  int cov_op [0:2];
  int cov_cyc_carry, cov_ins_carry, cov_ret_write_lo, cov_ret_write_hi, cov_read_ret;
  int cov_trap_combo [0:3], cov_mret_combo [0:3], cov_trap_irq, cov_prio_trap, cov_prio_mret;
  int cov_nocommit;

  // Model update at the clock edge, from the inputs of this cycle
  task automatic model_step();
    logic [31:0] old, wv;
    logic [63:0] ir;
    bit          we;
    ir  = m_instret + (retire ? 64'd1 : 64'd0);
    old = model_read(ex_addr, retire);
    case (ex_op)
      OP_RS:   wv = old | ex_operand;
      OP_RC:   wv = old & ~ex_operand;
      default: wv = ex_operand;
    endcase
    we = ex_commit && ex_write && !trap && !mret;
    if (ex_commit && ex_write && trap) cov_prio_trap++;
    if (ex_commit && ex_write && mret && !trap) cov_prio_mret++;
    if (ex_write && !ex_commit) cov_nocommit++;
    if (trap) begin
      cov_trap_combo[{m_mie, m_mpie}]++;
      if (trap_irq) cov_trap_irq++;
      m_mpie = m_mie; m_mie = 0;
      m_mepc = trap_pc & 32'hFFFF_FFFE;
      m_mcause = {trap_irq, 26'd0, trap_cause};
      m_mtval = trap_tval;
    end else if (mret) begin
      cov_mret_combo[{m_mie, m_mpie}]++;
      m_mie = m_mpie; m_mpie = 1;
    end else if (we) begin
      cov_op[ex_op]++;
      case (ex_addr)
        12'h300: begin m_mie = wv[3]; m_mpie = wv[7]; cov_write[0]++; end
        12'h305: begin m_mtvec = wv & 32'hFFFF_FFFC;   cov_write[1]++; end
        12'h340: begin m_mscratch = wv;                cov_write[2]++; end
        12'h341: begin m_mepc = wv & 32'hFFFF_FFFE;    cov_write[3]++; end
        12'h342: begin m_mcause = wv & 32'h8000_001F;  cov_write[4]++; end
        12'h343: begin m_mtval = wv;                   cov_write[5]++; end
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
    logic [31:0] exp;
    checks++;
    if (id_illegal !== model_illegal(id_addr, id_write))
      fail($sformatf("%s: id_illegal %b for addr %03h write %b", where, id_illegal, id_addr, id_write));
    exp = model_read(ex_addr, retire);
    if (ex_rdata !== exp)
      fail($sformatf("%s: read %03h = %08h, model %08h", where, ex_addr, ex_rdata, exp));
    if (ex_noinc !== (ex_write && (ex_addr == 12'hB02 || ex_addr == 12'hB82)))
      fail($sformatf("%s: noinc %b for addr %03h write %b", where, ex_noinc, ex_addr, ex_write));
    if (mtvec_o !== m_mtvec) fail($sformatf("%s: mtvec_o %08h, model %08h", where, mtvec_o, m_mtvec));
    if (mepc_o  !== m_mepc)  fail($sformatf("%s: mepc_o %08h, model %08h", where, mepc_o, m_mepc));
    if (mie_o   !== m_mie)   fail($sformatf("%s: MIE %b, model %b", where, mie_o, m_mie));
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
    ex_commit = 0; ex_write = 0; retire = 0; trap = 0; mret = 0; trap_irq = 0;
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
    cov_cyc_carry = 0; cov_ins_carry = 0; cov_ret_write_lo = 0; cov_ret_write_hi = 0;
    cov_read_ret = 0; cov_trap_irq = 0; cov_prio_trap = 0; cov_prio_mret = 0; cov_nocommit = 0;

    idle();
    id_addr = 12'h300; id_write = 0; ex_addr = 12'h300;
    trap_cause = 0; trap_pc = 0; trap_tval = 0;
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
    expect_read(12'h301, 32'h4000_1104, "T1 misa");
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

    // ---- T2: legality, exhaustive (combinational; the model catches up on mcycle) ----
    p2 = posedges;
    for (int a = 0; a < 4096; a++) begin
      for (int w = 0; w < 2; w++) begin
        id_addr = a; id_write = w;
        #1;
        checks++;
        if (id_illegal !== model_illegal(a, w))
          fail($sformatf("T2: addr %03h write %0d: illegal %b", a, w, id_illegal));
      end
    end
    // explicit spot checks independent of the list
    id_addr = 12'hC00; id_write = 1; #1; if (!id_illegal) fail("T2: cycle write accepted");
    id_addr = 12'hC00; id_write = 0; #1; if (!id_illegal) fail("T2: cycle (Zicntr) accepted");
    id_addr = 12'hF14; id_write = 0; #1; if (id_illegal)  fail("T2: mhartid read rejected");
    id_addr = 12'hF14; id_write = 1; #1; if (!id_illegal) fail("T2: mhartid write accepted");
    id_addr = 12'h301; id_write = 1; #1; if (id_illegal)  fail("T2: misa write rejected");
    id_addr = 12'h320; id_write = 0; #1; if (!id_illegal) fail("T2: mcountinhibit accepted");
    id_addr = 12'h306; id_write = 0; #1; if (!id_illegal) fail("T2: mcounteren accepted");
    id_addr = 12'hB01; id_write = 0; #1; if (!id_illegal) fail("T2: 0xB01 accepted");
    id_addr = 12'h001; id_write = 0; #1; if (!id_illegal) fail("T2: fflags accepted");
    checks += 9;
    @(posedge clk); #1;
    m_cycle = m_cycle + (posedges - p2);
    id_addr = 12'h300; id_write = 0;

    // ---- T3: fields ----
    csr_write(12'h300, OP_RW, 32'hFFFF_FFFF); expect_read(12'h300, 32'h0000_1888, "T3 mstatus ones");
    csr_write(12'h300, OP_RC, 32'h0000_0008); expect_read(12'h300, 32'h0000_1880, "T3 mstatus clear MIE");
    csr_write(12'h300, OP_RC, 32'hFFFF_FFFF); expect_read(12'h300, 32'h0000_1800, "T3 mstatus zeros");
    csr_write(12'h300, OP_RS, 32'h0000_0080); expect_read(12'h300, 32'h0000_1880, "T3 mstatus set MPIE");
    csr_write(12'h300, OP_RW, 32'h0000_0000); expect_read(12'h300, 32'h0000_1800, "T3 mstatus MPP fixed");
    csr_write(12'h301, OP_RW, 32'h0000_0000); expect_read(12'h301, 32'h4000_1104, "T3 misa fixed");
    csr_write(12'h304, OP_RW, 32'hFFFF_FFFF); expect_read(12'h304, 32'd0, "T3 mie read-only 0");
    csr_write(12'h344, OP_RS, 32'hFFFF_FFFF); expect_read(12'h344, 32'd0, "T3 mip read-only 0");
    csr_write(12'h310, OP_RW, 32'hFFFF_FFFF); expect_read(12'h310, 32'd0, "T3 mstatush 0");
    csr_write(12'h305, OP_RW, 32'hFFFF_FFFF); expect_read(12'h305, 32'hFFFF_FFFC, "T3 mtvec ones");
    csr_write(12'h305, OP_RW, 32'h1234_5679); expect_read(12'h305, 32'h1234_5678, "T3 mtvec mode 1 -> direct");
    csr_write(12'h305, OP_RW, 32'h1000_0043); expect_read(12'h305, 32'h1000_0040, "T3 mtvec mode 3 -> direct");
    csr_write(12'h341, OP_RW, 32'hFFFF_FFFF); expect_read(12'h341, 32'hFFFF_FFFE, "T3 mepc ones");
    csr_write(12'h341, OP_RW, 32'h1000_0002); expect_read(12'h341, 32'h1000_0002, "T3 mepc halfword");
    csr_write(12'h342, OP_RW, 32'hFFFF_FFFF); expect_read(12'h342, 32'h8000_001F, "T3 mcause ones");
    csr_write(12'h342, OP_RC, 32'h8000_0000); expect_read(12'h342, 32'h0000_001F, "T3 mcause clear irq");
    csr_write(12'h343, OP_RW, 32'hFFFF_FFFF); expect_read(12'h343, 32'hFFFF_FFFF, "T3 mtval ones");
    csr_write(12'h343, OP_RC, 32'h0F0F_0F0F); expect_read(12'h343, 32'hF0F0_F0F0, "T3 mtval RC");
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

    // ---- T6: trap entry and MRET ----
    for (int c = 0; c < 4; c++) begin
      csr_write(12'h300, OP_RW, {24'd0, c[1], 3'd0, c[0], 3'd0});   // MPIE = c[1], MIE = c[0]
      idle(); trap = 1; trap_cause = 5'd11; trap_pc = 32'h1000_1233; trap_tval = 32'hDEAD_0000 + c;
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
    // priority: trap over a write, MRET over a write
    csr_write(12'h343, OP_RW, 32'h1111_1111);
    idle(); trap = 1; trap_cause = 5'd2; trap_pc = 32'h4; trap_tval = 32'h2222_2222;
    ex_addr = 12'h343; ex_op = OP_RW; ex_operand = 32'h3333_3333; ex_write = 1; ex_commit = 1;
    cycle("T6 trap and write");
    expect_read(12'h343, 32'h2222_2222, "T6 trap wins over write");
    idle(); mret = 1;
    ex_addr = 12'h340; ex_op = OP_RW; ex_operand = 32'h4444_4444; ex_write = 1; ex_commit = 1;
    cycle("T6 mret and write");
    expect_read(12'h340, 32'h5A5A_5A5A, "T6 MRET drops the write");

    // ---- T7: random against the model ----
    for (int i = 0; i < NUM_RANDOM; i++) begin
      int k;
      idle();
      k = $urandom % 100;
      if (k < 70) begin
        case ($urandom % 16)
          0: ex_addr = 12'h300;  1: ex_addr = 12'h301;  2: ex_addr = 12'h304;  3: ex_addr = 12'h305;
          4: ex_addr = 12'h340;  5: ex_addr = 12'h341;  6: ex_addr = 12'h342;  7: ex_addr = 12'h343;
          8: ex_addr = 12'hB00;  9: ex_addr = 12'hB80; 10: ex_addr = 12'hB02; 11: ex_addr = 12'hB82;
          12: ex_addr = 12'h344; 13: ex_addr = 12'h310; 14: ex_addr = 12'hF13;
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
      ex_write  = ($urandom % 3) != 0;
      ex_commit = ($urandom % 2) != 0;
      retire    = ($urandom % 2) != 0;
      trap      = ($urandom % 16) == 0;
      mret      = ($urandom % 16) == 0;
      trap_irq  = $urandom % 2;
      trap_cause = $urandom; trap_pc = $urandom; trap_tval = $urandom;
      id_addr = ($urandom % 2) ? ex_addr : $urandom;
      id_write = $urandom % 2;
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
      $display("PASS tb_px_csr (%0d checks, 4096 addresses x 2 legality, %0d random cycles, full functional coverage)",
               checks, NUM_RANDOM);
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
