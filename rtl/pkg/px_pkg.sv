// px_pkg: shared constants and types for the PX32 core.
//
// Opcodes, funct fields and CSR addresses follow the RISC-V Unprivileged ISA
// and Privileged ISA specifications, release 20240411 (IMPLEMENTATION_CONTRACTS.md § 1).
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
  // Zba/Zbb/Zbs 1.0.0 and Zicond 1.0 (unprivileged ISA 20240411); F7_ALT is also andn/orn/xnor
  localparam logic [6:0] F7_ZEXTH   = 7'b0000100;  // zext.h (rs2 = 0)
  localparam logic [6:0] F7_MINMAX  = 7'b0000101;  // min, minu, max, maxu
  localparam logic [6:0] F7_CZERO   = 7'b0000111;  // czero.eqz, czero.nez
  localparam logic [6:0] F7_SHADD   = 7'b0010000;  // sh1add, sh2add, sh3add
  localparam logic [6:0] F7_BSET    = 7'b0010100;  // bset(i); orc.b (OP-IMM funct3 101)
  localparam logic [6:0] F7_BCLR    = 7'b0100100;  // bclr(i), bext(i)
  localparam logic [6:0] F7_ROT     = 7'b0110000;  // rol, ror, rori; clz/ctz/cpop/sext.b/sext.h
  localparam logic [6:0] F7_BINV    = 7'b0110100;  // binv(i); rev8 (OP-IMM funct3 101)
  // OP-IMM funct3 001/101 unary Zbb encodings: imm[11:0] (rs2 field selects the operation)
  localparam logic [11:0] IMM_CLZ   = 12'h600;
  localparam logic [11:0] IMM_CTZ   = 12'h601;
  localparam logic [11:0] IMM_CPOP  = 12'h602;
  localparam logic [11:0] IMM_SEXTB = 12'h604;
  localparam logic [11:0] IMM_SEXTH = 12'h605;
  localparam logic [11:0] IMM_ORCB  = 12'h287;
  localparam logic [11:0] IMM_REV8  = 12'h698;   // RV32 encoding (RV64 rev8 is 0x6B8)

  // ---------------------------------------------------------------------------
  // CSR addresses (machine mode subset; CLIC CSRs since step 2.2d)
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
  localparam logic [11:0] CSR_MCONFIGPTR = 12'hF15;
  // Hardware performance monitor (read-only zero in PX32, D-022): mhpmcounter3..31 at
  // 0xB03..0xB1F, their high halves at 0xB83..0xB9F, mhpmevent3..31 at 0x323..0x33F.
  localparam logic [11:0] CSR_MHPMCOUNTER3  = 12'hB03;
  localparam logic [11:0] CSR_MHPMCOUNTER31 = 12'hB1F;
  localparam logic [11:0] CSR_MHPMCOUNTER3H = 12'hB83;
  localparam logic [11:0] CSR_MHPMCOUNTER31H = 12'hB9F;
  localparam logic [11:0] CSR_MHPMEVENT3    = 12'h323;
  localparam logic [11:0] CSR_MHPMEVENT31   = 12'h33F;
  // PMP (read-only zero until step 2.6): pmpcfg0..15 at 0x3A0..0x3AF, pmpaddr0..63 at
  // 0x3B0..0x3EF (one contiguous range)
  localparam logic [11:0] CSR_PMPCFG0       = 12'h3A0;
  localparam logic [11:0] CSR_PMPADDR63     = 12'h3EF;
  // CLIC CSRs (pinned CLIC draft 0.9, "CLIC CSRs"; step 2.2d, D-035). mscratchcsw (0x348)
  // exists only with U-mode (step 2.6) and is illegal until then.
  localparam logic [11:0] CSR_MTVT          = 12'h307;
  localparam logic [11:0] CSR_MNXTI         = 12'h345;
  localparam logic [11:0] CSR_MINTTHRESH    = 12'h347;
  localparam logic [11:0] CSR_MSCRATCHCSW   = 12'h348;
  localparam logic [11:0] CSR_MSCRATCHCSWL  = 12'h349;
  localparam logic [11:0] CSR_MINTSTATUS    = 12'hFB1;

  // misa (read-only, D-022; D-028): MXL = 32 (bits 31:30 = 01), extensions I (bit 8),
  // M (12), C (2) and B (1: Zba, Zbb and Zbs all implemented, privileged ISA 20240411)
  localparam logic [31:0] MISA_VALUE = 32'h4000_1106;

  // mstatus bit positions (RV32, machine mode only)
  localparam int MSTATUS_MIE  = 3;
  localparam int MSTATUS_MPIE = 7;

  // Exception codes (mcause, interrupt bit clear)
  localparam logic [4:0] EXC_IACCESS = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL = 5'd2;
  localparam logic [4:0] EXC_BREAK   = 5'd3;
  localparam logic [4:0] EXC_LMISAL  = 5'd4;
  localparam logic [4:0] EXC_LACCESS = 5'd5;
  localparam logic [4:0] EXC_SMISAL  = 5'd6;
  localparam logic [4:0] EXC_SACCESS = 5'd7;
  localparam logic [4:0] EXC_ECALL_M = 5'd11;

  // ---------------------------------------------------------------------------
  // ALU operations (px_alu): RV32I, Zba, Zbb, Zbs, Zicond (36 operations, 6 bits; D-028).
  // ADD, SH1ADD, SH2ADD and SH3ADD must stay 0..3: px_alu uses op_i[1:0] as the Zba
  // pre-shift amount of operand a and selects the adder only when op_i[5:2] == 0.
  // RORI uses ALU_ROR and the Zbs immediate forms use the register forms (b = immediate).
  // Codes 36..63 are undefined (result 0); Xcvalu (step 2.5a) adds its operations here.
  // ---------------------------------------------------------------------------
  typedef enum logic [5:0] {
    ALU_ADD       = 6'd0,
    ALU_SH1ADD    = 6'd1,
    ALU_SH2ADD    = 6'd2,
    ALU_SH3ADD    = 6'd3,
    ALU_SUB       = 6'd4,
    ALU_SLL       = 6'd5,
    ALU_SLT       = 6'd6,
    ALU_SLTU      = 6'd7,
    ALU_XOR       = 6'd8,
    ALU_SRL       = 6'd9,
    ALU_SRA       = 6'd10,
    ALU_OR        = 6'd11,
    ALU_AND       = 6'd12,
    ALU_ANDN      = 6'd13,
    ALU_ORN       = 6'd14,
    ALU_XNOR      = 6'd15,
    ALU_CLZ       = 6'd16,
    ALU_CTZ       = 6'd17,
    ALU_CPOP      = 6'd18,
    ALU_MAX       = 6'd19,
    ALU_MAXU      = 6'd20,
    ALU_MIN       = 6'd21,
    ALU_MINU      = 6'd22,
    ALU_SEXTB     = 6'd23,
    ALU_SEXTH     = 6'd24,
    ALU_ZEXTH     = 6'd25,
    ALU_ROL       = 6'd26,
    ALU_ROR       = 6'd27,
    ALU_ORCB      = 6'd28,
    ALU_REV8      = 6'd29,
    ALU_BCLR      = 6'd30,
    ALU_BEXT      = 6'd31,
    ALU_BINV      = 6'd32,
    ALU_BSET      = 6'd33,
    ALU_CZERO_EQZ = 6'd34,
    ALU_CZERO_NEZ = 6'd35
  } alu_op_e;

  localparam int ALU_NUM_OPS = 36;

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
