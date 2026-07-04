// ============================================================================
//  riscv_single.v  —  TOP LEVEL of the single-cycle RV32I CPU
// ----------------------------------------------------------------------------
//  This module wires every piece together into a working processor. In a
//  SINGLE-CYCLE design, one whole instruction executes per clock cycle:
//  fetch -> decode -> execute -> memory -> write-back all happen between two
//  rising clock edges. Simple to understand, but the clock must be slow enough
//  for the longest instruction — which is exactly why real CPUs pipeline
//  (see ../pipelined/ for the faster version).
//
//  DATA FLOW EACH CYCLE:
//    1. PC points at an instruction; imem returns it.
//    2. control decodes it into switch settings; imm_gen extracts any constant.
//    3. regfile reads rs1/rs2.
//    4. alu computes (arithmetic, or an address for load/store).
//    5. dmem is read (load) or written (store).
//    6. the right value is selected and, on the clock edge, written to rd and
//       the PC advances to the next instruction.
// ============================================================================
`include "defines.vh"

module riscv_single #(
    parameter PROG = "program.hex",
    parameter DATA = ""              // optional .data image preloaded into dmem
)(
    input  wire clk,
    input  wire rst,
    // Debug/observation outputs (used by the testbench to check correctness)
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire        halted,      // program stored to MMIO_HALT (see dmem.v)
    // Device write strobes surfaced for the FPGA top (unused in pure sim).
    output wire        io_uart_we,
    output wire        io_lcd_we,
    output wire [7:0]  io_wbyte
);

    // ---------------------------------------------------------------------
    //  1. PROGRAM COUNTER (the only state that decides "where we are")
    // ---------------------------------------------------------------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] next_pc;

    always @(posedge clk) begin
        if (rst) pc <= 32'd0;      // reset: start at address 0
        else     pc <= next_pc;    // otherwise jump to the computed next address
    end

    assign pc_out = pc;

    // ---------------------------------------------------------------------
    //  2. INSTRUCTION FETCH
    // ---------------------------------------------------------------------
    wire [31:0] instr;
    imem #(.PROG(PROG)) IMEM (.addr(pc), .instr(instr));
    assign instr_out = instr;

    // Pull apart the instruction fields (same positions for every format).
    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire [6:0] funct7 = instr[31:25];

    // ---------------------------------------------------------------------
    //  3. CONTROL + IMMEDIATE DECODE
    // ---------------------------------------------------------------------
    wire       reg_write_raw, alu_src_a, alu_src_b, mem_read, mem_write_raw,
               branch, jump, jalr;
    wire [1:0] result_src;
    wire [4:0] alu_op;

    control CTRL (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write_raw), .alu_src_a(alu_src_a), .alu_src_b(alu_src_b),
        .mem_read(mem_read), .mem_write(mem_write_raw), .result_src(result_src),
        .branch(branch), .jump(jump), .jalr(jalr), .alu_op(alu_op)
    );

    // ---------------------------------------------------------------------
    //  3b. SYSTEM / trap decode  (Zicsr + machine-mode traps)
    // ---------------------------------------------------------------------
    //  Decode the SYSTEM opcode into its two families and flag anything the
    //  core can't execute as an illegal instruction. `trap` (computed with the
    //  CSR file below) then suppresses the current instruction's side effects
    //  and redirects the PC — so a trapping instruction commits NOTHING.
    wire [11:0] funct12 = instr[31:20];         // csr addr / priv selector
    wire        is_system = (opcode == `OPC_SYSTEM);
    wire        is_csr    = is_system && (funct3 != `SYS_PRIV);
    wire        is_priv   = is_system && (funct3 == `SYS_PRIV);

    wire exc_ecall  = is_priv && (funct12 == `PRIV_ECALL);
    wire exc_ebreak = is_priv && (funct12 == `PRIV_EBREAK);
    wire do_mret    = is_priv && (funct12 == `PRIV_MRET);
    wire is_wfi     = is_priv && (funct12 == `PRIV_WFI);   // treated as a nop

    // Which opcodes does this core understand? Anything else -> illegal trap.
    reg legal_opcode;
    always @(*) begin
        case (opcode)
            `OPC_RTYPE, `OPC_ITYPE, `OPC_LOAD,  `OPC_STORE,
            `OPC_BRANCH,`OPC_JAL,   `OPC_JALR,  `OPC_LUI,
            `OPC_AUIPC, `OPC_FENCE: legal_opcode = 1'b1;
            `OPC_SYSTEM: legal_opcode =
                is_csr || exc_ecall || exc_ebreak || do_mret || is_wfi;
            default:     legal_opcode = 1'b0;
        endcase
    end
    wire exc_illegal = !legal_opcode;

    wire [31:0] imm;
    imm_gen IMM (.instr(instr), .imm(imm));

    // ---------------------------------------------------------------------
    //  4. REGISTER FILE (reads now; write happens at end of cycle)
    // ---------------------------------------------------------------------
    wire [31:0] rs1_data, rs2_data;
    wire [31:0] wb_data;             // value chosen for write-back (defined below)

    // A trapping instruction must not commit its result. `commit` (driven by
    // the CSR/trap logic below) is 1 in normal operation, so ordinary programs
    // — which never trap — see exactly the original behaviour.
    wire trap;                       // from the CSR file (section 6b)
    wire commit    = !trap;
    wire reg_write = reg_write_raw & commit;

    regfile RF (
        .clk(clk), .we(reg_write),
        .rs1_addr(rs1), .rs2_addr(rs2), .rd_addr(rd),
        .rd_data(wb_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // ---------------------------------------------------------------------
    //  5. ALU  (operand muxes pick reg-vs-pc and reg-vs-imm)
    // ---------------------------------------------------------------------
    wire [31:0] alu_a = alu_src_a ? pc       : rs1_data;   // PC for AUIPC
    wire [31:0] alu_b = alu_src_b ? imm      : rs2_data;   // imm for I/S/lui/...
    wire [31:0] alu_result;
    wire        alu_zero;

    alu ALU (.a(alu_a), .b(alu_b), .alu_op(alu_op),
             .result(alu_result), .zero(alu_zero));

    // ---------------------------------------------------------------------
    //  6. DATA MEMORY (loads read, stores write)
    // ---------------------------------------------------------------------
    wire [31:0] mem_rdata;
    wire        mem_write = mem_write_raw & commit;   // a trap cancels the store
    dmem #(.DATA(DATA)) DMEM (
        .clk(clk), .rst(rst), .we(mem_write),
        .funct3(funct3),        // access size: lb/lh/lw/lbu/lhu, sb/sh/sw
        .addr(alu_result),      // effective address = rs1 + imm
        .wdata(rs2_data),       // stores write rs2
        .rdata(mem_rdata),
        .halted(halted),
        .io_uart_we(io_uart_we), .io_lcd_we(io_lcd_we), .io_wbyte(io_wbyte)
    );

    // ---------------------------------------------------------------------
    //  6b. CSR FILE + TRAP / INTERRUPT LOGIC (Zicsr, machine mode)
    // ---------------------------------------------------------------------
    //  The CSR file owns mstatus/mtvec/mepc/mcause/mie + the machine timer.
    //  It tells us when to take a trap (jump to mtvec) or return from one
    //  (mret -> mepc). `ex_valid` is de-asserted once the program has halted so
    //  the counters/traps freeze cleanly at the end of simulation.
    wire        csr_mret;
    wire [31:0] csr_rdata, trap_vector, mret_target;

    // Immediate CSR forms use a 5-bit zero-extended constant from the rs1 slot.
    wire [31:0] csr_zimm  = {27'b0, rs1};
    wire [31:0] csr_wsrc  = funct3[2] ? csr_zimm : rs1_data;  // funct3[2]=1 -> *I
    wire        csr_rs1nz = (rs1 != 5'd0);

    csr CSR (
        .clk(clk), .rst(rst),
        .csr_access(is_csr), .csr_addr(funct12), .csr_cmd(funct3),
        .csr_wsrc(csr_wsrc), .csr_rs1_nz(csr_rs1nz), .csr_rdata(csr_rdata),
        .ex_valid(!halted),
        .pc(pc), .exc_ecall(exc_ecall), .exc_ebreak(exc_ebreak),
        .exc_illegal(exc_illegal), .do_mret(do_mret),
        .trap(trap), .trap_vector(trap_vector),
        .mret(csr_mret), .mret_target(mret_target)
    );

    // ---------------------------------------------------------------------
    //  7. WRITE-BACK MUX  (which value goes into rd?)
    // ---------------------------------------------------------------------
    assign wb_data =
        (result_src == `RES_MEM) ? mem_rdata :   // loads
        (result_src == `RES_PC4) ? pc_plus4  :   // jal/jalr return address
        (result_src == `RES_CSR) ? csr_rdata :   // csrrw/csrrs/csrrc[i]
                                   alu_result;    // everything else

    // ---------------------------------------------------------------------
    //  8. BRANCH DECISION + NEXT-PC LOGIC
    // ---------------------------------------------------------------------
    //  Decide whether a conditional branch is taken, based on funct3 and a
    //  comparison of rs1 vs rs2.
    wire signed [31:0] rs1_s = rs1_data;
    wire signed [31:0] rs2_s = rs2_data;
    reg  branch_taken;
    always @(*) begin
        case (funct3)
            3'b000: branch_taken = (rs1_data == rs2_data);   // BEQ
            3'b001: branch_taken = (rs1_data != rs2_data);   // BNE
            3'b100: branch_taken = (rs1_s   <  rs2_s);       // BLT  (signed)
            3'b101: branch_taken = (rs1_s   >= rs2_s);       // BGE  (signed)
            3'b110: branch_taken = (rs1_data <  rs2_data);   // BLTU (unsigned)
            3'b111: branch_taken = (rs1_data >= rs2_data);   // BGEU (unsigned)
            default: branch_taken = 1'b0;
        endcase
    end

    // Jump/branch target addresses.
    wire [31:0] branch_target = pc + imm;                    // beq/jal: pc-relative
    wire [31:0] jalr_target   = (rs1_data + imm) & ~32'd1;   // jalr: reg-relative, LSB cleared
    wire        take_pc_rel   = jump | (branch & branch_taken);

    // A trap or an mret overrides ordinary control flow. Traps have the highest
    // priority: a faulting/interrupted instruction is abandoned and we vector
    // to mtvec instead of advancing. (For non-trapping programs this collapses
    // back to the original jalr / branch / pc+4 selection.)
    assign next_pc = trap        ? trap_vector  :
                     csr_mret     ? mret_target  :
                     jalr         ? jalr_target  :
                     take_pc_rel  ? branch_target :
                                    pc_plus4;

endmodule
