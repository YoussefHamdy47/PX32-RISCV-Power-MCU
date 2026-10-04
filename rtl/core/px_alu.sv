// px_alu: integer ALU for the EX stage.
//
// Implements the RV32I register/immediate ALU operations (ARCHITECTURE.md § 3, § 4.1:
// "ALU op: 1 cycle") and, since Phase 2 step 2.1, Zba, Zbb, Zbs 1.0.0 and Zicond 1.0
// (unprivileged ISA 20240411; PHASE2_ARCHITECTURE.md § 2.2; DECISIONS.md D-028).
// Purely combinational; the EX stage registers the result.
//
// Interface
//   op_i      operation (px_pkg::alu_op_e, 6 bits)
//   a_i, b_i  operands. Operand selection (rs1/pc, rs2/imm) is done by the ID/EX stage.
//             For shifts, rotates and Zbs bit indices only b_i[4:0] is used.
//   result_o  operation result. Undefined op codes (36..63) produce 32'd0.
//   eq_o      a_i == b_i            \
//   lt_o      a_i <  b_i (signed)    > always valid, independent of op_i.
//   ltu_o     a_i <  b_i (unsigned) /  Used by the branch unit (BEQ..BGEU).
//
// Structure
//   A dedicated subtractor produces SUB, SLT, SLTU, MIN/MAX and the compare flags; a
//   separate adder produces ADD and SH1ADD/SH2ADD/SH3ADD. Keeping them apart means the
//   flags never depend on op_i and the adder path has no add/sub mux.
//   D-028: ADD..SH3ADD are op codes 0..3, so operand a is pre-shifted by op_i[1:0] in front
//   of the adder for every operation (a 4:1 mux whose select comes straight from the
//   op-code flop, no decode), and the adder output is selected last: result_o =
//   (op_i[5:2] == 0) ? sum : <every other operation>. The adder result is therefore never
//   used by another operation, whatever op_i[1:0] is.
//   CLZ: five-step binary search; CTZ is CLZ of the bit-reversed operand (one counter).
//   CPOP: lane-separated adder tree. ROL/ROR: 64-bit shifts of {a, a}. Zbs: one-hot mask
//   1 << b[4:0]; BEXT is bit 0 of the right shifter. Zicond: zero detect of b.
//
// Usage by instruction (contract for px_decoder / EX-stage operand muxes)
//   ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND   op per funct3/funct7, a = rs1, b = rs2
//   ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/...     same op,                a = rs1, b = imm
//   LUI                                        ALU_ADD,                a = 0,   b = imm_u
//   AUIPC                                      ALU_ADD,                a = pc,  b = imm_u
//   LOAD/STORE address                         ALU_ADD,                a = rs1, b = imm
//   JAL/JALR link value (rd)                   ALU_ADD,                a = pc,  b = 4 (2 for RVC)
//   BEQ/BNE/BLT/BGE/BLTU/BGEU                  flags only,             a = rs1, b = rs2
//     BEQ = eq_o, BNE = !eq_o, BLT = lt_o, BGE = !lt_o, BLTU = ltu_o, BGEU = !ltu_o
//   SH1ADD/SH2ADD/SH3ADD                       rd = rs2 + (rs1 << n),  a = rs1, b = rs2
//   ANDN/ORN/XNOR, MIN/MINU/MAX/MAXU, ROL/ROR, BCLR/BEXT/BINV/BSET, CZERO.EQZ/NEZ
//                                              a = rs1, b = rs2
//   RORI, BCLRI/BEXTI/BINVI/BSETI              ALU_ROR / ALU_Bxxx,     a = rs1, b = imm
//   CLZ/CTZ/CPOP/SEXT.B/SEXT.H/ORC.B/REV8/ZEXT.H   unary,              a = rs1 (b ignored)
//   Branch/JAL/JALR target addresses use a separate adder in the branch unit, so a branch
//   compare and its target are computed in the same EX cycle.
//
// Timing
//   Critical path: op-code flop -> operand pre-shift (Zba) -> 32-bit adder -> final 2:1 mux
//   (generic depth: D-028). The 32-way mux of the other results is parallel to the adder.
//
// Corner cases (each covered by tb/unit/tb_px_alu.sv)
//   - ADD/SUB/SHnADD overflow wraps modulo 2^32
//   - SLT/MIN/MAX with operands of different sign (0x8000_0000 vs 0x7FFF_FFFF)
//   - shift, rotate and bit index by 0 and by 31; upper bits of b_i ignored
//   - SRA of negative values fills with ones
//   - CLZ/CTZ of 0 is 32; CPOP of all ones is 32
//   - CZERO with a zero and a nonzero condition
//   - undefined op codes return 0

