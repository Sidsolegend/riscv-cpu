// Top level of the single-cycle RV32I core -- wires imem/control/regfile/
// alu/dmem together so one full fetch-decode-execute-memory-writeback
// happens every clock edge. Simple, but the clock has to be slow enough
// for the longest instruction path; pipelined/ is the faster version.
`include "defines.vh"

module riscv_single #(
    parameter PROG = "program.hex",
    parameter DATA = "",             // optional .data image preloaded into dmem
    parameter IMEM_WORDS = 256,
    parameter DMEM_WORDS = 256,
    // 1 = div/rem run in the bit-serial muldiv_seq unit (PC stalls until it
    // finishes) instead of the ALU's combinational divider, which is far too
    // big for the FPGA. Same results, just takes ~35 cycles per divide.
    parameter SEQ_DIV = 0,
    parameter CLK_HZ = 0             // what the MMIO_CLKHZ register reports
)(
    input  wire clk,
    input  wire rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire        halted,
    // surfaced for the FPGA top; unused in plain sim
    output wire        io_uart_we,
    output wire        io_lcd_we,
    output wire [7:0]  io_wbyte,
    // program loading (fpga/uart_loader.v), only while rst holds the CPU;
    // tie to 0 when unused
    input  wire        ld_imem_we,
    input  wire        ld_dmem_we,
    input  wire [31:0] ld_addr,     // byte address
    input  wire [31:0] ld_data
);

    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] next_pc;

    always @(posedge clk) begin
        if (rst) pc <= 32'd0;
        else     pc <= next_pc;
    end

    assign pc_out = pc;

    wire [31:0] instr;
    imem #(.MEM_WORDS(IMEM_WORDS), .PROG(PROG)) IMEM (
        .clk(clk), .addr(pc), .instr(instr),
        .we(ld_imem_we), .waddr(ld_addr), .wdata(ld_data));
    assign instr_out = instr;

    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire [6:0] funct7 = instr[31:25];

    // sequential divide: stall until the unit reports done, then commit with
    // its result. md_stall is 0 for everything else (and always when SEQ_DIV=0)
    wire        md_busy, md_done;
    wire [31:0] md_result;
    wire        md_is_div;
    wire        md_stall = md_is_div & ~md_done;
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

    // SYSTEM opcode splits into CSR ops and privileged ops; anything this
    // core doesn't recognize becomes an illegal-instruction trap. `trap`
    // (from the CSR file below) then suppresses that instruction's side
    // effects entirely and redirects the PC instead of letting it commit.
    wire [11:0] funct12 = instr[31:20];         // csr addr / priv selector
    wire        is_system = (opcode == `OPC_SYSTEM);
    wire        is_csr    = is_system && (funct3 != `SYS_PRIV);
    wire        is_priv   = is_system && (funct3 == `SYS_PRIV);

    wire exc_ecall  = is_priv && (funct12 == `PRIV_ECALL);
    wire exc_ebreak = is_priv && (funct12 == `PRIV_EBREAK);
    wire do_mret    = is_priv && (funct12 == `PRIV_MRET);
    wire is_wfi     = is_priv && (funct12 == `PRIV_WFI);   // treated as a nop

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

    wire [31:0] rs1_data, rs2_data;
    wire [31:0] wb_data;

    // a trapping instruction must not commit -- commit is 1 in normal
    // operation so non-trapping programs see no change in behavior
    wire trap;                       // driven by the CSR file below
    wire commit    = !trap;
    // nothing commits while the CPU is held in reset: the instruction at
    // address 0 is still being decoded, and a program is possibly being
    // loaded underneath it
    wire reg_write = reg_write_raw & commit & ~md_stall & ~rst;

    regfile RF (
        .clk(clk), .we(reg_write),
        .rs1_addr(rs1), .rs2_addr(rs2), .rd_addr(rd),
        .rd_data(wb_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    wire [31:0] alu_a = alu_src_a ? pc       : rs1_data;   // PC for AUIPC
    wire [31:0] alu_b = alu_src_b ? imm      : rs2_data;
    wire [31:0] alu_result;
    wire        alu_zero;

    wire [31:0] alu_result_raw;
    alu #(.HAS_DIV(!SEQ_DIV)) ALU (.a(alu_a), .b(alu_b), .alu_op(alu_op),
             .result(alu_result_raw), .zero(alu_zero));

    generate if (SEQ_DIV) begin : g_seq_div
        assign md_is_div = (opcode == `OPC_RTYPE) && (funct7 == `FUNCT7_M) && funct3[2];
        muldiv_seq MD (
            .clk(clk), .rst(rst),
            .start(md_is_div & ~md_busy & ~md_done), .op(funct3),
            .a(rs1_data), .b(rs2_data),
            .result(md_result), .done(md_done), .busy(md_busy)
        );
    end else begin : g_no_div
        assign md_is_div = 1'b0;
        assign md_busy   = 1'b0;
        assign md_done   = 1'b0;
        assign md_result = 32'd0;
    end endgenerate

    assign alu_result = md_is_div ? md_result : alu_result_raw;

    wire [31:0] mem_rdata;
    wire        mem_write = mem_write_raw & commit & ~rst;   // a trap cancels the store
    dmem #(.MEM_WORDS(DMEM_WORDS), .DATA(DATA), .CLK_HZ(CLK_HZ)) DMEM (
        .clk(clk), .rst(rst), .we(mem_write | ld_dmem_we),
        .funct3(ld_dmem_we ? 3'b010 : funct3),               // loader writes whole words
        .addr(ld_dmem_we ? ld_addr : alu_result),            // else rs1 + imm
        .wdata(ld_dmem_we ? ld_data : rs2_data),
        .rdata(mem_rdata),
        .halted(halted),
        .io_uart_we(io_uart_we), .io_lcd_we(io_lcd_we), .io_wbyte(io_wbyte)
    );

    // ex_valid drops once halted so counters/traps freeze cleanly at the
    // end of a run instead of drifting past it
    wire        csr_mret;
    wire [31:0] csr_rdata, trap_vector, mret_target;

    // *i forms use a 5-bit zero-extended constant sitting in the rs1 field
    wire [31:0] csr_zimm  = {27'b0, rs1};
    wire [31:0] csr_wsrc  = funct3[2] ? csr_zimm : rs1_data;  // funct3[2]=1 -> *I
    wire        csr_rs1nz = (rs1 != 5'd0);

    csr CSR (
        .clk(clk), .rst(rst),
        .csr_access(is_csr), .csr_addr(funct12), .csr_cmd(funct3),
        .csr_wsrc(csr_wsrc), .csr_rs1_nz(csr_rs1nz), .csr_rdata(csr_rdata),
        .ex_valid(!halted && !md_stall),
        .pc(pc), .exc_ecall(exc_ecall), .exc_ebreak(exc_ebreak),
        .exc_illegal(exc_illegal), .do_mret(do_mret),
        .trap(trap), .trap_vector(trap_vector),
        .mret(csr_mret), .mret_target(mret_target)
    );

    assign wb_data =
        (result_src == `RES_MEM) ? mem_rdata :   // loads
        (result_src == `RES_PC4) ? pc_plus4  :   // jal/jalr return address
        (result_src == `RES_CSR) ? csr_rdata :   // csrrw/csrrs/csrrc[i]
                                   alu_result;

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

    wire [31:0] branch_target = pc + imm;
    wire [31:0] jalr_target   = (rs1_data + imm) & ~32'd1;   // LSB cleared per spec
    wire        take_pc_rel   = jump | (branch & branch_taken);

    // trap beats everything -- a faulting/interrupted instruction gets
    // abandoned and we vector to mtvec instead of advancing normally
    assign next_pc = md_stall    ? pc           :
                     trap        ? trap_vector  :
                     csr_mret     ? mret_target  :
                     jalr         ? jalr_target  :
                     take_pc_rel  ? branch_target :
                                    pc_plus4;

endmodule
