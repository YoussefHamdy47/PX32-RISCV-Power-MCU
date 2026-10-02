// px_decompressor: expands RV32C (C extension 2.0) instructions to 32-bit form in IF.
//
// Purely combinational. The input is the 32-bit fetch window starting at the current
// PC. If bits [1:0] are 2'b11 the window holds a 32-bit instruction and is passed
// through unchanged; otherwise the low 16 bits are a compressed instruction and are
// expanded to the equivalent 32-bit instruction that px_decoder understands.
//
// Outputs
//   instr_o          32-bit instruction for px_decoder
//   is_compressed_o  1 when the input was a 16-bit instruction (PC advances by 2, and a
//                    JAL/JALR link value is PC + 2)
//   illegal_o        1 for a reserved or unimplemented 16-bit encoding. instr_o is then
//                    {16'd0, instr_i[15:0]}: bits [1:0] are not 2'b11, so px_decoder also
//                    flags it illegal, and the original 16 bits are kept for mtval.
//
// Encodings that are illegal on PX32
//   - reserved: C.ADDI4SPN with nzuimm = 0 (includes the all-zero word), C.ADDI16SP and
//     C.LUI with a zero immediate, C.LWSP with rd = x0, C.JR with rs1 = x0,
//     quadrant 0 funct3 100
//   - RV32 custom/reserved: C.SRLI/C.SRAI/C.SLLI with shamt[5] = 1, and the
//     C.SUBW/C.ADDW slots (quadrant 1, funct3 100, bit 12 = 1, bits 11:10 = 11)
//   - floating point loads/stores (C.FLD, C.FSD, C.FLW, C.FSW, C.FLDSP, C.FSDSP,
//     C.FLWSP, C.FSWSP): PX32 has Zfinx, not F or D
// HINT encodings are legal and expand to the corresponding 32-bit HINT (for example
// C.ADDI with rd = x0, C.LI/C.LUI/C.MV/C.ADD/C.SLLI with rd = x0, shifts by 0).
//
// Timing: field extraction and one 32-way select; no arithmetic.