`timescale 1ns/1ps

module px_alu (
  input  px_pkg::alu_op_e op_i,
  input  logic [31:0]     a_i,
  input  logic [31:0]     b_i,
  output logic [31:0]     result_o,
  output logic            eq_o,
  output logic            lt_o,
  output logic            ltu_o
);

  import px_pkg::*;

  // ---------------------------------------------------------------------------
  // Adder (with the Zba pre-shift) and subtractor
  // ---------------------------------------------------------------------------
  logic [1:0]  shadd;
  logic [31:0] a_sh;
  logic [31:0] sum;
  logic [32:0] diff;   // bit 32 = borrow
  logic [31:0] sub_res;

  assign shadd = op_i[1:0];       // 0 for ADD, n for SHnADD (D-028)
  assign a_sh  = (shadd == 2'd0) ? a_i :
                 (shadd == 2'd1) ? {a_i[30:0], 1'b0} :
                 (shadd == 2'd2) ? {a_i[29:0], 2'b00} : {a_i[28:0], 3'b000};
  assign sum     = a_sh + b_i;
  assign diff    = {1'b0, a_i} - {1'b0, b_i};
  assign sub_res = diff[31:0];

  // ---------------------------------------------------------------------------
  // Compare flags
  // ---------------------------------------------------------------------------
  assign eq_o  = (a_i == b_i);
  assign ltu_o = diff[32];
  // Different signs: the negative operand is smaller. Same signs: no overflow is
  // possible, so the sign of the difference decides.
  assign lt_o  = (a_i[31] != b_i[31]) ? a_i[31] : diff[31];

  // ---------------------------------------------------------------------------
  // Shifter and rotates
  // ---------------------------------------------------------------------------
  logic [4:0]  shamt;
  logic [31:0] sll_res;
  logic [31:0] srl_res;
  logic [31:0] sra_res;
  // Only one half of each 64-bit shift is the rotate result.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] rot_l, rot_r;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] rol_res, ror_res;

  assign shamt   = b_i[4:0];
  assign sll_res = a_i << shamt;
  assign srl_res = a_i >> shamt;
  assign sra_res = $signed(a_i) >>> shamt;
  assign rot_l   = {a_i, a_i} << shamt;
  assign rot_r   = {a_i, a_i} >> shamt;
  assign rol_res = rot_l[63:32];
  assign ror_res = rot_r[31:0];

  // ---------------------------------------------------------------------------
  // Count leading/trailing zeros (shared counter) and population count
  // ---------------------------------------------------------------------------
  logic [31:0] a_rev, cz_in, cz16, cz8, cz4, cz2;
  // Only bit 31 of the last search step is used (it is 0 only for a zero operand).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] cz1;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        z16, z8, z4, z2, z1;
  logic [5:0]  cz_res;

  for (genvar i = 0; i < 32; i++) begin : g_rev
    assign a_rev[i] = a_i[31 - i];
  end
  assign cz_in = (op_i == ALU_CTZ) ? a_rev : a_i;
  // Binary search for the first set bit from the top: each step shifts the operand left
  // when its upper half is zero and records that half's width.
  assign z16  = (cz_in[31:16] == 16'd0);
  assign cz16 = z16 ? {cz_in[15:0], 16'd0} : cz_in;
  assign z8   = (cz16[31:24] == 8'd0);
  assign cz8  = z8 ? {cz16[23:0], 8'd0} : cz16;
  assign z4   = (cz8[31:28] == 4'd0);
  assign cz4  = z4 ? {cz8[27:0], 4'd0} : cz8;
  assign z2   = (cz4[31:30] == 2'd0);
  assign cz2  = z2 ? {cz4[29:0], 2'd0} : cz4;
  assign z1   = !cz2[31];
  assign cz1  = z1 ? {cz2[30:0], 1'b0} : cz2;
  // cz1[31] is clear only for a zero operand: the count is then 32.
  assign cz_res = cz1[31] ? {1'b0, z16, z8, z4, z2, z1} : 6'd32;

  logic [31:0] pc1;   // 16 x 2-bit counts
  logic [23:0] pc2;   //  8 x 3-bit counts
  logic [15:0] pc3;   //  4 x 4-bit counts
  logic [9:0]  pc4;   //  2 x 5-bit counts
  logic [5:0]  cpop_res;
  for (genvar i = 0; i < 16; i++) begin : g_pc1
    assign pc1[2*i +: 2] = {1'b0, a_i[2*i]} + {1'b0, a_i[2*i + 1]};
  end
  for (genvar i = 0; i < 8; i++) begin : g_pc2
    assign pc2[3*i +: 3] = {1'b0, pc1[4*i +: 2]} + {1'b0, pc1[4*i + 2 +: 2]};
  end
  for (genvar i = 0; i < 4; i++) begin : g_pc3
    assign pc3[4*i +: 4] = {1'b0, pc2[6*i +: 3]} + {1'b0, pc2[6*i + 3 +: 3]};
  end
  for (genvar i = 0; i < 2; i++) begin : g_pc4
    assign pc4[5*i +: 5] = {1'b0, pc3[8*i +: 4]} + {1'b0, pc3[8*i + 4 +: 4]};
  end
  assign cpop_res = {1'b0, pc4[4:0]} + {1'b0, pc4[9:5]};

  // ---------------------------------------------------------------------------
  // Byte operations, extensions, single-bit operations, conditional zero
  // ---------------------------------------------------------------------------
  logic [31:0] orcb_res, rev8_res, sextb_res, sexth_res, zexth_res;
  logic [31:0] bmask, bext_res;
  logic        b_zero;

  for (genvar k = 0; k < 4; k++) begin : g_bytes
    assign orcb_res[8*k +: 8] = (a_i[8*k +: 8] != 8'd0) ? 8'hFF : 8'h00;
    assign rev8_res[8*k +: 8] = a_i[8*(3 - k) +: 8];
  end
  assign sextb_res = {{24{a_i[7]}}, a_i[7:0]};
  assign sexth_res = {{16{a_i[15]}}, a_i[15:0]};
  assign zexth_res = {16'd0, a_i[15:0]};
  assign bmask     = 32'd1 << shamt;
  assign bext_res  = {31'd0, srl_res[0]};
  assign b_zero    = (b_i == 32'd0);

  // ---------------------------------------------------------------------------
  // Result select: every operation except the adder group, then the adder last
  // ---------------------------------------------------------------------------
  logic [31:0] other_res;
  logic        add_group;

  always_comb begin
    other_res = 32'd0;
    case (op_i)
      ALU_SUB:       other_res = sub_res;
      ALU_SLL:       other_res = sll_res;
      ALU_SLT:       other_res = {31'd0, lt_o};
      ALU_SLTU:      other_res = {31'd0, ltu_o};
      ALU_XOR:       other_res = a_i ^ b_i;
      ALU_SRL:       other_res = srl_res;
      ALU_SRA:       other_res = sra_res;
      ALU_OR:        other_res = a_i | b_i;
      ALU_AND:       other_res = a_i & b_i;
      ALU_ANDN:      other_res = a_i & ~b_i;
      ALU_ORN:       other_res = a_i | ~b_i;
      ALU_XNOR:      other_res = ~(a_i ^ b_i);
      ALU_CLZ:       other_res = {26'd0, cz_res};
      ALU_CTZ:       other_res = {26'd0, cz_res};
      ALU_CPOP:      other_res = {26'd0, cpop_res};
      ALU_MAX:       other_res = lt_o  ? b_i : a_i;
      ALU_MAXU:      other_res = ltu_o ? b_i : a_i;
      ALU_MIN:       other_res = lt_o  ? a_i : b_i;
      ALU_MINU:      other_res = ltu_o ? a_i : b_i;
      ALU_SEXTB:     other_res = sextb_res;
      ALU_SEXTH:     other_res = sexth_res;
      ALU_ZEXTH:     other_res = zexth_res;
      ALU_ROL:       other_res = rol_res;
      ALU_ROR:       other_res = ror_res;
      ALU_ORCB:      other_res = orcb_res;
      ALU_REV8:      other_res = rev8_res;
      ALU_BCLR:      other_res = a_i & ~bmask;
      ALU_BEXT:      other_res = bext_res;
      ALU_BINV:      other_res = a_i ^ bmask;
      ALU_BSET:      other_res = a_i | bmask;
      ALU_CZERO_EQZ: other_res = b_zero ? 32'd0 : a_i;
      ALU_CZERO_NEZ: other_res = b_zero ? a_i : 32'd0;
      default:       other_res = 32'd0;
    endcase
  end

  assign add_group = (op_i[5:2] == 4'd0);   // ADD, SH1ADD, SH2ADD, SH3ADD (D-028)
  assign result_o  = add_group ? sum : other_res;

endmodule
