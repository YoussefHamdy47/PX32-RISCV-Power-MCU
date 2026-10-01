// px_core: PX32 4-stage in-order pipeline (Phase 1, steps 1.5 to 1.7).
//
// Implements ARCHITECTURE.md § 4.1 and IMPLEMENTATION_CONTRACTS.md § 2.3 for the Phase 1
// subset: RV32IMC, Zicsr, Zifencei, machine mode.
//
//   IF      px_if_stage: prefetch buffer, aligner, RVC expansion
//   ID      px_decoder, px_regfile read (write-through covers WB -> ID), JAL resolution,
//           load-use hazard detection, CSR legality (px_csr)
//   EX      px_alu with forwarding from WB, branch/JALR/FENCE.I/MRET resolution, data
//           request, CSR access (px_csr), multiplier stage 1 (px_mul), divider (px_div),
//           synchronous exception detection
//   MEM/WB  load alignment and extension, multiplier stage 2, register write, retirement
//           trace, bus errors
//
// Timing with single-cycle memories (targets from ARCHITECTURE.md § 4.1)
//   ALU op 1 cycle; load 1 cycle plus 1 if the next instruction uses the result;
//   taken branch, JALR, FENCE.I and MRET 3 cycles (resolved in EX); JAL 2 cycles
//   (resolved in ID); CSR access 1 cycle; trap entry 3 cycles from the trapping
//   instruction in EX to the first handler instruction in EX (D-020 adds 1 for a 32-bit
//   target at a halfword offset).
//   MUL: throughput 1, latency 2: the result is formed in WB and not forwarded, so an
//   instruction that uses it immediately stalls one cycle in ID, like a load (D-023).
//   DIV/REM: the instruction occupies EX for exactly 17 cycles for every operand and holds
//   the pipeline behind it; its result is forwarded from WB, so the next instruction,
//   dependent or not, reaches EX 17 cycles after the divide did (D-023).
//
// Exceptions and ordering
//   - Fetch faults, illegal instructions (including illegal CSR accesses), ECALL/EBREAK and
//     misaligned loads/stores are raised when the instruction is in EX and every older
//     instruction has completed: the instruction does not retire, younger ones are flushed.
//   - A load/store bus error is raised in WB when the response arrives. The data request
//     of the next instruction (in EX) is only issued once the older access has completed
//     without error, so no younger access can have a side effect.
//   - Priority follows the privileged spec: fetch fault, illegal, breakpoint/ECALL,
//     misaligned address; a WB bus error (older instruction) beats anything in EX,
//     including a CSR access or MRET.
//   - CSR accesses and MRET take effect at the EX commit point (ex_to_wb: valid, not
//     held, no exception, no older bus error), the same rule that gates data requests, so
//     stalled, flushed, wrong-path and faulting instructions never change CSR state and
//     each access happens exactly once. The instruction behind a CSR write reads the new
//     value (it reaches EX one cycle later); no pipeline flush is needed in Phase 1.
//   - Trap entry (px_csr): mepc = trapping PC, mcause, mtval, MPIE = MIE, MIE = 0; the
//     redirect goes to mtvec (Direct mode). MRET redirects to mepc like a JALR.
//   - minstret counts retirements in WB; the retirement of an instruction that wrote
//     minstret/minstreth is not counted (the write replaces its increment, D-022).
//   - MUL and DIV results reach the register file only when the instruction retires in
//     WB. A divide that is flushed from EX (older bus error; Phase 2 adds interrupt entry)
//     is abandoned by px_div (kill) and restarts from its first cycle when fetched again.
//
// Staged features (tracked in PROGRESS.md)
//   - Interrupts: Phase 2 (CLIC).
//   WFI executes as a NOP (allowed by the privileged spec); FENCE is a NOP (in-order
//   core, no caches); FENCE.I refetches everything after it.

