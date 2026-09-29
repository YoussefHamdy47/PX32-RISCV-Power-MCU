// px_decoder: instruction decoder for the ID stage (Phase 1: RV32I, M, Zicsr, Zifencei).
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
//   - OP: funct7 0000000 (all funct3), 0100000 (SUB, SRA only), 0000001 (M, all funct3)
//   - OP-IMM shifts: SLLI needs imm[11:5] = 0000000, SRLI/SRAI need 0000000/0100000
//     (imm[5] set would be a 64-bit shift amount: reserved on RV32)
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
        if (f3 == F3_SLL && f7 != F7_BASE) legal = 1'b0;
        if (f3 == F3_SRL_SRA && f7 != F7_BASE && f7 != F7_ALT) legal = 1'b0;
        d.rd_we    = 1'b1;
        d.rs1_used = 1'b1;
        d.op_b     = OPB_IMM;
        d.imm      = imm_i;
        d.alu_op   = alu_from_f3(f3, (f3 == F3_SRL_SRA) && (f7 == F7_ALT));
      end

      OPC_OP: begin
        d.rd_we    = 1'b1;
        d.rs1_used = 1'b1;
        d.rs2_used = 1'b1;
        if (f7 == F7_MULDIV) begin
          d.muldiv_en = 1'b1;
          d.muldiv_op = f3;
          d.wb_sel    = WB_MULDIV;
        end else if (f7 == F7_BASE) begin
          d.alu_op = alu_from_f3(f3, 1'b0);
        end else if (f7 == F7_ALT && (f3 == F3_ADD_SUB || f3 == F3_SRL_SRA)) begin
          d.alu_op = alu_from_f3(f3, 1'b1);
        end else begin
          legal = 1'b0;
        end
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
