// px_regfile: two-bank integer register file, 3 read / 2 write ports.
//
// Implements IMPLEMENTATION_CONTRACTS.md § 2.1 (D-011). Bank 0 is the normal context,
// bank 1 the level-15 fast-interrupt context. Phase 1 ties bank_i = 0 and may tie
// we1_i = 0; interrupt-driven bank switching arrives in Phase 2.
//
// Behaviour
//   - Each bank holds 31 writable 32-bit registers (x1..x31); x0 is not stored and
//     always reads 0. Writes to x0 are ignored.
//   - Writes happen on the rising clock edge, into the bank selected by bank_i at that
//     edge. Switching bank_i changes what is read immediately (no copy latency).
//   - If both write ports target the same nonzero register, port 0 wins.
//   - Reads are combinational with write-through. Priority per read port:
//       1. address 0                          -> 0
//       2. we0_i and waddr0_i matches          -> wdata0_i
//       3. we1_i and waddr1_i matches          -> wdata1_i
//       4. stored value of the selected bank
//     Write-through lets the WB stage write and the ID stage read the same register in
//     one cycle without a separate forwarding path.
//   - rst_ni is asynchronous assert (release synchronised outside). While it is low,
//     both banks are cleared, writes are ignored and all read ports output 0 (no
//     write-through).
//
// Latency: reads 0 cycles (combinational), writes visible in storage after 1 edge.
// Timing note: the write-through path (wdata → rdata) is combinational. In the core it
// sits between WB and the ID-stage operand muxes.
//
// Corner cases (each covered by tb/unit/tb_px_regfile.sv)
//   - reset clears both banks; reset dominates a simultaneous write; outputs 0 in reset
//   - x0 writes on either port, in either bank, are ignored
//   - same-address write on both ports: port 0 wins in storage and in write-through
//   - write-through on all three read ports from each write port
//   - bank isolation; bank switch in the same cycle as a write

`timescale 1ns/1ps

module px_regfile (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        bank_i,

  input  logic [4:0]  raddr_a_i,
  input  logic [4:0]  raddr_b_i,
  input  logic [4:0]  raddr_c_i,
  output logic [31:0] rdata_a_o,
  output logic [31:0] rdata_b_o,
  output logic [31:0] rdata_c_o,

  input  logic        we0_i,
  input  logic [4:0]  waddr0_i,
  input  logic [31:0] wdata0_i,
  input  logic        we1_i,
  input  logic [4:0]  waddr1_i,
  input  logic [31:0] wdata1_i
);

  // ---------------------------------------------------------------------------
  // Storage: index {bank, addr}. Entries 0 and 32 (x0 of each bank) are constant 0
  // and have no flops.
  // ---------------------------------------------------------------------------
  logic [63:0][31:0] rf;

  assign rf[0]  = 32'd0;
  assign rf[32] = 32'd0;

  for (genvar b = 0; b < 2; b++) begin : g_bank
    for (genvar r = 1; r < 32; r++) begin : g_reg
      logic [31:0] q;
      logic        sel0, sel1;

      assign sel0 = (bank_i == b[0]) && we0_i && (waddr0_i == r[4:0]);
      assign sel1 = (bank_i == b[0]) && we1_i && (waddr1_i == r[4:0]);

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)   q <= 32'd0;
        else if (sel0) q <= wdata0_i;   // port 0 wins a same-address collision
        else if (sel1) q <= wdata1_i;
      end

      assign rf[b * 32 + r] = q;
    end
  end

  // ---------------------------------------------------------------------------
  // Read ports with write-through
  // ---------------------------------------------------------------------------
  // Every input is an explicit argument: a continuous assignment is re-evaluated only
  // when one of its operands changes, so a function that read module signals as
  // globals would leave the read port stale in simulation.
  function automatic logic [31:0] read_port(
    input logic [4:0]  addr,
    input logic [31:0] stored,
    input logic        we0,
    input logic [4:0]  wa0,
    input logic [31:0] wd0,
    input logic        we1,
    input logic [4:0]  wa1,
    input logic [31:0] wd1
  );
    if (addr == 5'd0)              return 32'd0;
    else if (we0 && wa0 == addr)   return wd0;
    else if (we1 && wa1 == addr)   return wd1;
    else                           return stored;
  endfunction

  logic [31:0] stored_a, stored_b, stored_c;

  assign stored_a = rf[{bank_i, raddr_a_i}];
  assign stored_b = rf[{bank_i, raddr_b_i}];
  assign stored_c = rf[{bank_i, raddr_c_i}];

  assign rdata_a_o = rst_ni ? read_port(raddr_a_i, stored_a, we0_i, waddr0_i, wdata0_i,
                                        we1_i, waddr1_i, wdata1_i) : 32'd0;
  assign rdata_b_o = rst_ni ? read_port(raddr_b_i, stored_b, we0_i, waddr0_i, wdata0_i,
                                        we1_i, waddr1_i, wdata1_i) : 32'd0;
  assign rdata_c_o = rst_ni ? read_port(raddr_c_i, stored_c, we0_i, waddr0_i, wdata0_i,
                                        we1_i, waddr1_i, wdata1_i) : 32'd0;

endmodule