`timescale 1ns/1ps

module px_core #(
  parameter logic [31:0] BOOT_ADDR   = 32'h1000_0000,
  parameter logic [31:0] MTVEC_RESET = 32'h1000_0040   // mtvec after reset (D-022)
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Instruction port (OBI-style)
  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  output logic [31:0] instr_addr_o,
  input  logic        instr_rvalid_i,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  // Data port (OBI-style)
  output logic        data_req_o,
  input  logic        data_gnt_i,
  output logic [31:0] data_addr_o,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_wdata_o,
  input  logic        data_rvalid_i,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,

  // Retirement trace (one entry per retired instruction, in program order)
  output logic        rvfi_valid_o,
  output logic [31:0] rvfi_pc_o,
  output logic [31:0] rvfi_insn_o,
  output logic [4:0]  rvfi_rd_addr_o,
  output logic [31:0] rvfi_rd_wdata_o,
  output logic [31:0] rvfi_mem_addr_o,
  output logic [3:0]  rvfi_mem_rmask_o,
  output logic [3:0]  rvfi_mem_wmask_o,
  output logic [31:0] rvfi_mem_rdata_o,
  output logic [31:0] rvfi_mem_wdata_o,

  // Trap report (one pulse per trap; the trapping instruction does not retire)
  output logic        trap_valid_o,
  output logic [4:0]  trap_cause_o,
  output logic [31:0] trap_pc_o,
  output logic [31:0] trap_tval_o
);

  import px_pkg::*;

  // Exception causes: px_pkg EXC_*.

  // ===========================================================================
  // Control signals shared between stages (declared first, driven below)
  // ===========================================================================
  logic        wb_wait, wb_bus_err;
  logic        ex_hold, ex_redirect, ex_trap, ex_to_wb;
  logic        id_hold, id_redirect;
  logic        if_redirect;
  logic [31:0] if_redirect_pc;
  logic        id_csr_illegal;
  logic [31:0] csr_mtvec, csr_mepc;
  logic        ex_is_mul, ex_is_div, div_done, div_wait;

  // ===========================================================================
  // IF
  // ===========================================================================
  logic        if_valid;
  logic [31:0] if_pc, if_instr, if_raw;
  logic        if_is_c, if_ill_c, if_ferr, if_ferr_hi;

  px_if_stage #(.BOOT_ADDR(BOOT_ADDR)) u_if (
    .clk_i, .rst_ni,
    .redirect_i     (if_redirect),
    .redirect_pc_i  (if_redirect_pc),
    .valid_o        (if_valid),
    .ready_i        (!id_hold),
    .pc_o           (if_pc),
    .instr_o        (if_instr),
    .raw_o          (if_raw),
    .is_compressed_o(if_is_c),
    .illegal_c_o    (if_ill_c),
    .fetch_err_o    (if_ferr),
    .fetch_err_hi_o (if_ferr_hi),
    .instr_req_o, .instr_gnt_i, .instr_addr_o,
    .instr_rvalid_i, .instr_rdata_i, .instr_err_i
  );

  // ===========================================================================
  // IF/ID register and ID stage
  // ===========================================================================
  logic        id_valid_q;
  logic [31:0] id_pc_q, id_instr_q, id_raw_q;
  logic        id_is_c_q, id_ill_c_q, id_ferr_q, id_ferr_hi_q;

  decode_t     dec;
  px_decoder u_dec (.instr_i(id_instr_q), .dec_o(dec));

  // A CSR access is illegal when px_csr rejects its address or its write attempt
  // (decided on the encoding alone).
  logic id_illegal;
  assign id_illegal     = id_ill_c_q || dec.illegal ||
                          (dec.csr_en && id_csr_illegal);

  // Register file (bank 0 only in Phase 1; port C and write port 1 unused)
  logic [31:0] rf_a, rf_b, rf_c_unused;
  logic        rf_we;
  logic [4:0]  rf_waddr;
  logic [31:0] rf_wdata;

  px_regfile u_rf (
    .clk_i, .rst_ni,
    .bank_i   (1'b0),
    .raddr_a_i(dec.rs1), .rdata_a_o(rf_a),
    .raddr_b_i(dec.rs2), .rdata_b_o(rf_b),
    .raddr_c_i(5'd0),    .rdata_c_o(rf_c_unused),
    .we0_i    (rf_we),   .waddr0_i(rf_waddr), .wdata0_i(rf_wdata),
    .we1_i    (1'b0),    .waddr1_i(5'd0),     .wdata1_i(32'd0)
  );

  // ===========================================================================
  // ID/EX register
  // ===========================================================================
  logic        ex_valid_q;
  logic [31:0] ex_pc_q, ex_raw_q;
  logic        ex_is_c_q, ex_ferr_q, ex_ferr_hi_q, ex_ill_q;
  // The full decode is carried into EX. csr_read is not needed (no implemented CSR has
  // read side effects) and some fields are unused in EX; synthesis removes their flops.
  /* verilator lint_off UNUSEDSIGNAL */
  decode_t     ex_dec_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] ex_rs1_q, ex_rs2_q;

  // Load-use hazard: the instruction in ID needs the result of a load in EX.
  // A multiply's result is formed in WB (D-023) and, like a load's, is not forwarded: its
  // consumer waits in ID for one cycle and reads it through register-file write-through.
  logic load_use;
  assign load_use = id_valid_q && ex_valid_q && (ex_dec_q.is_load || ex_is_mul) && ex_dec_q.rd_we &&
                    ((dec.rs1_used && dec.rs1 == ex_dec_q.rd) ||
                     (dec.rs2_used && dec.rs2 == ex_dec_q.rd));

  // JAL is resolved in ID. The target adder takes the J immediate straight from the
  // instruction bits rather than dec.imm, which the decoder zeroes for illegal words: the
  // adder then does not wait for the legality decode (id_redirect still requires a legal
  // JAL, so the result is only used when the two are equal).
  logic [31:0] id_imm_j, jal_target;
  assign id_imm_j   = {{11{id_instr_q[31]}}, id_instr_q[31], id_instr_q[19:12], id_instr_q[20],
                       id_instr_q[30:21], 1'b0};
  assign jal_target = id_pc_q + id_imm_j;

  // ===========================================================================
  // EX/WB register (declared here: EX forwards from it)
  // ===========================================================================
  logic        wb_valid_q;
  logic [31:0] wb_pc_q, wb_raw_q, wb_result_q, wb_addr_q, wb_wdata_q;
  logic [4:0]  wb_rd_q;
  logic        wb_rd_we_q, wb_is_load_q, wb_is_store_q, wb_unsigned_q, wb_is_mul_q;
  logic        wb_noinc_q;                 // retirement not counted in minstret (D-022)
  mem_size_e   wb_size_q;
  logic [3:0]  wb_be_q;

  // ===========================================================================
  // EX stage
  // ===========================================================================
  logic [31:0] fwd_a, fwd_b;
  logic        fwd_a_q, fwd_b_q;           // forward from WB (registered select)
  logic        fwd_a_d, fwd_b_d;

  // Forward from WB. A load in WB is never forwarded: the load-use stall guarantees that
  // its consumer is still in ID, where register-file write-through supplies the data.
  // The select is decided when the instructions advance (ID->EX with EX->WB) and
  // registered, so no register-number compare sits in front of the EX datapath. After a
  // cycle in which EX was held the operands have been refreshed (see the ID/EX register)
  // and WB holds a bubble or a waiting access, which is never forwarded.
  assign fwd_a_d = ex_to_wb && ex_dec_q.rd_we && !ex_dec_q.is_load && (ex_dec_q.rd == dec.rs1);
  assign fwd_b_d = ex_to_wb && ex_dec_q.rd_we && !ex_dec_q.is_load && (ex_dec_q.rd == dec.rs2);
  assign fwd_a   = fwd_a_q ? wb_result_q : ex_rs1_q;
  assign fwd_b   = fwd_b_q ? wb_result_q : ex_rs2_q;

  // Decode fields used inside always_comb blocks, as plain signals (guide § 3.3).
  op_a_sel_e   ex_op_a;
  op_b_sel_e   ex_op_b;
  mem_size_e   ex_size;
  logic [31:0] ex_imm;
  logic [2:0]  ex_br_f3;
  logic        ex_is_load, ex_is_ebreak, ex_is_ecall, ex_is_jalr, ex_is_mret;
  assign ex_op_a      = ex_dec_q.op_a;
  assign ex_op_b      = ex_dec_q.op_b;
  assign ex_size      = ex_dec_q.mem_size;
  assign ex_imm       = ex_dec_q.imm;
  assign ex_br_f3     = ex_dec_q.branch_f3;
  assign ex_is_load   = ex_dec_q.is_load;
  assign ex_is_ebreak = ex_dec_q.is_ebreak;
  assign ex_is_ecall  = ex_dec_q.is_ecall;
  assign ex_is_jalr   = ex_dec_q.is_jalr;
  assign ex_is_mret   = ex_dec_q.is_mret;

  logic [31:0] alu_a, alu_b, alu_res;
  logic        alu_eq, alu_lt, alu_ltu;

  always_comb begin
    case (ex_op_a)
      OPA_PC:   alu_a = ex_pc_q;
      OPA_ZERO: alu_a = 32'd0;
      default:  alu_a = fwd_a;
    endcase
    case (ex_op_b)
      OPB_IMM:  alu_b = ex_imm;
      OPB_LINK: alu_b = ex_is_c_q ? 32'd2 : 32'd4;
      default:  alu_b = fwd_b;
    endcase
  end

  // Separate signal: Icarus 12 crashes when an enum struct member drives an enum port.
  alu_op_e ex_alu_op;
  assign ex_alu_op = ex_dec_q.alu_op;

  px_alu u_alu (
    .op_i(ex_alu_op), .a_i(alu_a), .b_i(alu_b),
    .result_o(alu_res), .eq_o(alu_eq), .lt_o(alu_lt), .ltu_o(alu_ltu)
  );

  // Branch unit
  logic        br_cond, br_taken;
  logic [31:0] br_target, jalr_sum, jalr_target, fencei_target;

  always_comb begin
    case (ex_br_f3)
      F3_BEQ:  br_cond = alu_eq;
      F3_BNE:  br_cond = !alu_eq;
      F3_BLT:  br_cond = alu_lt;
      F3_BGE:  br_cond = !alu_lt;
      F3_BLTU: br_cond = alu_ltu;
      default: br_cond = !alu_ltu;   // F3_BGEU (other values are illegal and never get here)
    endcase
  end

  assign br_taken      = ex_dec_q.is_branch && br_cond;
  assign br_target     = ex_pc_q + ex_dec_q.imm;
  assign jalr_sum      = fwd_a + ex_dec_q.imm;
  assign jalr_target   = jalr_sum & ~32'd1;       // bit 0 cleared (ISA)
  assign fencei_target = ex_pc_q + 32'd4;

  // Load/store unit (request side)
  logic        ex_is_mem, misaligned;
  logic [1:0]  addr_lo;
  logic [3:0]  be;
  logic [31:0] store_data;

  assign ex_is_mem = ex_dec_q.is_load || ex_dec_q.is_store;
  assign addr_lo   = alu_res[1:0];
  assign misaligned = ex_is_mem &&
                      ((ex_size == MEM_H && addr_lo[0]) ||
                       (ex_size == MEM_W && addr_lo != 2'b00));

  assign be = (ex_size == MEM_B) ? (4'b0001 << addr_lo) :
              (ex_size == MEM_H) ? (4'b0011 << addr_lo) : 4'b1111;
  // Store data is replicated into the addressed byte lanes by shifting.
  assign store_data = fwd_b << {addr_lo, 3'b000};

  // Synchronous exceptions of the instruction in EX, in priority order
  logic        ex_exc;
  logic [4:0]  ex_cause;
  logic [31:0] ex_tval;

  always_comb begin
    ex_exc   = 1'b1;
    ex_cause = 5'd0;
    ex_tval  = 32'd0;
    if (ex_ferr_q) begin
      // mtval is the address of the faulting part: pc + 2 when only the second word of a
      // straddling 32-bit instruction faulted.
      ex_cause = EXC_IACCESS; ex_tval = ex_ferr_hi_q ? ex_pc_q + 32'd2 : ex_pc_q;
    end else if (ex_ill_q) begin
      ex_cause = EXC_ILLEGAL; ex_tval = ex_raw_q;
    end else if (ex_is_ebreak) begin
      ex_cause = EXC_BREAK;   ex_tval = ex_pc_q;
    end else if (ex_is_ecall) begin
      ex_cause = EXC_ECALL_M; ex_tval = 32'd0;
    end else if (misaligned) begin
      ex_cause = ex_is_load ? EXC_LMISAL : EXC_SMISAL; ex_tval = alu_res;
    end else begin
      ex_exc   = 1'b0;
    end
  end

  logic ex_mem_go;          // EX holds a memory access that may be issued
  assign ex_mem_go = ex_valid_q && ex_is_mem && !ex_exc;

  // The data request waits until the older access in WB has completed without error.
  assign data_req_o   = ex_mem_go && !wb_wait && !wb_bus_err;
  assign data_addr_o  = {alu_res[31:2], 2'b00};
  assign data_we_o    = ex_dec_q.is_store;
  assign data_be_o    = be;
  assign data_wdata_o = store_data;

  // ===========================================================================
  // CSR unit
  // ===========================================================================
  // Commit point shared with the data request rule: the instruction in EX is valid, not
  // held, has no exception and no older instruction is failing in WB.
  logic        csr_commit, mret_commit, csr_noinc, wb_count;
  logic [31:0] csr_rdata, csr_operand, ex_result;
  logic [11:0] id_csr_addr, ex_csr_addr;
  logic [1:0]  ex_csr_op;
  assign id_csr_addr = dec.csr_addr;
  assign ex_csr_addr = ex_dec_q.csr_addr;
  assign ex_csr_op   = ex_dec_q.csr_op;
  assign csr_operand = ex_dec_q.csr_use_imm ? ex_imm : fwd_a;
  assign csr_commit  = ex_to_wb && ex_dec_q.csr_en;
  assign mret_commit = ex_to_wb && ex_dec_q.is_mret;

  /* verilator lint_off PINCONNECTEMPTY */
  px_csr #(.MTVEC_RESET(MTVEC_RESET)) u_csr (
    .clk_i, .rst_ni,
    .id_addr_i    (id_csr_addr),
    .id_write_i   (dec.csr_write),
    .id_illegal_o (id_csr_illegal),
    .ex_addr_i    (ex_csr_addr),
    .ex_op_i      (ex_csr_op),
    .ex_operand_i (csr_operand),
    .ex_write_i   (ex_dec_q.csr_write),
    .ex_commit_i  (csr_commit),
    .ex_rdata_o   (csr_rdata),
    .ex_noinc_o   (csr_noinc),
    .retire_i     (wb_count),
    .trap_i       (trap_valid_o),
    .trap_irq_i   (1'b0),
    .trap_cause_i (trap_cause_o),
    .trap_pc_i    (trap_pc_o),
    .trap_tval_i  (trap_tval_o),
    .mret_i       (mret_commit),
    .mtvec_o      (csr_mtvec),
    .mepc_o       (csr_mepc),
    .mstatus_mie_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ===========================================================================
  // Multiplier and divider (D-023)
  // ===========================================================================
  logic [1:0]  ex_md_op;
  logic [31:0] mul_result, div_result;
  logic        div_valid, div_accept;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        div_busy;                   // observed by the testbench
  /* verilator lint_on UNUSEDSIGNAL */
  assign ex_md_op  = ex_dec_q.muldiv_op[1:0];
  assign ex_is_mul = ex_dec_q.muldiv_en && !ex_dec_q.muldiv_op[2];
  assign ex_is_div = ex_dec_q.muldiv_en &&  ex_dec_q.muldiv_op[2];

  // Stage 1 is loaded when the multiply moves to WB; stage 2 feeds the WB write mux.
  px_mul u_mul (
    .clk_i, .rst_ni,
    .en_i    (ex_to_wb && ex_is_mul),
    .op_i    (ex_md_op),
    .a_i     (fwd_a),
    .b_i     (fwd_b),
    .result_o(mul_result)
  );

  // The divider runs while its instruction is valid in EX without an exception, and is
  // killed by an EX flush (older WB bus error). Phase 2: interrupt entry is a second kill
  // source. The instruction leaves EX (accept) in the cycle the result is done.
  assign div_valid  = ex_valid_q && ex_is_div && !ex_exc;
  assign div_accept = ex_to_wb && ex_is_div;
  assign div_wait   = div_valid && !div_done;

  px_div u_div (
    .clk_i, .rst_ni,
    .valid_i (div_valid),
    .kill_i  (wb_bus_err),
    .accept_i(div_accept),
    .op_i    (ex_md_op),
    .a_i     (fwd_a),
    .b_i     (fwd_b),
    .done_o  (div_done),
    .result_o(div_result),
    .busy_o  (div_busy)
  );

  // Result written to rd: the CSR's old value for CSR instructions, the quotient or
  // remainder for divides, else the ALU result (a multiply's result is added in WB).
  assign ex_result = ex_dec_q.csr_en ? csr_rdata : ex_is_div ? div_result : alu_res;

  // ===========================================================================
  // WB stage
  // ===========================================================================
  logic        wb_is_mem;
  logic [31:0] load_val, wb_wdata_rf;
  logic [7:0]  ld_byte;
  logic [15:0] ld_half;

  assign wb_is_mem  = wb_is_load_q || wb_is_store_q;
  assign wb_wait    = wb_valid_q && wb_is_mem && !data_rvalid_i;
  assign wb_bus_err = wb_valid_q && wb_is_mem && data_rvalid_i && data_err_i;

  // Select the addressed halfword, then the addressed byte within it.
  assign ld_half = wb_addr_q[1] ? data_rdata_i[31:16] : data_rdata_i[15:0];
  assign ld_byte = wb_addr_q[0] ? ld_half[15:8] : ld_half[7:0];

  logic ld_byte_sign, ld_half_sign;
  assign ld_byte_sign = !wb_unsigned_q && ld_byte[7];
  assign ld_half_sign = !wb_unsigned_q && ld_half[15];
  assign load_val = (wb_size_q == MEM_B) ? {{24{ld_byte_sign}}, ld_byte} :
                    (wb_size_q == MEM_H) ? {{16{ld_half_sign}}, ld_half} : data_rdata_i;

  assign wb_wdata_rf = wb_is_load_q ? load_val : wb_is_mul_q ? mul_result : wb_result_q;

  logic wb_retire;
  assign wb_retire = wb_valid_q && !wb_wait && !wb_bus_err;
  assign wb_count  = wb_retire && !wb_noinc_q;
  assign rf_we     = wb_retire && wb_rd_we_q;
  assign rf_waddr  = wb_rd_q;
  assign rf_wdata  = wb_wdata_rf;

  // ===========================================================================
  // Hazards, redirects, traps
  // ===========================================================================
  assign ex_hold = wb_wait || (ex_mem_go && !data_gnt_i) || div_wait;
  assign id_hold = ex_hold || load_use;

  assign ex_trap     = ex_valid_q && ex_exc && !ex_hold && !wb_bus_err;
  assign ex_redirect = ex_valid_q && !ex_hold && !wb_bus_err &&
                       (ex_exc || br_taken || ex_dec_q.is_jalr || ex_dec_q.is_fence_i ||
                        ex_dec_q.is_mret);
  assign id_redirect = id_valid_q && !id_hold && !ex_redirect && !wb_bus_err &&
                       dec.is_jal && !id_ferr_q && !id_illegal;

  assign if_redirect = wb_bus_err || ex_redirect || id_redirect;
  always_comb begin
    if (wb_bus_err || ex_trap)       if_redirect_pc = csr_mtvec;
    else if (ex_redirect) begin
      if (br_taken)                  if_redirect_pc = br_target;
      else if (ex_is_jalr)           if_redirect_pc = jalr_target;
      else if (ex_is_mret)           if_redirect_pc = csr_mepc;
      else                           if_redirect_pc = fencei_target;
    end else                         if_redirect_pc = jal_target;
  end

  assign trap_valid_o = wb_bus_err || ex_trap;
  assign trap_cause_o = wb_bus_err ? (wb_is_load_q ? EXC_LACCESS : EXC_SACCESS) : ex_cause;
  assign trap_pc_o    = wb_bus_err ? wb_pc_q : ex_pc_q;
  assign trap_tval_o  = wb_bus_err ? wb_addr_q : ex_tval;

  // ===========================================================================
  // Pipeline registers
  // ===========================================================================

  assign ex_to_wb = ex_valid_q && !ex_hold && !ex_exc && !wb_bus_err;
  logic id_to_ex;
  assign id_to_ex = id_valid_q && !id_hold;

  // IF/ID
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_valid_q <= 1'b0;
      id_pc_q    <= 32'd0; id_instr_q <= 32'd0; id_raw_q <= 32'd0;
      id_is_c_q  <= 1'b0;  id_ill_c_q <= 1'b0;  id_ferr_q <= 1'b0;  id_ferr_hi_q <= 1'b0;
    end else if (wb_bus_err || ex_redirect || id_redirect) begin
      id_valid_q <= 1'b0;
    end else if (!id_hold) begin
      id_valid_q <= if_valid;
      id_pc_q    <= if_pc;
      id_instr_q <= if_instr;
      id_raw_q   <= if_raw;
      id_is_c_q  <= if_is_c;
      id_ill_c_q <= if_ill_c;
      id_ferr_q  <= if_ferr;
      id_ferr_hi_q <= if_ferr_hi;
    end
  end

  // ID/EX
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_valid_q <= 1'b0;
      ex_pc_q    <= 32'd0; ex_raw_q <= 32'd0;
      ex_is_c_q  <= 1'b0;  ex_ferr_q <= 1'b0; ex_ferr_hi_q <= 1'b0; ex_ill_q <= 1'b0;
      ex_dec_q   <= '0;
      ex_rs1_q   <= 32'd0; ex_rs2_q <= 32'd0;
      fwd_a_q    <= 1'b0;  fwd_b_q  <= 1'b0;
    end else if (wb_bus_err || ex_redirect) begin
      ex_valid_q <= 1'b0;
      fwd_a_q    <= 1'b0;  fwd_b_q  <= 1'b0;
    end else if (!ex_hold) begin
      fwd_a_q    <= fwd_a_d;
      fwd_b_q    <= fwd_b_d;
      ex_valid_q <= id_to_ex;
      ex_pc_q    <= id_pc_q;
      ex_raw_q   <= id_raw_q;
      ex_is_c_q  <= id_is_c_q;
      ex_ferr_q  <= id_ferr_q;
      ex_ferr_hi_q <= id_ferr_hi_q;
      ex_ill_q   <= id_illegal;
      ex_dec_q   <= dec;
      ex_rs1_q   <= rf_a;
      ex_rs2_q   <= rf_b;
    end else begin
      // Held in EX: keep the operands current, because the WB instruction that is
      // being forwarded from may leave WB while this instruction waits.
      ex_rs1_q   <= fwd_a;
      ex_rs2_q   <= fwd_b;
      fwd_a_q    <= 1'b0;
      fwd_b_q    <= 1'b0;
    end
  end

  // EX/WB
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_valid_q    <= 1'b0;
      wb_pc_q       <= 32'd0; wb_raw_q <= 32'd0; wb_result_q <= 32'd0;
      wb_addr_q     <= 32'd0; wb_wdata_q <= 32'd0; wb_be_q <= 4'd0;
      wb_rd_q       <= 5'd0;  wb_rd_we_q <= 1'b0;  wb_noinc_q <= 1'b0;
      wb_is_load_q  <= 1'b0;  wb_is_store_q <= 1'b0; wb_unsigned_q <= 1'b0;
      wb_is_mul_q   <= 1'b0;
      wb_size_q     <= MEM_W;
    end else if (!wb_wait) begin
      wb_valid_q    <= ex_to_wb;
      wb_pc_q       <= ex_pc_q;
      wb_raw_q      <= ex_raw_q;
      wb_result_q   <= ex_result;
      wb_addr_q     <= alu_res;
      wb_wdata_q    <= store_data;
      wb_be_q       <= be;
      wb_rd_q       <= ex_dec_q.rd;
      wb_rd_we_q    <= ex_dec_q.rd_we;
      wb_noinc_q    <= ex_dec_q.csr_en && csr_noinc;
      wb_is_load_q  <= ex_dec_q.is_load;
      wb_is_mul_q   <= ex_is_mul;
      wb_is_store_q <= ex_dec_q.is_store;
      wb_unsigned_q <= ex_dec_q.mem_unsigned;
      wb_size_q     <= ex_dec_q.mem_size;
    end
  end

  // ===========================================================================
  // Retirement trace
  // ===========================================================================
  assign rvfi_valid_o     = wb_retire;
  assign rvfi_pc_o        = wb_pc_q;
  assign rvfi_insn_o      = wb_raw_q;
  assign rvfi_rd_addr_o   = wb_rd_we_q ? wb_rd_q : 5'd0;
  assign rvfi_rd_wdata_o  = wb_rd_we_q ? wb_wdata_rf : 32'd0;
  assign rvfi_mem_addr_o  = wb_is_mem ? wb_addr_q : 32'd0;
  assign rvfi_mem_rmask_o = wb_is_load_q  ? wb_be_q : 4'd0;
  assign rvfi_mem_wmask_o = wb_is_store_q ? wb_be_q : 4'd0;
  assign rvfi_mem_rdata_o = wb_is_load_q  ? data_rdata_i : 32'd0;
  assign rvfi_mem_wdata_o = wb_is_store_q ? wb_wdata_q : 32'd0;

endmodule
