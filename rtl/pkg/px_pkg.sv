// px_pkg: shared constants and types for the PX32 core.
//
// Opcodes, funct fields and CSR addresses follow the RISC-V Unprivileged ISA
// (20191213) and Privileged ISA (20211203) specifications.
// Implements ARCHITECTURE.md § 3 (encoding constants only).

`timescale 1ns/1ps

package px_pkg;

  // ---------------------------------------------------------------------------
  // Base opcodes (inst[6:0])
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPC_LOAD     = 7'b0000011;
  localparam logic [6:0] OPC_MISC_MEM = 7'b0001111;  // FENCE, FENCE.I
  localparam logic [6:0] OPC_OP_IMM   = 7'b0010011;
  localparam logic [6:0] OPC_AUIPC    = 7'b0010111;
  localparam logic [6:0] OPC_STORE    = 7'b0100011;
  localparam logic [6:0] OPC_OP       = 7'b0110011;
  localparam logic [6:0] OPC_LUI      = 7'b0110111;
  localparam logic [6:0] OPC_BRANCH   = 7'b1100011;
  localparam logic [6:0] OPC_JALR     = 7'b1100111;
  localparam logic [6:0] OPC_JAL      = 7'b1101111;
  localparam logic [6:0] OPC_SYSTEM   = 7'b1110011;

  // ---------------------------------------------------------------------------
  // funct3
  // ---------------------------------------------------------------------------
  // OP / OP-IMM
  localparam logic [2:0] F3_ADD_SUB = 3'b000;
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // BRANCH
  localparam logic [2:0] F3_BEQ  = 3'b000;
  localparam logic [2:0] F3_BNE  = 3'b001;
  localparam logic [2:0] F3_BLT  = 3'b100;
  localparam logic [2:0] F3_BGE  = 3'b101;
  localparam logic [2:0] F3_BLTU = 3'b110;
  localparam logic [2:0] F3_BGEU = 3'b111;

  // LOAD / STORE
  localparam logic [2:0] F3_B  = 3'b000;
  localparam logic [2:0] F3_H  = 3'b001;
  localparam logic [2:0] F3_W  = 3'b010;
  localparam logic [2:0] F3_BU = 3'b100;
  localparam logic [2:0] F3_HU = 3'b101;

  // M extension (OP with funct7 = 0000001)
  localparam logic [2:0] F3_MUL    = 3'b000;
  localparam logic [2:0] F3_MULH   = 3'b001;
  localparam logic [2:0] F3_MULHSU = 3'b010;
  localparam logic [2:0] F3_MULHU  = 3'b011;
  localparam logic [2:0] F3_DIV    = 3'b100;
  localparam logic [2:0] F3_DIVU   = 3'b101;
  localparam logic [2:0] F3_REM    = 3'b110;
  localparam logic [2:0] F3_REMU   = 3'b111;

  // SYSTEM
  localparam logic [2:0] F3_PRIV   = 3'b000;  // ECALL, EBREAK, MRET, WFI
  localparam logic [2:0] F3_CSRRW  = 3'b001;
  localparam logic [2:0] F3_CSRRS  = 3'b010;
  localparam logic [2:0] F3_CSRRC  = 3'b011;
  localparam logic [2:0] F3_CSRRWI = 3'b101;
  localparam logic [2:0] F3_CSRRSI = 3'b110;
  localparam logic [2:0] F3_CSRRCI = 3'b111;

  // MISC-MEM
  localparam logic [2:0] F3_FENCE   = 3'b000;
  localparam logic [2:0] F3_FENCE_I = 3'b001;

  // ---------------------------------------------------------------------------
  // funct7
  // ---------------------------------------------------------------------------
  localparam logic [6:0] F7_BASE   = 7'b0000000;
  localparam logic [6:0] F7_ALT    = 7'b0100000;  // SUB, SRA, SRAI
  localparam logic [6:0] F7_MULDIV = 7'b0000001;

  // ---------------------------------------------------------------------------
  // CSR addresses (machine mode subset, ARCHITECTURE.md § 4.3 adds CLIC CSRs later)
  // ---------------------------------------------------------------------------
  localparam logic [11:0] CSR_FFLAGS    = 12'h001;
  localparam logic [11:0] CSR_FRM       = 12'h002;
  localparam logic [11:0] CSR_FCSR      = 12'h003;
  localparam logic [11:0] CSR_MSTATUS   = 12'h300;
  localparam logic [11:0] CSR_MISA      = 12'h301;
  localparam logic [11:0] CSR_MIE       = 12'h304;
  localparam logic [11:0] CSR_MTVEC     = 12'h305;
  localparam logic [11:0] CSR_MSTATUSH  = 12'h310;
  localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [11:0] CSR_MEPC      = 12'h341;
  localparam logic [11:0] CSR_MCAUSE    = 12'h342;
  localparam logic [11:0] CSR_MTVAL     = 12'h343;
  localparam logic [11:0] CSR_MIP       = 12'h344;
  localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID   = 12'hF12;
  localparam logic [11:0] CSR_MIMPID    = 12'hF13;
  localparam logic [11:0] CSR_MHARTID   = 12'hF14;

  // ---------------------------------------------------------------------------
  // ALU operations (px_alu)
  // 5 bits wide so Zba/Zbb/Zbs/Zicond/Xcvalu operations can be added in
  // Phase 2 without changing port widths.
  // ---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    ALU_ADD  = 5'd0,
    ALU_SUB  = 5'd1,
    ALU_SLL  = 5'd2,
    ALU_SLT  = 5'd3,
    ALU_SLTU = 5'd4,
    ALU_XOR  = 5'd5,
    ALU_SRL  = 5'd6,
    ALU_SRA  = 5'd7,
    ALU_OR   = 5'd8,
    ALU_AND  = 5'd9
  } alu_op_e;

  // ---------------------------------------------------------------------------
  // Decoder output (px_decoder). Every field is defined for every input word:
  // fields that do not apply to an instruction are 0, and an illegal instruction
  // has every enable and side-effect field 0 (only rs1/rs2/rd and illegal are set).
  // The bit layout is mirrored by scripts/gen_decoder_vectors.py; keep them in step.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    OPA_RS1  = 2'd0,
    OPA_PC   = 2'd1,
    OPA_ZERO = 2'd2
  } op_a_sel_e;

  typedef enum logic [1:0] {
    OPB_RS2  = 2'd0,
    OPB_IMM  = 2'd1,
    OPB_LINK = 2'd2     // 4, or 2 for an expanded compressed instruction (chosen in EX)
  } op_b_sel_e;

  typedef enum logic [1:0] {
    WB_ALU    = 2'd0,
    WB_MEM    = 2'd1,
    WB_CSR    = 2'd2,
    WB_MULDIV = 2'd3
  } wb_sel_e;

  typedef enum logic [1:0] {
    MEM_B = 2'd0,
    MEM_H = 2'd1,
    MEM_W = 2'd2
  } mem_size_e;

  typedef enum logic [1:0] {
    CSR_RW = 2'd0,
    CSR_RS = 2'd1,
    CSR_RC = 2'd2
  } csr_op_e;

  typedef struct packed {
    logic        illegal;       // encoding not implemented: raise illegal-instruction trap
    logic [4:0]  rs1;           // raw instruction fields, always passed through
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic        rs1_used;      // instruction architecturally reads rs1 (for hazards)
    logic        rs2_used;
    logic        rd_we;         // writes rd, and rd != x0
    logic [31:0] imm;           // format-specific immediate, sign-extended; zimm for CSR*I
    alu_op_e     alu_op;
    op_a_sel_e   op_a;
    op_b_sel_e   op_b;
    wb_sel_e     wb_sel;
    logic        is_branch;
    logic [2:0]  branch_f3;     // funct3 of the branch (px_pkg::F3_BEQ ... F3_BGEU)
    logic        is_jal;
    logic        is_jalr;
    logic        is_load;
    logic        is_store;
    mem_size_e   mem_size;
    logic        mem_unsigned;  // LBU / LHU
    logic        muldiv_en;
    logic [2:0]  muldiv_op;     // funct3 of the M instruction (F3_MUL ... F3_REMU)
    logic        csr_en;
    csr_op_e     csr_op;
    logic        csr_use_imm;   // CSRRWI / CSRRSI / CSRRCI: operand is zimm (in imm)
    logic        csr_read;      // false for CSRRW/CSRRWI with rd = x0 (no read side effects)
    logic        csr_write;     // false for CSRRS/CSRRC(I) with rs1/zimm = 0 (no write)
    logic [11:0] csr_addr;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        is_wfi;
    logic        is_fence;
    logic        is_fence_i;
  } decode_t;

endpackage
