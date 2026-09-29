// tb_px_regfile: self-checking unit test for px_regfile (IMPLEMENTATION_CONTRACTS.md § 2.1).
//
// Every cycle, all three read ports are compared against a reference model just before
// the clock edge (so write-through is checked), then the model is updated at the edge.
// Directed tests additionally compare against explicit constants, so a mistake shared by
// the RTL and the model's priority logic is still caught.
//
//   T1 reset: outputs 0 during reset, reset dominates a write, both banks cleared
//   T2 fill both banks through both ports, read every register on every port
//   T3 x0 writes ignored (both ports, both banks), including write-through
//   T4 same-address collision: port 0 wins in write-through and in storage
//   T5 write-through from each write port to all three read ports
//   T6 bank switch in the same cycle as a write; bank isolation
//   T7 asynchronous reset between clock edges
//   T8 constrained random traffic (collisions, bank switches, occasional reset)
// Functional coverage bins must all be hit, otherwise the test fails.
//
// Run: scripts/run_unit.sh tb_px_regfile [+vcd]

`timescale 1ns/1ps

module tb_px_regfile;

  localparam int NUM_RANDOM   = 20000;
  localparam int CYCLE_LIMIT  = 100000;

  logic        clk = 1'b0;
  logic        rst_n;
  logic        bank;
  logic [4:0]  ra, rb, rc;
  logic [31:0] da, db, dc;
  logic        we0, we1;
  logic [4:0]  wa0, wa1;
  logic [31:0] wd0, wd1;

  px_regfile dut (
    .clk_i    (clk),
    .rst_ni   (rst_n),
    .bank_i   (bank),
    .raddr_a_i(ra), .raddr_b_i(rb), .raddr_c_i(rc),
    .rdata_a_o(da), .rdata_b_o(db), .rdata_c_o(dc),
    .we0_i    (we0), .waddr0_i(wa0), .wdata0_i(wd0),
    .we1_i    (we1), .waddr1_i(wa1), .wdata1_i(wd1)
  );

  always #5 clk = ~clk;

  int checks = 0;
  int errors = 0;
  int cycles = 0;

  always @(posedge clk) begin
    cycles++;
    if (cycles > CYCLE_LIMIT) begin
      $display("FAIL tb_px_regfile (TIMEOUT after %0d cycles)", cycles);
      $finish;
    end
  end

  // ---------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------
  logic [31:0] m [64];   // index {bank, addr}; entries 0 and 32 stay 0

  task automatic model_clear();
    for (int i = 0; i < 64; i++) m[i] = 32'd0;
  endtask

  function automatic logic [31:0] model_read(input logic [4:0] addr);
    if (!rst_n)                        return 32'd0;
    if (addr == 5'd0)                  return 32'd0;
    if (we0 && wa0 == addr)            return wd0;
    if (we1 && wa1 == addr)            return wd1;
    return m[{bank, addr}];
  endfunction

  // Model update at the rising edge (inputs are stable: they change on the falling edge).
  task automatic model_edge();
    if (rst_n) begin
      if (we0 && wa0 != 5'd0)                              m[{bank, wa0}] = wd0;
      if (we1 && wa1 != 5'd0 && !(we0 && wa0 == wa1))      m[{bank, wa1}] = wd1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Functional coverage
  // ---------------------------------------------------------------------------
  bit cov_wr     [2][2][32];  // [bank][write port][reg] with a real (nonzero) write
  bit cov_rd     [2][3][32];  // [bank][read port][reg] read while not in reset
  bit cov_wt     [3][2];      // [read port][write port] write-through observed
  bit cov_x0_wr  [2][2];      // [bank][write port] attempted x0 write
  bit cov_collide, cov_reset_write, cov_bank_switch_write;

  logic prev_bank = 1'b0;

  task automatic sample_coverage();
    logic [4:0] rds [3];
    rds[0] = ra; rds[1] = rb; rds[2] = rc;
    if (!rst_n) begin
      if (we0 || we1) cov_reset_write = 1'b1;
    end else begin
      if (we0 && wa0 != 0) cov_wr[bank][0][wa0] = 1'b1;
      if (we1 && wa1 != 0) cov_wr[bank][1][wa1] = 1'b1;
      if (we0 && wa0 == 0) cov_x0_wr[bank][0] = 1'b1;
      if (we1 && wa1 == 0) cov_x0_wr[bank][1] = 1'b1;
      if (we0 && we1 && wa0 == wa1 && wa0 != 0) cov_collide = 1'b1;
      if (bank != prev_bank && (we0 || we1)) cov_bank_switch_write = 1'b1;
      for (int p = 0; p < 3; p++) begin
        cov_rd[bank][p][rds[p]] = 1'b1;
        if (rds[p] != 0 && we0 && wa0 == rds[p])                          cov_wt[p][0] = 1'b1;
        if (rds[p] != 0 && we1 && wa1 == rds[p] && !(we0 && wa0 == rds[p])) cov_wt[p][1] = 1'b1;
      end
    end
    prev_bank = bank;
  endtask

  function automatic int report_coverage();
    int total, missing;
    total = 0; missing = 0;
    for (int b = 0; b < 2; b++) begin
      for (int p = 0; p < 2; p++) begin
        for (int r = 1; r < 32; r++) begin
          total++;
          if (!cov_wr[b][p][r]) begin missing++; $display("  hole: bank %0d write port %0d x%0d", b, p, r); end
        end
        total++;
        if (!cov_x0_wr[b][p]) begin missing++; $display("  hole: bank %0d write port %0d x0 write", b, p); end
      end
      for (int p = 0; p < 3; p++)
        for (int r = 0; r < 32; r++) begin
          total++;
          if (!cov_rd[b][p][r]) begin missing++; $display("  hole: bank %0d read port %0d x%0d", b, p, r); end
        end
    end
    for (int p = 0; p < 3; p++)
      for (int w = 0; w < 2; w++) begin
        total++;
        if (!cov_wt[p][w]) begin missing++; $display("  hole: write-through read port %0d from write port %0d", p, w); end
      end
    total++; if (!cov_collide)           begin missing++; $display("  hole: same-address collision"); end
    total++; if (!cov_reset_write)       begin missing++; $display("  hole: write during reset");     end
    total++; if (!cov_bank_switch_write) begin missing++; $display("  hole: bank switch with write"); end
    $display("coverage: %0d/%0d bins hit", total - missing, total);
    return missing;
  endfunction

  // ---------------------------------------------------------------------------
  // Checking helpers
  // ---------------------------------------------------------------------------
  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("ERROR t=%0t %s", $time, msg);
  endtask

  // Compare all read ports with the model (inputs settled, before the edge).
  task automatic check_model();
    logic [31:0] ea, eb, ec;
    #1;
    ea = model_read(ra); eb = model_read(rb); ec = model_read(rc);
    checks++;
    if (da !== ea || db !== eb || dc !== ec)
      fail($sformatf("model mismatch bank=%0d ra=%0d rb=%0d rc=%0d : %08h %08h %08h exp %08h %08h %08h",
                     bank, ra, rb, rc, da, db, dc, ea, eb, ec));
  endtask

  // Compare one read port with an explicit constant.
  task automatic expect_port(input int p, input logic [31:0] exp, input string what);
    logic [31:0] got;
    #1;
    got = (p == 0) ? da : (p == 1) ? db : dc;
    checks++;
    if (got !== exp) fail($sformatf("%s: port %0d = %08h, expected %08h", what, p, got, exp));
  endtask

  // One clock cycle: check, sample coverage, clock edge (model follows), back to the falling edge.
  task automatic step();
    check_model();
    sample_coverage();
    @(posedge clk);
    model_edge();
    @(negedge clk);
  endtask

  task automatic idle_inputs();
    we0 = 1'b0; we1 = 1'b0; wa0 = 5'd0; wa1 = 5'd0; wd0 = 32'd0; wd1 = 32'd0;
    ra = 5'd0; rb = 5'd0; rc = 5'd0;
  endtask

  function automatic logic [31:0] pattern(input int b, input int r);
    return {8'hB0 + b[7:0], 8'h5A, 8'(r), 8'(~r)};
  endfunction

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
    int seed;
    int holes;
    seed = 32'h0000_2E6F;

    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/tb_px_regfile.vcd");
      $dumpvars(0, tb_px_regfile);
    end

    model_clear();
    idle_inputs();
    bank  = 1'b0;
    rst_n = 1'b0;
    @(negedge clk);

    // ---------------- T1: reset ----------------
    // Outputs are 0 in reset for every address, even with a matching write (no write-through).
    we0 = 1'b1; wa0 = 5'd7; wd0 = 32'hDEAD_0007;
    we1 = 1'b1; wa1 = 5'd8; wd1 = 32'hDEAD_0008;
    for (int r = 0; r < 32; r++) begin
      ra = 5'(r); rb = 5'd7; rc = 5'd8;
      expect_port(0, 32'd0, "T1 read in reset");
      expect_port(1, 32'd0, "T1 write-through blocked in reset (port 0 addr)");
      expect_port(2, 32'd0, "T1 write-through blocked in reset (port 1 addr)");
    end
    step();                                   // clock edge in reset with writes enabled
    bank = 1'b1; step();
    idle_inputs();
    rst_n = 1'b1;
    @(negedge clk);
    for (int b = 0; b < 2; b++) begin
      bank = 1'(b);
      for (int r = 0; r < 32; r++) begin
        ra = 5'(r); rb = 5'(r); rc = 5'(r);
        expect_port(0, 32'd0, "T1 bank cleared after reset");
        expect_port(1, 32'd0, "T1 bank cleared after reset");
        expect_port(2, 32'd0, "T1 bank cleared after reset");
      end
    end

    // ---------------- T2: fill both banks, read everything ----------------
    for (int r = 1; r < 32; r++) begin       // bank 0 via port 0, bank 1 via port 1
      idle_inputs();
      bank = 1'b0; we0 = 1'b1; wa0 = 5'(r); wd0 = pattern(0, r);
      step();
      idle_inputs();
      bank = 1'b1; we1 = 1'b1; wa1 = 5'(r); wd1 = pattern(1, r);
      step();
    end
    for (int r = 1; r < 32; r++) begin       // and the other way round, same values
      idle_inputs();
      bank = 1'b0; we1 = 1'b1; wa1 = 5'(r); wd1 = pattern(0, r);
      step();
      idle_inputs();
      bank = 1'b1; we0 = 1'b1; wa0 = 5'(r); wd0 = pattern(1, r);
      step();
    end
    idle_inputs();
    for (int b = 0; b < 2; b++) begin
      bank = 1'(b);
      for (int r = 0; r < 32; r++) begin
        ra = 5'(r); rb = 5'((31 - r)); rc = 5'((r + 7) % 32);
        expect_port(0, r == 0 ? 32'd0 : pattern(b, r), "T2 readback port a");
        expect_port(1, (31 - r) == 0 ? 32'd0 : pattern(b, 31 - r), "T2 readback port b");
        expect_port(2, ((r + 7) % 32) == 0 ? 32'd0 : pattern(b, (r + 7) % 32), "T2 readback port c");
        step();
      end
    end

    // ---------------- T3: x0 writes ignored ----------------
    for (int b = 0; b < 2; b++) begin
      idle_inputs();
      bank = 1'(b);
      we0 = 1'b1; wa0 = 5'd0; wd0 = 32'hFFFF_FFFF;
      we1 = 1'b1; wa1 = 5'd0; wd1 = 32'hAAAA_AAAA;
      ra = 5'd0; rb = 5'd0; rc = 5'd0;
      expect_port(0, 32'd0, "T3 x0 write-through");
      expect_port(1, 32'd0, "T3 x0 write-through");
      expect_port(2, 32'd0, "T3 x0 write-through");
      step();
      idle_inputs();
      expect_port(0, 32'd0, "T3 x0 after write");
    end

    // ---------------- T4: same-address collision ----------------
    idle_inputs();
    bank = 1'b0;
    we0 = 1'b1; wa0 = 5'd9; wd0 = 32'h0000_AAAA;
    we1 = 1'b1; wa1 = 5'd9; wd1 = 32'h0000_5555;
    ra = 5'd9; rb = 5'd9; rc = 5'd10;
    expect_port(0, 32'h0000_AAAA, "T4 collision write-through, port 0 wins");
    expect_port(1, 32'h0000_AAAA, "T4 collision write-through, port 0 wins");
    expect_port(2, pattern(0, 10), "T4 unrelated register");
    step();
    idle_inputs();
    ra = 5'd9;
    expect_port(0, 32'h0000_AAAA, "T4 collision stored, port 0 wins");
    bank = 1'b1;
    expect_port(0, pattern(1, 9), "T4 other bank untouched");

    // ---------------- T5: write-through from each write port ----------------
    idle_inputs();
    bank = 1'b0;
    we1 = 1'b1; wa1 = 5'd12; wd1 = 32'h1234_5678;
    ra = 5'd12; rb = 5'd12; rc = 5'd12;
    expect_port(0, 32'h1234_5678, "T5 write-through port 1 -> a");
    expect_port(1, 32'h1234_5678, "T5 write-through port 1 -> b");
    expect_port(2, 32'h1234_5678, "T5 write-through port 1 -> c");
    we0 = 1'b1; wa0 = 5'd13; wd0 = 32'h8765_4321;
    rb = 5'd13;
    expect_port(0, 32'h1234_5678, "T5 two writes: port 1 target");
    expect_port(1, 32'h8765_4321, "T5 two writes: port 0 target");
    step();
    idle_inputs();
    ra = 5'd12; rb = 5'd13;
    expect_port(0, 32'h1234_5678, "T5 stored from port 1");
    expect_port(1, 32'h8765_4321, "T5 stored from port 0");

    // ---------------- T6: bank switch in the same cycle as a write ----------------
    idle_inputs();
    bank = 1'b1;
    we0 = 1'b1; wa0 = 5'd3; wd0 = 32'hC0DE_0003;
    step();
    idle_inputs();
    bank = 1'b0; ra = 5'd3;
    expect_port(0, pattern(0, 3), "T6 write went to bank 1 only");
    bank = 1'b1;
    expect_port(0, 32'hC0DE_0003, "T6 bank 1 holds the write");
    // switch back to bank 0 and write in the switching cycle
    bank = 1'b0; we1 = 1'b1; wa1 = 5'd3; wd1 = 32'hC0DE_1003;
    step();
    idle_inputs();
    ra = 5'd3;
    expect_port(0, 32'hC0DE_1003, "T6 write after switch went to bank 0");
    bank = 1'b1;
    expect_port(0, 32'hC0DE_0003, "T6 bank 1 unchanged");

    // ---------------- T7: asynchronous reset between edges ----------------
    idle_inputs();
    bank = 1'b1; ra = 5'd3; rb = 5'd31; rc = 5'd1;
    #2;
    rst_n = 1'b0;                             // mid low phase, no clock edge
    model_clear();
    expect_port(0, 32'd0, "T7 output 0 immediately in async reset");
    expect_port(1, 32'd0, "T7 output 0 immediately in async reset");
    #1;
    rst_n = 1'b1;
    @(negedge clk);
    for (int b = 0; b < 2; b++) begin
      bank = 1'(b);
      for (int r = 0; r < 32; r++) begin
        ra = 5'(r);
        expect_port(0, 32'd0, "T7 banks cleared by async reset");
      end
    end

    // ---------------- T8: constrained random ----------------
    for (int n = 0; n < NUM_RANDOM; n++) begin
      logic [4:0] hot;
      hot = 5'($urandom(seed) % 4);           // small set of addresses to force collisions
      if (($urandom(seed) % 5) == 0) bank = ~bank;
      we0 = ($urandom(seed) % 3) != 0;
      we1 = ($urandom(seed) % 3) != 0;
      wa0 = (($urandom(seed) % 3) == 0) ? hot : 5'($urandom(seed));
      wa1 = (($urandom(seed) % 3) == 0) ? hot : 5'($urandom(seed));
      wd0 = $urandom(seed);
      wd1 = $urandom(seed);
      ra  = (($urandom(seed) % 3) == 0) ? wa0 : 5'($urandom(seed));
      rb  = (($urandom(seed) % 3) == 0) ? wa1 : 5'($urandom(seed));
      rc  = (($urandom(seed) % 4) == 0) ? hot : 5'($urandom(seed));
      if (($urandom(seed) % 1000) == 0) begin
        rst_n = 1'b0;                         // synchronous-looking reset pulse over one edge
        model_clear();
        step();
        rst_n = 1'b1;
      end else begin
        step();
      end
    end

    idle_inputs();
    holes = report_coverage();
    if (errors == 0 && holes == 0)
      $display("PASS tb_px_regfile (%0d checks, %0d cycles, full functional coverage)", checks, cycles);
    else
      $display("FAIL tb_px_regfile (%0d errors / %0d checks, %0d coverage holes)", errors, checks, holes);
    $finish;
  end

endmodule
