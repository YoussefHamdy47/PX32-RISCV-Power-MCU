// px_alu: integer ALU for the EX stage.
//
// Implements the RV32I register/immediate ALU operations (ARCHITECTURE.md § 3, § 4.1:
// "ALU op: 1 cycle"). Purely combinational; the EX stage registers the result.
//
// Interface
//   op_i      operation (px_pkg::alu_op_e)
//   a_i, b_i  operands. Operand selection (rs1/pc, rs2/imm) is done by the ID/EX stage.
//             For shifts only b_i[4:0] is used, as required by the ISA.
//   result_o  operation result. Undefined op codes produce 32'd0.
//   eq_o      a_i == b_i            \
//   lt_o      a_i <  b_i (signed)    > always valid, independent of op_i.
//   ltu_o     a_i <  b_i (unsigned) /  Used by the branch unit (BEQ..BGEU).
//
// Structure
//   A dedicated subtractor produces SUB, SLT, SLTU and the compare flags; a separate
//   adder produces ADD. Keeping them apart means the flags never depend on op_i and
//   the ADD path (also used for AUIPC and address generation) has no add/sub mux.
//   Cost: one extra 32-bit adder.
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
//   Branch/JAL/JALR target addresses use a separate adder in the branch unit, so a branch
//   compare and its target are computed in the same EX cycle.
//
// Timing
//   Critical path: 32-bit subtractor → lt_o → SLT result mux (or → branch decision).
//   For LOAD/STORE the ADD result also drives the TCM address in the same cycle
//   (OBI request issued from EX, ARCHITECTURE.md § 5.2 / guide § 5.1).
//
// Corner cases (each covered by tb/unit/tb_px_alu.sv)
//   - ADD/SUB overflow wraps modulo 2^32
//   - SLT with operands of different sign (0x8000_0000 vs 0x7FFF_FFFF)
//   - shift by 0 and by 31; upper bits of b_i ignored for shifts
//   - SRA of negative values fills with ones
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
  // Adder and subtractor
  // ---------------------------------------------------------------------------
  logic [31:0] sum;
  logic [32:0] diff;   // bit 32 = borrow
  logic [31:0] sub_res;

  assign sum     = a_i + b_i;
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
  // Shifter
  // ---------------------------------------------------------------------------
  logic [4:0]  shamt;
  logic [31:0] sll_res;
  logic [31:0] srl_res;
  logic [31:0] sra_res;

  assign shamt   = b_i[4:0];
  assign sll_res = a_i << shamt;
  assign srl_res = a_i >> shamt;
  assign sra_res = $signed(a_i) >>> shamt;

  // ---------------------------------------------------------------------------
  // Result select
  // ---------------------------------------------------------------------------
  always_comb begin
    result_o = 32'd0;
    case (op_i)
      ALU_ADD:  result_o = sum;
      ALU_SUB:  result_o = sub_res;
      ALU_SLL:  result_o = sll_res;
      ALU_SLT:  result_o = {31'd0, lt_o};
      ALU_SLTU: result_o = {31'd0, ltu_o};
      ALU_XOR:  result_o = a_i ^ b_i;
      ALU_SRL:  result_o = srl_res;
      ALU_SRA:  result_o = sra_res;
      ALU_OR:   result_o = a_i | b_i;
      ALU_AND:  result_o = a_i & b_i;
      default:  result_o = 32'd0;
    endcase
  end

endmodule
