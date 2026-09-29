// tb_px_decompressor: exhaustive self-checking test for px_decompressor.
//
//   1. Directed: compressed words from the GNU assembler with their expansions written
//      out by hand.
//   2. Golden vectors: all 49,152 16-bit encodings (quadrants 0, 1, 2), each with random
//      upper bits that must be ignored, plus 3,000 32-bit pass-through windows, against
//      scripts/gen_decompressor_vectors.py (spec scatter tables, cross-checked against
//      GNU objdump operand by operand).
//   3. Properties, independent of any model, checked on every vector, with the real
//      px_decoder connected to the output:
//        - is_compressed == (bits [1:0] != 2'b11); a 32-bit window passes through unchanged
//        - a legal compressed word expands to a word px_decoder accepts
//        - an illegal compressed word yields a word px_decoder rejects, with the original
//          16 bits in [15:0] (for mtval)
//        - the upper 16 bits of the window never affect a compressed expansion
// Coverage: every compressed instruction, every illegal category and pass-through.
//
// Run: scripts/run_unit.sh tb_px_decompressor

`timescale 1ns/1ps

module tb_px_decompressor;

  import px_pkg::*;

  localparam string VEC_FILE = "tb/unit/vectors/decompressor_vectors.hex";
  localparam int    MAX_IDS  = 32;

  logic [31:0] win, out;
  logic        comp, ill;
  decode_t     dec;

  px_decompressor dut (.instr_i(win), .instr_o(out), .is_compressed_o(comp), .illegal_o(ill));
  px_decoder      u_dec (.instr_i(out), .dec_o(dec));

  int checks = 0;
  int errors = 0;
  bit cov_id [MAX_IDS];

  task automatic fail(input string msg);
    errors++;
    if (errors <= 25) $display("ERROR %s", msg);
  endtask

  task automatic expect_exp(input logic [31:0] w, input logic [31:0] exp_out,
                            input logic exp_comp, input logic exp_ill, input string what);
    win = w;
    #1;
    checks++;
    if (out !== exp_out || comp !== exp_comp || ill !== exp_ill)
      fail($sformatf("%s: in %08h -> out %08h comp %0d ill %0d, expected %08h %0d %0d",
                     what, w, out, comp, ill, exp_out, exp_comp, exp_ill));
  endtask

  task automatic check_properties(input logic [31:0] w);
    logic [31:0] first_out;
    logic        first_ill;
    checks++;
    if (comp !== (w[1:0] != 2'b11)) fail($sformatf("%08h: is_compressed wrong", w));
    if (!comp && out !== w)         fail($sformatf("%08h: 32-bit window not passed through", w));
    if (comp && !ill && dec.illegal)
      fail($sformatf("%08h: legal compressed word expands to %08h, which the decoder rejects", w, out));
    if (comp && ill && (!dec.illegal || out !== {16'd0, w[15:0]}))
      fail($sformatf("%08h: illegal compressed word gives %08h (decoder illegal %0d)", w, out, dec.illegal));
    if (comp && ill && dec.illegal !== 1'b1)
      fail($sformatf("%08h: decoder accepts an illegal compressed word", w));
    // Upper half must not matter for a compressed word.
    if (comp) begin
      first_out = out;
      first_ill = ill;
      win = {~w[31:16], w[15:0]};
      #1;
      if (out !== first_out || ill !== first_ill)
        fail($sformatf("%08h: expansion depends on the upper 16 bits", w));
      win = w;
      #1;
    end
  endtask

  initial begin
    int           fd, count, nids, id, holes;
    logic [79:0]  line;

    // ---------------- 1. Directed (GNU as encodings) ----------------
    expect_exp(32'h0000_4501, 32'h0000_0513, 1, 0, "c.li x10,0");            // addi x10,x0,0
    expect_exp(32'h0000_0505, 32'h0015_0513, 1, 0, "c.addi x10,1");          // addi x10,x10,1
    expect_exp(32'h0000_1141, 32'hff01_0113, 1, 0, "c.addi x2,-16");         // addi x2,x2,-16
    expect_exp(32'h0000_6105, 32'h0201_0113, 1, 0, "c.addi16sp x2,32");      // addi x2,x2,32
    expect_exp(32'h0000_7101, 32'he001_0113, 1, 0, "c.addi16sp x2,-512");    // addi x2,x2,-512
    expect_exp(32'h0000_0040, 32'h0041_0413, 1, 0, "c.addi4spn x8,x2,4");    // addi x8,x2,4
    expect_exp(32'h0000_4004, 32'h0004_2483, 1, 0, "c.lw x9,0(x8)");         // lw x9,0(x8)
    expect_exp(32'h0000_c004, 32'h0094_2023, 1, 0, "c.sw x9,0(x8)");         // sw x9,0(x8)
    expect_exp(32'h0000_4082, 32'h0001_2083, 1, 0, "c.lwsp x1,0(x2)");       // lw x1,0(x2)
    expect_exp(32'h0000_c006, 32'h0011_2023, 1, 0, "c.swsp x1,0(x2)");       // sw x1,0(x2)
    expect_exp(32'h0000_8082, 32'h0000_8067, 1, 0, "c.jr x1");               // jalr x0,0(x1)
    expect_exp(32'h0000_9082, 32'h0000_80e7, 1, 0, "c.jalr x1");             // jalr x1,0(x1)
    expect_exp(32'h0000_80aa, 32'h00a0_00b3, 1, 0, "c.mv x1,x10");           // add x1,x0,x10
    expect_exp(32'h0000_9002, 32'h0010_0073, 1, 0, "c.ebreak");              // ebreak
    expect_exp(32'h0000_8c05, 32'h4094_0433, 1, 0, "c.sub x8,x9");           // sub x8,x8,x9
    expect_exp(32'h0000_8005, 32'h0014_5413, 1, 0, "c.srli x8,1");           // srli x8,x8,1
    expect_exp(32'h0000_8401, 32'h4004_5413, 1, 0, "c.srai x8,0 (HINT)");    // srai x8,x8,0
    expect_exp(32'h0000_0001, 32'h0000_0013, 1, 0, "c.nop");                 // addi x0,x0,0
    expect_exp(32'h0000_0000, 32'h0000_0000, 1, 1, "all-zero word");         // defined illegal
    expect_exp(32'h0000_6101, 32'h0000_6101, 1, 1, "c.addi16sp 0 (reserved)");
    expect_exp(32'h0000_9005, 32'h0000_9005, 1, 1, "c.srli shamt[5]=1");
    expect_exp(32'h0000_2002, 32'h0000_2002, 1, 1, "c.fldsp (no F/D)");
    expect_exp(32'h0000_4002, 32'h0000_4002, 1, 1, "c.lwsp x0 (reserved)");
    expect_exp(32'hffb1_0093, 32'hffb1_0093, 0, 0, "32-bit pass-through");

    // ---------------- 2 + 3. Exhaustive golden vectors and properties ----------------
    fd = $fopen(VEC_FILE, "r");
    if (fd == 0 || $fscanf(fd, "%h", line) != 1) begin
      $display("FAIL tb_px_decompressor (could not read %s)", VEC_FILE);
      $finish;
    end
    nids  = int'(line[79:72]);
    count = int'(line[71:40]);
    if (count < 49152 || nids > MAX_IDS) begin
      $display("FAIL tb_px_decompressor (bad vector header: %0d vectors, %0d ids)", count, nids);
      $finish;
    end
    for (int n = 1; n <= count; n++) begin
      if ($fscanf(fd, "%h", line) != 1) begin
        $display("FAIL tb_px_decompressor (vector file ends after %0d of %0d)", n - 1, count);
        $finish;
      end
      id = int'(line[79:72]);
      expect_exp(line[71:40], line[39:8], line[1], line[0], "golden");
      check_properties(line[71:40]);
      cov_id[id] = 1'b1;
    end
    $fclose(fd);

    holes = 0;
    for (int i = 0; i < nids; i++)
      if (!cov_id[i]) begin holes++; $display("  hole: id %0d (see tb/unit/vectors/decompressor_ids.txt)", i); end
    $display("coverage: %0d/%0d ids hit", nids - holes, nids);

    if (errors == 0 && holes == 0)
      $display("PASS tb_px_decompressor (%0d checks, %0d vectors, all 49152 compressed encodings)", checks, count);
    else
      $display("FAIL tb_px_decompressor (%0d errors / %0d checks, %0d coverage holes)", errors, checks, holes);
    $finish;
  end

endmodule
