// tb_px_alu: self-checking unit test for px_alu.
//
// Checks every defined operation (RV32I, Zba, Zbb, Zbs, Zicond: 36) and the three compare
// flags against an independent reference model:
//   1. all pairs from a table of corner values, for every operation
//   2. every shift, rotate and bit-index amount 0..31, with junk in b_i[31:5]
//   3. CLZ/CTZ/CPOP on 0, all ones, every single bit, every single zero, every low and high
//      mask (every count value 0..32 for each of the three)
//   4. random operands (fixed seed, reproducible), with b = 0 and b = a mixed in
//   5. undefined op codes (36..63) return 0
// The reference is written bit by bit (shifts, rotates, counts, byte and single-bit
// operations) so it does not reuse the RTL's operators or structure.
//
// Run: scripts/run_unit.sh tb_px_alu   (add +vcd for a waveform in sim/tb_px_alu.vcd)

`timescale 1ns/1ps

module tb_px_alu;

  import px_pkg::*;

  localparam int NUM_RANDOM = 36000;
  localparam int NUM_OPS    = ALU_NUM_OPS;
  localparam int NUM_SHIFTS = 9;   // SLL SRL SRA ROL ROR BCLR BEXT BINV BSET

  alu_op_e     op;
  logic [31:0] a, b;
  logic [31:0] res;
  logic        eq, lt, ltu;

  int checks = 0;
  int errors = 0;

  px_alu dut (
    .op_i    (op),
    .a_i     (a),
    .b_i     (b),
    .result_o(res),
    .eq_o    (eq),
    .lt_o    (lt),
    .ltu_o   (ltu)
  );

  // Filled element by element in init_tables(): Icarus 12 does not support
  // whole-array assignment patterns.
  alu_op_e     ops     [NUM_OPS];
  alu_op_e     shops   [NUM_SHIFTS];
  logic [31:0] corners [16];

  task automatic init_tables();
    for (int k = 0; k < NUM_OPS; k++) ops[k] = alu_op_e'(k);
    shops[0] = ALU_SLL;  shops[1] = ALU_SRL;  shops[2] = ALU_SRA;  shops[3] = ALU_ROL;
    shops[4] = ALU_ROR;  shops[5] = ALU_BCLR; shops[6] = ALU_BEXT; shops[7] = ALU_BINV;
    shops[8] = ALU_BSET;

    corners[0]  = 32'h0000_0000; corners[1]  = 32'h0000_0001;
    corners[2]  = 32'h0000_0002; corners[3]  = 32'h0000_001F;
    corners[4]  = 32'h0000_0020; corners[5]  = 32'h7FFF_FFFE;
    corners[6]  = 32'h7FFF_FFFF; corners[7]  = 32'h8000_0000;
    corners[8]  = 32'h8000_0001; corners[9]  = 32'hFFFF_FFFE;
    corners[10] = 32'hFFFF_FFFF; corners[11] = 32'h5555_5555;
    corners[12] = 32'hAAAA_AAAA; corners[13] = 32'h0000_FFFF;
    corners[14] = 32'hFFFF_0000; corners[15] = 32'h1234_5678;
  endtask

  // ---------------------------------------------------------------------------
  // Reference model (unprivileged ISA 20240411: RV32I, Zba/Zbb/Zbs 1.0.0, Zicond 1.0)
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] ref_shift(input logic [31:0] x, input logic [4:0] s,
                                            input bit left, input bit arith);
    logic [31:0] r;
    r = x;
    for (int i = 0; i < s; i++) begin
      if (left) r = {r[30:0], 1'b0};
      else      r = {(arith ? r[31] : 1'b0), r[31:1]};
    end
    return r;
  endfunction

  // Rotate one position at a time.
  function automatic logic [31:0] ref_rot(input logic [31:0] x, input logic [4:0] s, input bit left);
    logic [31:0] r;
    r = x;
    for (int i = 0; i < s; i++) begin
      if (left) r = {r[30:0], r[31]};
      else      r = {r[0], r[31:1]};
    end
    return r;
  endfunction

  function automatic logic [31:0] ref_clz(input logic [31:0] x);
    int n;
    bit found;
    n = 0; found = 0;
    for (int i = 31; i >= 0; i--) begin
      if (x[i]) found = 1;
      if (!found) n++;
    end
    return n;
  endfunction

  function automatic logic [31:0] ref_ctz(input logic [31:0] x);
    int n;
    bit found;
    n = 0; found = 0;
    for (int i = 0; i < 32; i++) begin
      if (x[i]) found = 1;
      if (!found) n++;
    end
    return n;
  endfunction

  function automatic logic [31:0] ref_cpop(input logic [31:0] x);
    int n;
    n = 0;
    for (int i = 0; i < 32; i++) if (x[i]) n++;
    return n;
  endfunction

  function automatic logic [31:0] ref_orcb(input logic [31:0] x);
    logic [31:0] r;
    r = 32'd0;
    for (int i = 0; i < 32; i++) if (x[i]) r = r | (32'hFF << (8 * (i / 8)));
    return r;
  endfunction

  function automatic logic [31:0] ref_rev8(input logic [31:0] x);
    logic [31:0] r;
    for (int i = 0; i < 32; i++) r[8 * (3 - i / 8) + i % 8] = x[i];
    return r;
  endfunction

  // Single-bit operations: kind 0 clear, 1 extract, 2 invert, 3 set
  function automatic logic [31:0] ref_bit(input logic [31:0] x, input logic [4:0] idx, input int kind);
    logic [31:0] r;
    r = x;
    case (kind)
      0: r[idx] = 1'b0;
      1: r = {31'd0, x[idx]};
      2: r[idx] = !x[idx];
      default: r[idx] = 1'b1;
    endcase
    return r;
  endfunction

  function automatic logic [31:0] ref_result(input alu_op_e o, input logic [31:0] x,
                                             input logic [31:0] y);
    case (o)
      ALU_ADD:       return x + y;
      ALU_SH1ADD:    return y + ref_shift(x, 5'd1, 1'b1, 1'b0);
      ALU_SH2ADD:    return y + ref_shift(x, 5'd2, 1'b1, 1'b0);
      ALU_SH3ADD:    return y + ref_shift(x, 5'd3, 1'b1, 1'b0);
      ALU_SUB:       return x - y;
      ALU_SLL:       return ref_shift(x, y[4:0], 1'b1, 1'b0);
      ALU_SLT:       return ($signed(x) < $signed(y)) ? 32'd1 : 32'd0;
      ALU_SLTU:      return (x < y) ? 32'd1 : 32'd0;
      ALU_XOR:       return x ^ y;
      ALU_SRL:       return ref_shift(x, y[4:0], 1'b0, 1'b0);
      ALU_SRA:       return ref_shift(x, y[4:0], 1'b0, 1'b1);
      ALU_OR:        return x | y;
      ALU_AND:       return x & y;
      ALU_ANDN:      return x & ~y;
      ALU_ORN:       return x | ~y;
      ALU_XNOR:      return ~(x ^ y);
      ALU_CLZ:       return ref_clz(x);
      ALU_CTZ:       return ref_ctz(x);
      ALU_CPOP:      return ref_cpop(x);
      ALU_MAX:       return ($signed(x) < $signed(y)) ? y : x;
      ALU_MAXU:      return (x < y) ? y : x;
      ALU_MIN:       return ($signed(x) < $signed(y)) ? x : y;
      ALU_MINU:      return (x < y) ? x : y;
      ALU_SEXTB:     return {{24{x[7]}}, x[7:0]};
      ALU_SEXTH:     return {{16{x[15]}}, x[15:0]};
      ALU_ZEXTH:     return {16'd0, x[15:0]};
      ALU_ROL:       return ref_rot(x, y[4:0], 1'b1);
      ALU_ROR:       return ref_rot(x, y[4:0], 1'b0);
      ALU_ORCB:      return ref_orcb(x);
      ALU_REV8:      return ref_rev8(x);
      ALU_BCLR:      return ref_bit(x, y[4:0], 0);
      ALU_BEXT:      return ref_bit(x, y[4:0], 1);
      ALU_BINV:      return ref_bit(x, y[4:0], 2);
      ALU_BSET:      return ref_bit(x, y[4:0], 3);
      ALU_CZERO_EQZ: return (y == 32'd0) ? 32'd0 : x;
      ALU_CZERO_NEZ: return (y != 32'd0) ? 32'd0 : x;
      default:       return 32'd0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Apply one vector and compare result + flags
  // ---------------------------------------------------------------------------
  task automatic check(input alu_op_e o, input logic [31:0] x, input logic [31:0] y);
    logic [31:0] exp_res;
    logic        exp_eq, exp_lt, exp_ltu;
    op = o; a = x; b = y;
    #1;
    exp_res = ref_result(o, x, y);
    exp_eq  = (x == y);
    exp_lt  = ($signed(x) < $signed(y));
    exp_ltu = (x < y);
    checks++;
    if (res !== exp_res || eq !== exp_eq || lt !== exp_lt || ltu !== exp_ltu) begin
      errors++;
      if (errors <= 20)
        $display("ERROR op=%0d a=%08h b=%08h : res=%08h exp=%08h  eq/lt/ltu=%b%b%b exp=%b%b%b",
                 o, x, y, res, exp_res, eq, lt, ltu, exp_eq, exp_lt, exp_ltu);
    end
    sample_coverage(o, x, y);
  endtask

  // ---------------------------------------------------------------------------
  // Functional coverage (hand-written bins: Icarus has no covergroups).
  // Every bin must be hit, otherwise the test fails: a passing run with a hole in
  // the stimulus would prove nothing about that case.
  // ---------------------------------------------------------------------------
  bit cov_sign    [NUM_OPS][4];  // operand sign combination {a[31], b[31]} per op
  bit cov_zero    [NUM_OPS];     // result == 0 per op (where reachable, see zero_reachable)
  bit cov_nonzero [NUM_OPS];     // result != 0 per op
  bit cov_msb     [NUM_OPS];     // result[31] == 1 per op (where reachable, see msb_reachable)
  bit cov_flags   [5];           // eq | lt&ltu | lt&!ltu | !lt&ltu | !lt&!ltu&!eq
  bit cov_shamt   [NUM_SHIFTS][32];  // every shift/rotate/bit-index type x every amount
  bit cov_count   [3][33];       // CLZ/CTZ/CPOP x every result value 0..32
  bit cov_shadd_lost [3];        // SHnADD: a nonzero bit of a shifted out
  bit cov_shadd_carry [3];       // SHnADD: carry out of the 32-bit add
  bit cov_minmax  [4][2];        // MAX/MAXU/MIN/MINU x {a chosen and a != b, b chosen and a != b}
  bit cov_czero   [2][2];        // CZERO.EQZ/NEZ x {condition zero, condition nonzero}
  bit cov_bit0    [32];          // each result bit seen as 0 ...
  bit cov_bit1    [32];          // ... and as 1
  bit cov_add_ovf, cov_add_carry, cov_sub_ovf, cov_sub_borrow, cov_undef;

  function automatic bit msb_reachable(input alu_op_e o);
    return !(o == ALU_SLT || o == ALU_SLTU || o == ALU_CLZ || o == ALU_CTZ || o == ALU_CPOP ||
             o == ALU_BEXT || o == ALU_ZEXTH);
  endfunction

  // BSET always sets a bit: its result is never zero.
  function automatic bit zero_reachable(input alu_op_e o);
    return o != ALU_BSET;
  endfunction

  function automatic int shift_index(input alu_op_e o);
    for (int t = 0; t < NUM_SHIFTS; t++) if (shops[t] == o) return t;
    return -1;
  endfunction

  task automatic sample_coverage(input alu_op_e o, input logic [31:0] x, input logic [31:0] y);
    int k;
    k = int'(o);
    if (k >= NUM_OPS) begin
      cov_undef = 1'b1;
    end else begin
      sample_defined(k, o, x, y);
    end
  endtask

  task automatic sample_defined(input int k, input alu_op_e o, input logic [31:0] x,
                                input logic [31:0] y);
    logic [32:0] s33;
    logic [31:0] d;
    int          t, n;
    cov_sign[k][{x[31], y[31]}] = 1'b1;
    if (res == 32'd0) cov_zero[k]    = 1'b1;
    else              cov_nonzero[k] = 1'b1;
    if (res[31])      cov_msb[k]     = 1'b1;
    for (int i = 0; i < 32; i++) begin
      if (res[i]) cov_bit1[i] = 1'b1;
      else        cov_bit0[i] = 1'b1;
    end

    if (eq)              cov_flags[0] = 1'b1;
    else if (lt && ltu)  cov_flags[1] = 1'b1;
    else if (lt)         cov_flags[2] = 1'b1;
    else if (ltu)        cov_flags[3] = 1'b1;
    else                 cov_flags[4] = 1'b1;

    t = shift_index(o);
    if (t >= 0) cov_shamt[t][y[4:0]] = 1'b1;

    case (o)
      ALU_ADD: begin
        s33 = {1'b0, x} + {1'b0, y};
        if (s33[32]) cov_add_carry = 1'b1;
        if (x[31] == y[31] && s33[31] != x[31]) cov_add_ovf = 1'b1;
      end
      ALU_SUB: begin
        d = x - y;
        if (x < y) cov_sub_borrow = 1'b1;
        if (x[31] != y[31] && d[31] != x[31]) cov_sub_ovf = 1'b1;
      end
      ALU_SH1ADD, ALU_SH2ADD, ALU_SH3ADD: begin
        n = int'(o) - int'(ALU_SH1ADD);
        if ((x >> (31 - n)) != 32'd0) cov_shadd_lost[n] = 1'b1;
        s33 = {1'b0, ref_shift(x, n + 1, 1'b1, 1'b0)} + {1'b0, y};
        if (s33[32]) cov_shadd_carry[n] = 1'b1;
      end
      ALU_CLZ:  if (res <= 32) cov_count[0][res] = 1'b1;
      ALU_CTZ:  if (res <= 32) cov_count[1][res] = 1'b1;
      ALU_CPOP: if (res <= 32) cov_count[2][res] = 1'b1;
      ALU_MAX, ALU_MAXU, ALU_MIN, ALU_MINU: begin
        n = int'(o) - int'(ALU_MAX);
        if (x != y && res == x) cov_minmax[n][0] = 1'b1;
        if (x != y && res == y) cov_minmax[n][1] = 1'b1;
      end
      ALU_CZERO_EQZ: cov_czero[0][y != 32'd0] = 1'b1;
      ALU_CZERO_NEZ: cov_czero[1][y != 32'd0] = 1'b1;
      default: ;
    endcase
  endtask

  // Returns the number of unhit bins and prints each one.
  function automatic int report_coverage();
    int total, missing;
    total = 0; missing = 0;
    for (int k = 0; k < NUM_OPS; k++) begin
      for (int s = 0; s < 4; s++) begin
        total++; if (!cov_sign[k][s]) begin missing++; $display("  hole: op %0d sign combo %0d", k, s); end
      end
      if (zero_reachable(ops[k])) begin
        total++; if (!cov_zero[k])  begin missing++; $display("  hole: op %0d result zero", k);    end
      end
      total++; if (!cov_nonzero[k]) begin missing++; $display("  hole: op %0d result nonzero", k); end
      if (msb_reachable(ops[k])) begin
        total++; if (!cov_msb[k])   begin missing++; $display("  hole: op %0d result[31]=1", k);  end
      end
    end
    for (int f = 0; f < 5; f++) begin
      total++; if (!cov_flags[f]) begin missing++; $display("  hole: flag combo %0d", f); end
    end
    for (int t = 0; t < NUM_SHIFTS; t++)
      for (int s = 0; s < 32; s++) begin
        total++; if (!cov_shamt[t][s]) begin missing++; $display("  hole: shift type %0d amount %0d", t, s); end
      end
    for (int c = 0; c < 3; c++)
      for (int v = 0; v <= 32; v++) begin
        total++; if (!cov_count[c][v]) begin missing++; $display("  hole: count op %0d value %0d", c, v); end
      end
    for (int n = 0; n < 3; n++) begin
      total++; if (!cov_shadd_lost[n])  begin missing++; $display("  hole: sh%0dadd bit shifted out", n + 1); end
      total++; if (!cov_shadd_carry[n]) begin missing++; $display("  hole: sh%0dadd carry out", n + 1); end
    end
    for (int n = 0; n < 4; n++)
      for (int s = 0; s < 2; s++) begin
        total++; if (!cov_minmax[n][s]) begin missing++; $display("  hole: min/max op %0d choice %0d", n, s); end
      end
    for (int n = 0; n < 2; n++)
      for (int s = 0; s < 2; s++) begin
        total++; if (!cov_czero[n][s]) begin missing++; $display("  hole: czero op %0d condition %0d", n, s); end
      end
    for (int i = 0; i < 32; i++) begin
      total++; if (!cov_bit0[i]) begin missing++; $display("  hole: result bit %0d never 0", i); end
      total++; if (!cov_bit1[i]) begin missing++; $display("  hole: result bit %0d never 1", i); end
    end
    total++; if (!cov_add_ovf)    begin missing++; $display("  hole: ADD signed overflow");  end
    total++; if (!cov_add_carry)  begin missing++; $display("  hole: ADD carry out");        end
    total++; if (!cov_sub_ovf)    begin missing++; $display("  hole: SUB signed overflow");  end
    total++; if (!cov_sub_borrow) begin missing++; $display("  hole: SUB borrow");           end
    total++; if (!cov_undef)      begin missing++; $display("  hole: undefined op code");    end
    $display("coverage: %0d/%0d bins hit", total - missing, total);
    return missing;
  endfunction

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
    int          seed;
    int          holes;
    logic [31:0] r1, r2, junk;
    alu_op_e     co;
    seed = 32'h005E_EDA1;
    init_tables();

    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_alu.vcd");
      $dumpvars(0, tb_px_alu);
    end

    // 1. Corner-value pairs for every operation
    for (int k = 0; k < NUM_OPS; k++)
      for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++)
          check(ops[k], corners[i], corners[j]);

    // 2. Every shift, rotate and bit-index amount, with junk in the upper bits of b
    for (int s = 0; s < 32; s++)
      for (int i = 0; i < 16; i++)
        for (int t = 0; t < NUM_SHIFTS; t++) begin
          junk = (t % 3 == 0) ? 32'hFFFF_FFE0 : (t % 3 == 1) ? 32'hA5A5_A5A0 : 32'h8000_0000;
          check(shops[t], corners[i], (junk & 32'hFFFF_FFE0) | s);
        end

    // 3. Counts: zero, all ones, single bits, single zeros, low and high masks
    for (int c = 0; c < 3; c++) begin
      co = (c == 0) ? ALU_CLZ : (c == 1) ? ALU_CTZ : ALU_CPOP;
      check(co, 32'd0, 32'd0);
      check(co, 32'hFFFF_FFFF, 32'd0);
      for (int i = 0; i < 32; i++) begin
        check(co, 32'd1 << i, $random(seed));
        check(co, ~(32'd1 << i), $random(seed));
        check(co, (32'd1 << i) - 32'd1, 32'd0);
        check(co, 32'hFFFF_FFFF << i, 32'd0);
        r1 = $random(seed);
        check(co, (32'd1 << i) | (r1 & ((32'd1 << i) - 32'd1)), 32'd0);    // highest set bit i
        r1 = $random(seed);
        check(co, (32'd1 << i) | (r1 & ((32'hFFFF_FFFF << i) << 1)), 32'd0); // lowest set bit i
      end
    end

    // 4. Random operands, with b = 0 (Zicond, index 0) and b = a mixed in
    for (int n = 0; n < NUM_RANDOM; n++) begin
      r1 = $random(seed);
      r2 = $random(seed);
      if (n % 7 == 3) r2 = 32'd0;
      if (n % 11 == 5) r2 = r1;
      check(ops[n % NUM_OPS], r1, r2);
    end

    // 5. Undefined op codes
    for (int u = NUM_OPS; u < 64; u++)
      check(alu_op_e'(u), 32'hDEAD_BEEF, 32'h1234_5678);

    holes = report_coverage();

    if (errors == 0 && holes == 0)
      $display("PASS tb_px_alu (%0d checks, full functional coverage)", checks);
    else
      $display("FAIL tb_px_alu (%0d errors / %0d checks, %0d coverage holes)", errors, checks, holes);
    $finish;
  end

endmodule
