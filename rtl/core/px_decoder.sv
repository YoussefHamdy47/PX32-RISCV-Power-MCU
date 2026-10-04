// px_decoder: instruction decoder for the ID stage: RV32I, M, Zicsr, Zifencei (Phase 1) and
// Zba, Zbb, Zbs 1.0.0, Zicond 1.0 (Phase 2 step 2.1, PHASE2_ARCHITECTURE.md § 2.3, D-028).
//
// Purely combinational. Input is a 32-bit instruction; compressed instructions are
// expanded to their 32-bit form in IF before they reach this block.
//
// Output: px_pkg::decode_t. Every field is defined for every input word. Fields that
// do not apply are 0. For an illegal instruction every enable and side-effect field is
// 0 and only illegal, rs1, rs2 and rd are set, so the pipeline can trap without
// qualifying each control signal.
//
// Legality (encoding level, per the pinned unprivileged ISA 20240411)
//   - inst[1:0] must be 2'b11 (a 16-bit encoding here means the expander failed)
//   - LOAD funct3 in {LB, LH, LW, LBU, LHU}; STORE funct3 in {SB, SH, SW}
//   - BRANCH funct3 not 010/011; JALR funct3 = 000
//   - OP: funct7 0000000 (all funct3), 0100000 (SUB, SRA; ANDN, ORN, XNOR), 0000001 (M, all
//     funct3), 0010000 (SH1ADD/SH2ADD/SH3ADD: funct3 010/100/110), 0000101 (MIN/MINU/MAX/
//     MAXU: funct3 100-111), 0110000 (ROL 001, ROR 101), 0100100 (BCLR 001, BEXT 101),
//     0110100 (BINV 001), 0010100 (BSET 001), 0000111 (CZERO.EQZ 101, CZERO.NEZ 111),
//     0000100 funct3 100 with rs2 = 0 (ZEXT.H; rs2 != 0 is Zbkb PACK, not implemented)
//   - OP-IMM shifts: SLLI needs imm[11:5] = 0000000, SRLI/SRAI need 0000000/0100000
//     (imm[5] set would be a 64-bit shift amount: reserved on RV32); likewise RORI
//     (0110000), BCLRI/BEXTI (0100100), BINVI (0110100) and BSETI (0010100) need imm[5] = 0
//   - OP-IMM funct3 001 with imm[11:0] = 0x600/0x601/0x602/0x604/0x605: CLZ, CTZ, CPOP,
//     SEXT.B, SEXT.H; funct3 101 with imm[11:0] = 0x287 (ORC.B) or 0x698 (REV8, the RV32
//     encoding; 0x6B8 is RV64 REV8). Every other rs2/imm value in these spaces is illegal
//   - the RV64-only forms (.w, .uw: OP-32 and OP-IMM-32 major opcodes) are illegal
//   - MISC-MEM: funct3 000 FENCE (all fm/pred/succ/rs1/rd values: unused fields are
//     ignored for forward compatibility, and pred/succ = 0 forms are HINTs),
//     funct3 001 FENCE.I (imm/rs1/rd ignored per Zifencei); other funct3 illegal
//   - SYSTEM funct3 000: exactly ECALL, EBREAK, MRET, WFI; anything else (SRET, URET,
//     SFENCE.VMA, hypervisor instructions, nonzero reserved fields) is illegal
//   - SYSTEM funct3 100 illegal; CSR funct3 001/010/011/101/110/111 legal here
//   - every other opcode is illegal in Phase 1
// HINTs (for example ADDI/LUI/ALU ops with rd = x0) are legal and simply have rd_we = 0.
// CSR existence, privilege and writes to read-only CSRs are checked by the CSR unit,
// not here: they depend on state, not only on the encoding.
//
// Timing: one level of opcode/funct decoding plus immediate muxing; no arithmetic.