`timescale 1ns/1ps

module px_decompressor (
  input  logic [31:0] instr_i,
  output logic [31:0] instr_o,
  output logic        is_compressed_o,
  output logic        illegal_o
);

  import px_pkg::*;

  // ---------------------------------------------------------------------------
  // Fields (continuous assigns: see guide § 3.3 on part-selects in always_*)
  // ---------------------------------------------------------------------------
  logic [1:0]  quad;        // [1:0]
  logic [2:0]  c_f3;        // [15:13]
  logic        b12;         // [12]
  logic [1:0]  f2_hi;       // [11:10]
  logic [1:0]  f2_lo;       // [6:5]
  logic [4:0]  rd_full;     // [11:7]  rd / rs1 in CR, CI, CSS formats
  logic [4:0]  rs2_full;    // [6:2]
  logic [4:0]  rd_p;        // x8 + [4:2]  rd' / rs2'
  logic [4:0]  rs1_p;       // x8 + [9:7]  rs1' / rd'
  logic [15:0] c_instr;

  assign quad     = instr_i[1:0];
  assign c_f3     = instr_i[15:13];
  assign b12      = instr_i[12];
  assign f2_hi    = instr_i[11:10];
  assign f2_lo    = instr_i[6:5];
  assign rd_full  = instr_i[11:7];
  assign rs2_full = instr_i[6:2];
  assign rd_p     = {2'b01, instr_i[4:2]};
  assign rs1_p    = {2'b01, instr_i[9:7]};
  assign c_instr  = instr_i[15:0];

  // ---------------------------------------------------------------------------
  // Immediates, each in the bit order of its 32-bit target field
  // ---------------------------------------------------------------------------
  logic [11:0] imm_addi4spn;  // nzuimm[9:2]
  logic [11:0] imm_lw;        // uimm[6:2]      C.LW / C.SW
  logic [11:0] imm_ci;        // imm[5:0] sign-extended: C.ADDI, C.LI, C.ANDI
  logic [5:0]  shamt;         // shamt[5:0]: C.SRLI, C.SRAI, C.SLLI
  logic [11:0] imm_addi16sp;  // nzimm[9:4] sign-extended
  logic [19:0] imm_lui;       // nzimm[17:12] sign-extended to the 20-bit U field
  logic [20:1] imm_cj;        // offset[11:1] sign-extended (bit 0 is always 0): C.J, C.JAL
  logic [12:1] imm_cb;        // offset[8:1] sign-extended (bit 0 is always 0): C.BEQZ, C.BNEZ
  logic [11:0] imm_lwsp;      // uimm[7:2]
  logic [11:0] imm_swsp;      // uimm[7:2]

  assign imm_addi4spn = {2'b00, instr_i[10:7], instr_i[12:11], instr_i[5], instr_i[6], 2'b00};
  assign imm_lw       = {5'd0, instr_i[5], instr_i[12:10], instr_i[6], 2'b00};
  assign imm_ci       = {{7{instr_i[12]}}, instr_i[6:2]};
  assign shamt        = {instr_i[12], instr_i[6:2]};
  assign imm_addi16sp = {{3{instr_i[12]}}, instr_i[4:3], instr_i[5], instr_i[2], instr_i[6], 4'd0};
  assign imm_lui      = {{15{instr_i[12]}}, instr_i[6:2]};
  assign imm_cj       = {{10{instr_i[12]}}, instr_i[8], instr_i[10:9], instr_i[6], instr_i[7],
                         instr_i[2], instr_i[11], instr_i[5:3]};
  assign imm_cb       = {{5{instr_i[12]}}, instr_i[6:5], instr_i[2], instr_i[11:10], instr_i[4:3]};
  assign imm_lwsp     = {4'd0, instr_i[3:2], instr_i[12], instr_i[6:4], 2'b00};
  assign imm_swsp     = {4'd0, instr_i[8:7], instr_i[12:9], 2'b00};

  // ---------------------------------------------------------------------------
  // 32-bit instruction builders
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] enc_i(input logic [11:0] imm, input logic [4:0] rs1,
                                        input logic [2:0] fn3, input logic [4:0] rd,
                                        input logic [6:0] op);
    return {imm, rs1, fn3, rd, op};
  endfunction

  function automatic logic [31:0] enc_r(input logic [6:0] fn7, input logic [4:0] rs2,
                                        input logic [4:0] rs1, input logic [2:0] fn3,
                                        input logic [4:0] rd, input logic [6:0] op);
    return {fn7, rs2, rs1, fn3, rd, op};
  endfunction

  // Stores, branches and jumps are built with continuous assigns: their immediates are
  // split across the word, and part-selects inside always_* trip an Icarus limitation.
  logic [31:0] w_sw, w_swsp, w_beqz, w_bnez, w_j, w_jal;

  assign w_sw   = {imm_lw[11:5], rd_p, rs1_p, F3_W, imm_lw[4:0], OPC_STORE};
  assign w_swsp = {imm_swsp[11:5], rs2_full, 5'd2, F3_W, imm_swsp[4:0], OPC_STORE};
  assign w_beqz = {imm_cb[12], imm_cb[10:5], 5'd0, rs1_p, F3_BEQ, imm_cb[4:1], imm_cb[11], OPC_BRANCH};
  assign w_bnez = {imm_cb[12], imm_cb[10:5], 5'd0, rs1_p, F3_BNE, imm_cb[4:1], imm_cb[11], OPC_BRANCH};
  assign w_j    = {imm_cj[20], imm_cj[10:1], imm_cj[11], imm_cj[19:12], 5'd0, OPC_JAL};
  assign w_jal  = {imm_cj[20], imm_cj[10:1], imm_cj[11], imm_cj[19:12], 5'd1, OPC_JAL};

  // ---------------------------------------------------------------------------
  // Expansion
  // ---------------------------------------------------------------------------
  logic [31:0] exp;
  logic        ill;

  always_comb begin
    exp = 32'd0;
    ill = 1'b0;

    case (quad)
      // ---------------- Quadrant 0 ----------------
      2'b00: begin
        case (c_f3)
          3'b000: begin                                             // C.ADDI4SPN
            exp = enc_i(imm_addi4spn, 5'd2, F3_ADD_SUB, rd_p, OPC_OP_IMM);
            if (imm_addi4spn == 12'd0) ill = 1'b1;
          end
          3'b010:  exp = enc_i(imm_lw, rs1_p, F3_W, rd_p, OPC_LOAD);   // C.LW
          3'b110:  exp = w_sw;             // C.SW
          default: ill = 1'b1;       // C.FLD, C.FLW, reserved, C.FSD, C.FSW
        endcase
      end

      // ---------------- Quadrant 1 ----------------
      2'b01: begin
        case (c_f3)
          3'b000: exp = enc_i(imm_ci, rd_full, F3_ADD_SUB, rd_full, OPC_OP_IMM);  // C.NOP, C.ADDI
          3'b001: exp = w_jal;                                      // C.JAL
          3'b010: exp = enc_i(imm_ci, 5'd0, F3_ADD_SUB, rd_full, OPC_OP_IMM);     // C.LI
          3'b011: begin
            if (rd_full == 5'd2) begin                                           // C.ADDI16SP
              exp = enc_i(imm_addi16sp, 5'd2, F3_ADD_SUB, 5'd2, OPC_OP_IMM);
              if (imm_addi16sp == 12'd0) ill = 1'b1;
            end else begin                                                       // C.LUI
              exp = {imm_lui, rd_full, OPC_LUI};
              if (imm_lui == 20'd0) ill = 1'b1;
            end
          end
          3'b100: begin
            case (f2_hi)
              2'b00: begin                                                       // C.SRLI
                exp = enc_i({6'b000000, shamt}, rs1_p, F3_SRL_SRA, rs1_p, OPC_OP_IMM);
                if (b12) ill = 1'b1;
              end
              2'b01: begin                                                       // C.SRAI
                exp = enc_i({6'b010000, shamt}, rs1_p, F3_SRL_SRA, rs1_p, OPC_OP_IMM);
                if (b12) ill = 1'b1;
              end
              2'b10: exp = enc_i(imm_ci, rs1_p, F3_AND, rs1_p, OPC_OP_IMM);       // C.ANDI
              default: begin
                if (b12) ill = 1'b1;           // C.SUBW, C.ADDW (RV64) and reserved
                else begin
                  case (f2_lo)
                    2'b00:   exp = enc_r(F7_ALT,  rd_p, rs1_p, F3_ADD_SUB, rs1_p, OPC_OP);  // C.SUB
                    2'b01:   exp = enc_r(F7_BASE, rd_p, rs1_p, F3_XOR,     rs1_p, OPC_OP);  // C.XOR
                    2'b10:   exp = enc_r(F7_BASE, rd_p, rs1_p, F3_OR,      rs1_p, OPC_OP);  // C.OR
                    default: exp = enc_r(F7_BASE, rd_p, rs1_p, F3_AND,     rs1_p, OPC_OP);  // C.AND
                  endcase
                end
              end
            endcase
          end
          3'b101:  exp = w_j;                                     // C.J
          3'b110:  exp = w_beqz;                            // C.BEQZ
          default: exp = w_bnez;                            // C.BNEZ
        endcase
      end

      // ---------------- Quadrant 2 ----------------
      2'b10: begin
        case (c_f3)
          3'b000: begin                                                          // C.SLLI
            exp = enc_i({6'b000000, shamt}, rd_full, F3_SLL, rd_full, OPC_OP_IMM);
            if (b12) ill = 1'b1;
          end
          3'b010: begin                                                          // C.LWSP
            exp = enc_i(imm_lwsp, 5'd2, F3_W, rd_full, OPC_LOAD);
            if (rd_full == 5'd0) ill = 1'b1;
          end
          3'b100: begin
            if (!b12) begin
              if (rs2_full == 5'd0) begin                                        // C.JR
                exp = enc_i(12'd0, rd_full, 3'b000, 5'd0, OPC_JALR);
                if (rd_full == 5'd0) ill = 1'b1;
              end else begin                                                     // C.MV
                exp = enc_r(F7_BASE, rs2_full, 5'd0, F3_ADD_SUB, rd_full, OPC_OP);
              end
            end else begin
              if (rs2_full == 5'd0 && rd_full == 5'd0)                           // C.EBREAK
                exp = 32'h0010_0073;
              else if (rs2_full == 5'd0)                                         // C.JALR
                exp = enc_i(12'd0, rd_full, 3'b000, 5'd1, OPC_JALR);
              else                                                               // C.ADD
                exp = enc_r(F7_BASE, rs2_full, rd_full, F3_ADD_SUB, rd_full, OPC_OP);
            end
          end
          3'b110:  exp = w_swsp;                  // C.SWSP
          default: ill = 1'b1;       // C.FLDSP, C.FLWSP, C.FSDSP, C.FSWSP
        endcase
      end

      default: ;                     // 2'b11: 32-bit instruction, passed through below
    endcase
  end

  assign is_compressed_o = (quad != 2'b11);
  assign illegal_o       = is_compressed_o && ill;
  assign instr_o         = !is_compressed_o ? instr_i :
                           ill              ? {16'd0, c_instr} : exp;

endmodule
