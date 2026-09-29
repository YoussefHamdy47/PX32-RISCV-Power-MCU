// tb_px_decoder: self-checking unit test for px_decoder.
//
// Three independent checks:
//   1. Directed: instruction words produced by the GNU assembler, with the complete
//      expected decode_t written out by hand for each one.
//   2. Golden vectors: 54,957 words (every opcode x funct3 x funct7 combination that
//      matters, every SYSTEM immediate, FENCE variants, CSR corner cases, random words)
//      compared against scripts/gen_decoder_vectors.py. That model is table driven
//      (mask/match) and is itself cross-checked against GNU objdump.
//   3. Properties that hold for every word regardless of any model: an illegal word has
//      no side effects, rd_we implies rd != 0, register fields pass through, and at most
//      one instruction class is active.
// Functional coverage: every mnemonic (and illegal), every value of every selector
// enum, every ALU operation, and the CSR read/write suppression cases must be hit.
//
// Run: scripts/run_unit.sh tb_px_decoder

`timescale 1ns/1ps

module tb_px_decoder;

  import px_pkg::*;

  localparam string VEC_FILE    = "tb/unit/vectors/decoder_vectors.hex";
  localparam int    MAX_IDS     = 64;

  logic [31:0] instr;
  decode_t     dec;

  px_decoder dut (.instr_i(instr), .dec_o(dec));

  int checks = 0;
  int errors = 0;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 25) $display("ERROR %s", msg);
  endtask

  // Field-by-field report of a mismatch.
  task automatic report_diff(input logic [31:0] w, input decode_t got, input decode_t exp);
    string s;
    s = $sformatf("instr %08h:", w);
    if (got.illegal      !== exp.illegal)      s = {s, $sformatf(" illegal %0d/%0d", got.illegal, exp.illegal)};
    if (got.rs1_used     !== exp.rs1_used)     s = {s, $sformatf(" rs1_used %0d/%0d", got.rs1_used, exp.rs1_used)};
    if (got.rs2_used     !== exp.rs2_used)     s = {s, $sformatf(" rs2_used %0d/%0d", got.rs2_used, exp.rs2_used)};
    if (got.rd_we        !== exp.rd_we)        s = {s, $sformatf(" rd_we %0d/%0d", got.rd_we, exp.rd_we)};
    if (got.imm          !== exp.imm)          s = {s, $sformatf(" imm %08h/%08h", got.imm, exp.imm)};
    if (got.alu_op       !== exp.alu_op)       s = {s, $sformatf(" alu_op %0d/%0d", got.alu_op, exp.alu_op)};
    if (got.op_a         !== exp.op_a)         s = {s, $sformatf(" op_a %0d/%0d", got.op_a, exp.op_a)};
    if (got.op_b         !== exp.op_b)         s = {s, $sformatf(" op_b %0d/%0d", got.op_b, exp.op_b)};
    if (got.wb_sel       !== exp.wb_sel)       s = {s, $sformatf(" wb_sel %0d/%0d", got.wb_sel, exp.wb_sel)};
    if (got.is_branch    !== exp.is_branch)    s = {s, $sformatf(" is_branch %0d/%0d", got.is_branch, exp.is_branch)};
    if (got.branch_f3    !== exp.branch_f3)    s = {s, $sformatf(" branch_f3 %0d/%0d", got.branch_f3, exp.branch_f3)};
    if (got.is_jal       !== exp.is_jal)       s = {s, $sformatf(" is_jal %0d/%0d", got.is_jal, exp.is_jal)};
    if (got.is_jalr      !== exp.is_jalr)      s = {s, $sformatf(" is_jalr %0d/%0d", got.is_jalr, exp.is_jalr)};
    if (got.is_load      !== exp.is_load)      s = {s, $sformatf(" is_load %0d/%0d", got.is_load, exp.is_load)};
    if (got.is_store     !== exp.is_store)     s = {s, $sformatf(" is_store %0d/%0d", got.is_store, exp.is_store)};
    if (got.mem_size     !== exp.mem_size)     s = {s, $sformatf(" mem_size %0d/%0d", got.mem_size, exp.mem_size)};
    if (got.mem_unsigned !== exp.mem_unsigned) s = {s, $sformatf(" mem_unsigned %0d/%0d", got.mem_unsigned, exp.mem_unsigned)};
    if (got.muldiv_en    !== exp.muldiv_en)    s = {s, $sformatf(" muldiv_en %0d/%0d", got.muldiv_en, exp.muldiv_en)};
    if (got.muldiv_op    !== exp.muldiv_op)    s = {s, $sformatf(" muldiv_op %0d/%0d", got.muldiv_op, exp.muldiv_op)};
    if (got.csr_en       !== exp.csr_en)       s = {s, $sformatf(" csr_en %0d/%0d", got.csr_en, exp.csr_en)};
    if (got.csr_op       !== exp.csr_op)       s = {s, $sformatf(" csr_op %0d/%0d", got.csr_op, exp.csr_op)};
    if (got.csr_use_imm  !== exp.csr_use_imm)  s = {s, $sformatf(" csr_use_imm %0d/%0d", got.csr_use_imm, exp.csr_use_imm)};
    if (got.csr_read     !== exp.csr_read)     s = {s, $sformatf(" csr_read %0d/%0d", got.csr_read, exp.csr_read)};
    if (got.csr_write    !== exp.csr_write)    s = {s, $sformatf(" csr_write %0d/%0d", got.csr_write, exp.csr_write)};
    if (got.csr_addr     !== exp.csr_addr)     s = {s, $sformatf(" csr_addr %03h/%03h", got.csr_addr, exp.csr_addr)};
    if ({got.is_ecall, got.is_ebreak, got.is_mret, got.is_wfi, got.is_fence, got.is_fence_i} !==
        {exp.is_ecall, exp.is_ebreak, exp.is_mret, exp.is_wfi, exp.is_fence, exp.is_fence_i})
      s = {s, " system/fence flags"};
    if ({got.rs1, got.rs2, got.rd} !== {exp.rs1, exp.rs2, exp.rd}) s = {s, " register fields"};
    fail({s, "  (got/expected)"});
  endtask

  task automatic apply_and_compare(input logic [31:0] w, input decode_t exp);
    instr = w;
    #1;
    checks++;
    if (dec !== exp) report_diff(w, dec, exp);
  endtask

  // Base expectation for a legal word: all zero except the raw register fields.
  function automatic decode_t base(input logic [31:0] w);
    decode_t e;
    e     = '0;
    e.rs1 = w[19:15];
    e.rs2 = w[24:20];
    e.rd  = w[11:7];
    return e;
  endfunction

  // ---------------------------------------------------------------------------
  // Properties (model independent)
  // ---------------------------------------------------------------------------
  task automatic check_properties(input logic [31:0] w);
    int classes;
    if (dec.rs1 !== w[19:15] || dec.rs2 !== w[24:20] || dec.rd !== w[11:7])
      fail($sformatf("instr %08h: register fields do not pass through", w));
    if (dec.rd_we && dec.rd == 5'd0)
      fail($sformatf("instr %08h: rd_we with rd = x0", w));
    if (dec.illegal) begin
      if (dec.rd_we || dec.rs1_used || dec.rs2_used || dec.is_branch || dec.is_jal || dec.is_jalr ||
          dec.is_load || dec.is_store || dec.muldiv_en || dec.csr_en || dec.csr_read || dec.csr_write ||
          dec.is_ecall || dec.is_ebreak || dec.is_mret || dec.is_wfi || dec.is_fence || dec.is_fence_i ||
          dec.imm != 32'd0)
        fail($sformatf("instr %08h: illegal instruction has side-effect fields set", w));
    end
    classes = dec.is_branch + dec.is_jal + dec.is_jalr + dec.is_load + dec.is_store + dec.muldiv_en +
              dec.csr_en + dec.is_ecall + dec.is_ebreak + dec.is_mret + dec.is_wfi + dec.is_fence +
              dec.is_fence_i;
    if (classes > 1) fail($sformatf("instr %08h: %0d instruction classes active", w, classes));
    if (!dec.csr_en && (dec.csr_read || dec.csr_write || dec.csr_addr != 12'd0))
      fail($sformatf("instr %08h: CSR fields set without csr_en", w));
    checks++;
  endtask

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------
  bit cov_id    [MAX_IDS];
  bit cov_alu   [10];
  bit cov_opa   [3];
  bit cov_opb   [3];
  bit cov_wb    [4];
  bit cov_size  [3];
  bit cov_csrop [3];
  bit cov_hint_rd0, cov_csr_no_read, cov_csr_no_write, cov_csr_imm, cov_load_unsigned;

  task automatic sample(input int id);
    cov_id[id] = 1'b1;
    if (!dec.illegal) begin
      if (dec.alu_op <= ALU_AND) cov_alu[dec.alu_op] = 1'b1;
      if (dec.op_a <= OPA_ZERO)  cov_opa[dec.op_a]   = 1'b1;
      if (dec.op_b <= OPB_LINK)  cov_opb[dec.op_b]   = 1'b1;
      cov_wb[dec.wb_sel] = 1'b1;
      if (dec.is_load || dec.is_store) cov_size[dec.mem_size] = 1'b1;
      if (dec.csr_en) begin
        cov_csrop[dec.csr_op] = 1'b1;
        if (!dec.csr_read)   cov_csr_no_read  = 1'b1;
        if (!dec.csr_write)  cov_csr_no_write = 1'b1;
        if (dec.csr_use_imm) cov_csr_imm      = 1'b1;
      end
      if (dec.is_load && dec.mem_unsigned) cov_load_unsigned = 1'b1;
      if (!dec.csr_en && !dec.is_store && !dec.is_branch && dec.rd == 5'd0 && !dec.rd_we &&
          (dec.op_b == OPB_IMM || dec.alu_op != ALU_ADD)) cov_hint_rd0 = 1'b1;
    end
  endtask

  function automatic int report_coverage(input int nids);
    int total, missing;
    total = 0; missing = 0;
    for (int i = 0; i < nids; i++) begin
      total++; if (!cov_id[i]) begin missing++; $display("  hole: mnemonic id %0d", i); end
    end
    for (int i = 0; i < 10; i++) begin total++; if (!cov_alu[i])   begin missing++; $display("  hole: alu_op %0d", i);   end end
    for (int i = 0; i < 3;  i++) begin total++; if (!cov_opa[i])   begin missing++; $display("  hole: op_a %0d", i);     end end
    for (int i = 0; i < 3;  i++) begin total++; if (!cov_opb[i])   begin missing++; $display("  hole: op_b %0d", i);     end end
    for (int i = 0; i < 4;  i++) begin total++; if (!cov_wb[i])    begin missing++; $display("  hole: wb_sel %0d", i);   end end
    for (int i = 0; i < 3;  i++) begin total++; if (!cov_size[i])  begin missing++; $display("  hole: mem_size %0d", i); end end
    for (int i = 0; i < 3;  i++) begin total++; if (!cov_csrop[i]) begin missing++; $display("  hole: csr_op %0d", i);   end end
    total++; if (!cov_hint_rd0)      begin missing++; $display("  hole: HINT with rd = x0");     end
    total++; if (!cov_csr_no_read)   begin missing++; $display("  hole: CSR read suppressed");   end
    total++; if (!cov_csr_no_write)  begin missing++; $display("  hole: CSR write suppressed");  end
    total++; if (!cov_csr_imm)       begin missing++; $display("  hole: CSR immediate form");    end
    total++; if (!cov_load_unsigned) begin missing++; $display("  hole: unsigned load");         end
    $display("coverage: %0d/%0d bins hit", total - missing, total);
    return missing;
  endfunction

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------

  initial begin
    decode_t e;
    int      count, nids, holes, id;
    decode_t exp_v;
    int      fd;
    logic [143:0] line;

    // ---------------- 1. Directed (encodings from the GNU assembler) ----------------
    e = base(32'hffb10093); e.rd_we = 1; e.rs1_used = 1; e.op_b = OPB_IMM; e.imm = 32'hFFFF_FFFB;
    apply_and_compare(32'hffb10093, e);                                    // addi x1,x2,-5
    e = base(32'h405201b3); e.rd_we = 1; e.rs1_used = 1; e.rs2_used = 1; e.alu_op = ALU_SUB;
    apply_and_compare(32'h405201b3, e);                                    // sub x3,x4,x5
    e = base(32'hffe3d303); e.rd_we = 1; e.rs1_used = 1; e.op_b = OPB_IMM; e.imm = 32'hFFFF_FFFE;
    e.is_load = 1; e.wb_sel = WB_MEM; e.mem_size = MEM_H; e.mem_unsigned = 1;
    apply_and_compare(32'hffe3d303, e);                                    // lhu x6,-2(x7)
    e = base(32'h7e84ae23); e.rs1_used = 1; e.rs2_used = 1; e.op_b = OPB_IMM; e.imm = 32'd2044;
    e.is_store = 1; e.mem_size = MEM_W;
    apply_and_compare(32'h7e84ae23, e);                                    // sw x8,2044(x9)
    e = base(32'h80b50063); e.rs1_used = 1; e.rs2_used = 1; e.is_branch = 1; e.branch_f3 = F3_BEQ;
    e.imm = 32'hFFFF_F000;
    apply_and_compare(32'h80b50063, e);                                    // beq x10,x11,-4096
    e = base(32'h7ffff0ef); e.rd_we = 1; e.is_jal = 1; e.op_a = OPA_PC; e.op_b = OPB_LINK;
    e.imm = 32'h000F_FFFE;
    apply_and_compare(32'h7ffff0ef, e);                                    // jal x1,+1048574
    e = base(32'h00008067); e.is_jalr = 1; e.rs1_used = 1; e.op_a = OPA_PC; e.op_b = OPB_LINK;
    apply_and_compare(32'h00008067, e);                                    // jalr x0,0(x1): rd_we 0
    e = base(32'hfffff637); e.rd_we = 1; e.op_a = OPA_ZERO; e.op_b = OPB_IMM; e.imm = 32'hFFFF_F000;
    apply_and_compare(32'hfffff637, e);                                    // lui x12,0xfffff
    e = base(32'h00001697); e.rd_we = 1; e.op_a = OPA_PC; e.op_b = OPB_IMM; e.imm = 32'h0000_1000;
    apply_and_compare(32'h00001697, e);                                    // auipc x13,1
    e = base(32'h41f7d713); e.rd_we = 1; e.rs1_used = 1; e.op_b = OPB_IMM; e.imm = 32'h0000_041F;
    e.alu_op = ALU_SRA;
    apply_and_compare(32'h41f7d713, e);                                    // srai x14,x15,31
    e = base(32'h0328a833); e.rd_we = 1; e.rs1_used = 1; e.rs2_used = 1; e.muldiv_en = 1;
    e.muldiv_op = F3_MULHSU; e.wb_sel = WB_MULDIV;
    apply_and_compare(32'h0328a833, e);                                    // mulhsu x16,x17,x18
    e = base(32'h035a79b3); e.rd_we = 1; e.rs1_used = 1; e.rs2_used = 1; e.muldiv_en = 1;
    e.muldiv_op = F3_REMU; e.wb_sel = WB_MULDIV;
    apply_and_compare(32'h035a79b3, e);                                    // remu x19,x20,x21
    e = base(32'h34029073); e.csr_en = 1; e.csr_op = CSR_RW; e.csr_addr = CSR_MSCRATCH;
    e.csr_read = 0; e.csr_write = 1; e.rs1_used = 1; e.wb_sel = WB_CSR;
    apply_and_compare(32'h34029073, e);                                    // csrrw x0,mscratch,x5
    e = base(32'h30002373); e.csr_en = 1; e.csr_op = CSR_RS; e.csr_addr = CSR_MSTATUS;
    e.csr_read = 1; e.csr_write = 0; e.rs1_used = 1; e.rd_we = 1; e.wb_sel = WB_CSR;
    apply_and_compare(32'h30002373, e);                                    // csrrs x6,mstatus,x0
    e = base(32'h304073f3); e.csr_en = 1; e.csr_op = CSR_RC; e.csr_addr = CSR_MIE; e.csr_use_imm = 1;
    e.csr_read = 1; e.csr_write = 0; e.rd_we = 1; e.wb_sel = WB_CSR; e.imm = 32'd0;
    apply_and_compare(32'h304073f3, e);                                    // csrrci x7,mie,0
    e = base(32'h305fe073); e.csr_en = 1; e.csr_op = CSR_RS; e.csr_addr = CSR_MTVEC; e.csr_use_imm = 1;
    e.csr_read = 1; e.csr_write = 1; e.wb_sel = WB_CSR; e.imm = 32'd31;
    apply_and_compare(32'h305fe073, e);                                    // csrrsi x0,mtvec,31
    e = base(32'h0310000f); e.is_fence = 1;   apply_and_compare(32'h0310000f, e);   // fence rw,w
    e = base(32'h0000100f); e.is_fence_i = 1; apply_and_compare(32'h0000100f, e);   // fence.i
    e = base(32'h00000073); e.is_ecall = 1;   apply_and_compare(32'h00000073, e);   // ecall
    e = base(32'h00100073); e.is_ebreak = 1;  apply_and_compare(32'h00100073, e);   // ebreak
    e = base(32'h30200073); e.is_mret = 1;    apply_and_compare(32'h30200073, e);   // mret
    e = base(32'h10500073); e.is_wfi = 1;     apply_and_compare(32'h10500073, e);   // wfi
    e = base(32'h00000013); e.rs1_used = 1; e.op_b = OPB_IMM;
    apply_and_compare(32'h00000013, e);                                    // nop (HINT form): rd_we 0
    e = '0; e.illegal = 1; e.rs1 = 5'd0; e.rs2 = 5'd2; e.rd = 5'd0;
    apply_and_compare(32'h10200073, e);                                    // sret: illegal in M-only core
    e = '0; e.illegal = 1; e.rs2 = 5'd21; e.rs1 = 5'd2; e.rd = 5'd1;
    apply_and_compare(32'h03511093, e);                                    // slli x1,x2,53: RV64 only

    // ---------------- 2 + 3. Golden vectors and properties ----------------
    // Streamed with $fscanf (the vector count is only known from the header line).
    fd = $fopen(VEC_FILE, "r");
    if (fd == 0) begin
      $display("FAIL tb_px_decoder (could not open %s)", VEC_FILE);
      $finish;
    end
    if ($fscanf(fd, "%h", line) != 1) begin
      $display("FAIL tb_px_decoder (empty vector file)");
      $finish;
    end
    nids  = int'(line[143:136]);
    count = int'(line[135:104]);
    if (count < 1 || nids > MAX_IDS) begin
      $display("FAIL tb_px_decoder (bad vector header: %0d vectors, %0d ids)", count, nids);
      $finish;
    end
    for (int n = 1; n <= count; n++) begin
      if ($fscanf(fd, "%h", line) != 1) begin
        $display("FAIL tb_px_decoder (vector file ends after %0d of %0d vectors)", n - 1, count);
        $finish;
      end
      id    = int'(line[143:136]);
      exp_v = decode_t'(line[100:0]);
      apply_and_compare(line[135:104], exp_v);
      check_properties(line[135:104]);
      sample(id);
    end
    $fclose(fd);

    holes = report_coverage(nids);
    if (errors == 0 && holes == 0)
      $display("PASS tb_px_decoder (%0d checks, %0d golden vectors, full functional coverage)", checks, count);
    else
      $display("FAIL tb_px_decoder (%0d errors / %0d checks, %0d coverage holes)", errors, checks, holes);
    $finish;
  end

endmodule