`timescale 1ns/1ps

module px_decoder (
  input  logic [31:0]     instr_i,
  output px_pkg::decode_t dec_o
);

  import px_pkg::*;

  // ---------------------------------------------------------------------------
  // Fields (taken with continuous assigns: see guide § 3.3 on part-selects)
  // ---------------------------------------------------------------------------
  logic [6:0]  opcode;
  logic [2:0]  f3;
  logic [6:0]  f7;
  logic [4:0]  rd, rs1, rs2;
  logic [1:0]  quadrant;
  logic [1:0]  f3_lo;
  logic        f3_hi;
  logic [11:0] csr_addr;
  logic [11:0] sys_imm;
  logic [11:0] imm12;        // OP-IMM imm[11:0]: selects the unary Zbb operations

  assign opcode   = instr_i[6:0];
  assign quadrant = instr_i[1:0];
  assign rd       = instr_i[11:7];
  assign f3       = instr_i[14:12];
  assign rs1      = instr_i[19:15];
  assign rs2      = instr_i[24:20];
  assign f7       = instr_i[31:25];
  assign f3_lo    = instr_i[13:12];   // funct3[1:0]: access size, CSR operation
  assign f3_hi    = instr_i[14];      // funct3[2]: unsigned load, CSR immediate form
  assign csr_addr = instr_i[31:20];
  assign sys_imm  = instr_i[31:20];
  assign imm12    = instr_i[31:20];

  // ---------------------------------------------------------------------------
  // Immediates
  // ---------------------------------------------------------------------------
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j, imm_z;

  assign imm_i = {{20{instr_i[31]}}, instr_i[31:20]};
  assign imm_s = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
  assign imm_b = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u = {instr_i[31:12], 12'd0};
  assign imm_j = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};
  assign imm_z = {27'd0, instr_i[19:15]};

  // ---------------------------------------------------------------------------
  // ALU operation for OP / OP-IMM from funct3 (+ funct7[5] for SUB/SRA/SRAI)
  // ---------------------------------------------------------------------------
  function automatic alu_op_e alu_from_f3(input logic [2:0] fn3, input logic alt);
    case (fn3)
      F3_ADD_SUB: return alt ? ALU_SUB : ALU_ADD;
      F3_SLL:     return ALU_SLL;
      F3_SLT:     return ALU_SLT;
      F3_SLTU:    return ALU_SLTU;
      F3_XOR:     return ALU_XOR;
      F3_SRL_SRA: return alt ? ALU_SRA : ALU_SRL;
      F3_OR:      return ALU_OR;
      default:    return ALU_AND;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Decode
  // ---------------------------------------------------------------------------
  decode_t d;
  logic    legal;

  always_comb begin
    d     = '0;
    legal = 1'b1;

    case (opcode)
      OPC_LUI: begin
        d.rd_we = 1'b1;
        d.op_a  = OPA_ZERO;
        d.op_b  = OPB_IMM;
        d.imm   = imm_u;
      end

      OPC_AUIPC: begin
        d.rd_we = 1'b1;
        d.op_a  = OPA_PC;
        d.op_b  = OPB_IMM;
        d.imm   = imm_u;
      end

      OPC_JAL: begin
        d.rd_we  = 1'b1;
        d.is_jal = 1'b1;
        d.op_a   = OPA_PC;
        d.op_b   = OPB_LINK;
        d.imm    = imm_j;
      end

      OPC_JALR: begin
        if (f3 != 3'b000) legal = 1'b0;
        d.rd_we    = 1'b1;
        d.is_jalr  = 1'b1;
        d.rs1_used = 1'b1;
        d.op_a     = OPA_PC;
        d.op_b     = OPB_LINK;
        d.imm      = imm_i;
      end

      OPC_BRANCH: begin
        if (f3 == 3'b010 || f3 == 3'b011) legal = 1'b0;
        d.is_branch = 1'b1;
        d.branch_f3 = f3;
        d.rs1_used  = 1'b1;
        d.rs2_used  = 1'b1;
        d.imm       = imm_b;
      end

      OPC_LOAD: begin
        case (f3)
          F3_B, F3_H, F3_W, F3_BU, F3_HU: ;
          default: legal = 1'b0;
        endcase
        d.is_load      = 1'b1;
        d.rd_we        = 1'b1;
        d.rs1_used     = 1'b1;
        d.op_b         = OPB_IMM;
        d.wb_sel       = WB_MEM;
        d.imm          = imm_i;
        d.mem_size     = (f3_lo == 2'b00) ? MEM_B : (f3_lo == 2'b01) ? MEM_H : MEM_W;
        d.mem_unsigned = f3_hi;
      end

      OPC_STORE: begin
        if (f3 != F3_B && f3 != F3_H && f3 != F3_W) legal = 1'b0;
        d.is_store = 1'b1;
        d.rs1_used = 1'b1;
        d.rs2_used = 1'b1;
        d.op_b     = OPB_IMM;
        d.imm      = imm_s;
        d.mem_size = (f3_lo == 2'b00) ? MEM_B : (f3_lo == 2'b01) ? MEM_H : MEM_W;
      end

      OPC_OP_IMM: begin
        d.rd_we    = 1'b1;
        d.rs1_used = 1'b1;
        d.op_b     = OPB_IMM;
        d.imm      = imm_i;
        if (f3 == F3_SLL) begin
          // f7 is imm[11:5]; imm[5] = 1 (RV64 shift amount) never matches
          if (f7 == F7_BASE)      d.alu_op = ALU_SLL;
          else if (f7 == F7_BCLR) d.alu_op = ALU_BCLR;      // bclri
          else if (f7 == F7_BINV) d.alu_op = ALU_BINV;      // binvi
          else if (f7 == F7_BSET) d.alu_op = ALU_BSET;      // bseti
          else if (imm12 == IMM_CLZ)   d.alu_op = ALU_CLZ;
          else if (imm12 == IMM_CTZ)   d.alu_op = ALU_CTZ;
          else if (imm12 == IMM_CPOP)  d.alu_op = ALU_CPOP;
          else if (imm12 == IMM_SEXTB) d.alu_op = ALU_SEXTB;
          else if (imm12 == IMM_SEXTH) d.alu_op = ALU_SEXTH;
          else                    legal = 1'b0;
        end else if (f3 == F3_SRL_SRA) begin
          if (f7 == F7_BASE)      d.alu_op = ALU_SRL;
          else if (f7 == F7_ALT)  d.alu_op = ALU_SRA;
          else if (f7 == F7_ROT)  d.alu_op = ALU_ROR;       // rori
          else if (f7 == F7_BCLR) d.alu_op = ALU_BEXT;      // bexti
          else if (imm12 == IMM_ORCB) d.alu_op = ALU_ORCB;
          else if (imm12 == IMM_REV8) d.alu_op = ALU_REV8;
          else                    legal = 1'b0;
        end else begin
          d.alu_op = alu_from_f3(f3, 1'b0);
        end
      end

      OPC_OP: begin
        d.rd_we    = 1'b1;
        d.rs1_used = 1'b1;
        d.rs2_used = 1'b1;
        case (f7)
          F7_MULDIV: begin
            d.muldiv_en = 1'b1;
            d.muldiv_op = f3;
            d.wb_sel    = WB_MULDIV;
          end
          F7_BASE: d.alu_op = alu_from_f3(f3, 1'b0);
          F7_ALT: begin
            case (f3)
              F3_ADD_SUB: d.alu_op = ALU_SUB;
              F3_SRL_SRA: d.alu_op = ALU_SRA;
              F3_AND:     d.alu_op = ALU_ANDN;
              F3_OR:      d.alu_op = ALU_ORN;
              F3_XOR:     d.alu_op = ALU_XNOR;
              default:    legal = 1'b0;
            endcase
          end
          F7_SHADD: begin
            case (f3)
              3'b010:  d.alu_op = ALU_SH1ADD;
              3'b100:  d.alu_op = ALU_SH2ADD;
              3'b110:  d.alu_op = ALU_SH3ADD;
              default: legal = 1'b0;
            endcase
          end
          F7_MINMAX: begin
            case (f3)
              3'b100:  d.alu_op = ALU_MIN;
              3'b101:  d.alu_op = ALU_MINU;
              3'b110:  d.alu_op = ALU_MAX;
              3'b111:  d.alu_op = ALU_MAXU;
              default: legal = 1'b0;
            endcase
          end
          F7_ROT: begin
            if (f3 == F3_SLL)          d.alu_op = ALU_ROL;
            else if (f3 == F3_SRL_SRA) d.alu_op = ALU_ROR;
            else                       legal = 1'b0;
          end
          F7_BCLR: begin
            if (f3 == F3_SLL)          d.alu_op = ALU_BCLR;
            else if (f3 == F3_SRL_SRA) d.alu_op = ALU_BEXT;
            else                       legal = 1'b0;
          end
          F7_BINV: begin
            if (f3 == F3_SLL) d.alu_op = ALU_BINV;
            else              legal = 1'b0;
          end
          F7_BSET: begin
            if (f3 == F3_SLL) d.alu_op = ALU_BSET;
            else              legal = 1'b0;
          end
          F7_CZERO: begin
            if (f3 == 3'b101)      d.alu_op = ALU_CZERO_EQZ;
            else if (f3 == 3'b111) d.alu_op = ALU_CZERO_NEZ;
            else                   legal = 1'b0;
          end
          F7_ZEXTH: begin
            // zext.h is the rs2 = x0 form; it reads rs1 only
            if (f3 == F3_XOR && rs2 == 5'd0) begin
              d.alu_op   = ALU_ZEXTH;
              d.rs2_used = 1'b0;
            end else begin
              legal = 1'b0;
            end
          end
          default: legal = 1'b0;
        endcase
      end

      OPC_MISC_MEM: begin
        if (f3 == F3_FENCE)        d.is_fence   = 1'b1;
        else if (f3 == F3_FENCE_I) d.is_fence_i = 1'b1;
        else                       legal = 1'b0;
      end

      OPC_SYSTEM: begin
        if (f3 == F3_PRIV) begin
          // Exact encodings: all other fields must be zero.
          if (rd != 5'd0 || rs1 != 5'd0)  legal = 1'b0;
          else if (sys_imm == 12'h000)    d.is_ecall  = 1'b1;
          else if (sys_imm == 12'h001)    d.is_ebreak = 1'b1;
          else if (sys_imm == 12'h302)    d.is_mret   = 1'b1;
          else if (sys_imm == 12'h105)    d.is_wfi    = 1'b1;
          else                            legal = 1'b0;
        end else if (f3 == 3'b100) begin
          legal = 1'b0;
        end else begin
          d.csr_en      = 1'b1;
          d.csr_op      = (f3_lo == 2'b01) ? CSR_RW : (f3_lo == 2'b10) ? CSR_RS : CSR_RC;
          d.csr_use_imm = f3_hi;
          d.csr_addr    = csr_addr;
          d.csr_read    = !((f3_lo == 2'b01) && (rd == 5'd0));
          d.csr_write   = !((f3_lo != 2'b01) && (rs1 == 5'd0));
          d.rs1_used    = !f3_hi;
          d.rd_we       = 1'b1;
          d.wb_sel      = WB_CSR;
          d.imm         = f3_hi ? imm_z : 32'd0;
        end
      end

      default: legal = 1'b0;
    endcase

    if (quadrant != 2'b11) legal = 1'b0;

    if (!legal) begin
      d         = '0;
      d.illegal = 1'b1;
    end

    d.rs1 = rs1;
    d.rs2 = rs2;
    d.rd  = rd;
    if (rd == 5'd0) d.rd_we = 1'b0;
  end

  assign dec_o = d;

endmodule
