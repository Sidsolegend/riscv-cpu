// Top level of the 5-stage pipeline (IF/ID/EX/MEM/WB), same ISA as the
// single-cycle core in ../single_cycle/ but with up to 5 instructions in
// flight, one pipeline register (ifid/idex/exmem/memwb) between each stage.
// The three hazard mechanisms bolted onto the datapath below:
//   - data hazard    -> forwarding_unit bypasses the value into EX
//   - load-use       -> hazard_unit stalls the front of the pipe one cycle
//   - control hazard -> branches resolve in EX and flush the 2 instructions
//                        fetched behind them on the wrong path
`include "defines.vh"

module riscv_pipeline #(
    parameter PROG = "program.hex",
    parameter DATA = ""
)(
    input  wire clk,
    input  wire rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire        halted
);
    localparam [31:0] NOP = 32'h00000013;   // addi x0, x0, 0

    // driven further down the pipe, read further up it -- Verilog is fine
    // with a wire being used before the line that assigns it
    wire        stall;
    wire        pc_redirect;
    wire [31:0] pc_target;
    wire        flush;
    wire [31:0] wb_data;
    wire        memwb_reg_write;
    wire [4:0]  memwb_rd;

    // ---- IF ----
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] instr_if;

    imem #(.PROG(PROG)) IMEM (.clk(clk), .addr(pc), .instr(instr_if),
                              .we(1'b0), .waddr(32'd0), .wdata(32'd0));

    always @(posedge clk) begin
        if (rst)              pc <= 32'd0;
        else if (pc_redirect) pc <= pc_target;   // taken branch/jump wins
        else if (stall)       pc <= pc;          // load-use: hold still
        else                  pc <= pc_plus4;    // normal: next instruction
    end

    assign pc_out    = pc;
    assign instr_out = instr_if;

    reg [31:0] ifid_instr, ifid_pc, ifid_pc4;
    always @(posedge clk) begin
        if (rst || flush) begin
            ifid_instr <= NOP;      // wrong-path instruction gets squashed
            ifid_pc    <= 32'd0;
            ifid_pc4   <= 32'd0;
        end else if (stall) begin
            ifid_instr <= ifid_instr;   // hold in place, re-decode next cycle
            ifid_pc    <= ifid_pc;
            ifid_pc4   <= ifid_pc4;
        end else begin
            ifid_instr <= instr_if;
            ifid_pc    <= pc;
            ifid_pc4   <= pc_plus4;
        end
    end

    // ---- ID ----
    wire [6:0] id_opcode = ifid_instr[6:0];
    wire [4:0] id_rd     = ifid_instr[11:7];
    wire [2:0] id_funct3 = ifid_instr[14:12];
    wire [4:0] id_rs1    = ifid_instr[19:15];
    wire [4:0] id_rs2    = ifid_instr[24:20];
    wire [6:0] id_funct7 = ifid_instr[31:25];

    wire       id_reg_write, id_alu_src_a, id_alu_src_b, id_mem_read,
               id_mem_write, id_branch, id_jump, id_jalr;
    wire [1:0] id_result_src;
    wire [4:0] id_alu_op;

    control CTRL (
        .opcode(id_opcode), .funct3(id_funct3), .funct7(id_funct7),
        .reg_write(id_reg_write), .alu_src_a(id_alu_src_a), .alu_src_b(id_alu_src_b),
        .mem_read(id_mem_read), .mem_write(id_mem_write), .result_src(id_result_src),
        .branch(id_branch), .jump(id_jump), .jalr(id_jalr), .alu_op(id_alu_op)
    );

    wire [31:0] id_imm;
    imm_gen IMM (.instr(ifid_instr), .imm(id_imm));

    wire [31:0] id_rs1_data, id_rs2_data;
    // regfile_pipe writes on the negedge so a WB write this cycle is
    // visible to this same-cycle ID read -- see regfile_pipe.v
    regfile_pipe RF (
        .clk(clk), .we(memwb_reg_write),
        .rs1_addr(id_rs1), .rs2_addr(id_rs2), .rd_addr(memwb_rd),
        .rd_data(wb_data),
        .rs1_data(id_rs1_data), .rs2_data(id_rs2_data)
    );

    wire ctrl_kill = stall | flush;   // either one turns ID/EX into a bubble

    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b, idex_mem_read,
               idex_mem_write, idex_branch, idex_jump, idex_jalr;
    reg [1:0]  idex_result_src;
    reg [4:0]  idex_alu_op;
    reg [2:0]  idex_funct3;
    reg [31:0] idex_pc, idex_pc4, idex_rs1_data, idex_rs2_data, idex_imm;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd;

    always @(posedge clk) begin
        if (rst || ctrl_kill) begin
            idex_reg_write <= 1'b0; idex_alu_src_a <= 1'b0; idex_alu_src_b <= 1'b0;
            idex_mem_read  <= 1'b0; idex_mem_write <= 1'b0; idex_branch    <= 1'b0;
            idex_jump      <= 1'b0; idex_jalr      <= 1'b0; idex_result_src<= 2'b0;
            idex_alu_op    <= 5'b0; idex_funct3    <= 3'b0;
            idex_pc <= 32'd0; idex_pc4 <= 32'd0; idex_rs1_data <= 32'd0;
            idex_rs2_data <= 32'd0; idex_imm <= 32'd0;
            idex_rs1 <= 5'd0; idex_rs2 <= 5'd0; idex_rd <= 5'd0;
        end else begin
            idex_reg_write <= id_reg_write; idex_alu_src_a <= id_alu_src_a;
            idex_alu_src_b <= id_alu_src_b; idex_mem_read  <= id_mem_read;
            idex_mem_write <= id_mem_write; idex_branch    <= id_branch;
            idex_jump      <= id_jump;      idex_jalr      <= id_jalr;
            idex_result_src<= id_result_src;idex_alu_op    <= id_alu_op;
            idex_funct3    <= id_funct3;
            idex_pc <= ifid_pc; idex_pc4 <= ifid_pc4;
            idex_rs1_data <= id_rs1_data; idex_rs2_data <= id_rs2_data; idex_imm <= id_imm;
            idex_rs1 <= id_rs1; idex_rs2 <= id_rs2; idex_rd <= id_rd;
        end
    end

    // ---- EX ----
    reg  [31:0] exmem_alu_result;     // declared here so forwarding can read it
    reg         exmem_reg_write;
    reg  [4:0]  exmem_rd;

    wire [1:0] forward_a, forward_b;
    forwarding_unit FWD (
        .exmem_reg_write(exmem_reg_write), .exmem_rd(exmem_rd),
        .memwb_reg_write(memwb_reg_write), .memwb_rd(memwb_rd),
        .idex_rs1(idex_rs1), .idex_rs2(idex_rs2),
        .forward_a(forward_a), .forward_b(forward_b)
    );

    wire [31:0] fwd_a =
        (forward_a == 2'b10) ? exmem_alu_result :
        (forward_a == 2'b01) ? wb_data          :
                               idex_rs1_data;
    wire [31:0] fwd_b =
        (forward_b == 2'b10) ? exmem_alu_result :
        (forward_b == 2'b01) ? wb_data          :
                               idex_rs2_data;

    wire [31:0] alu_a = idex_alu_src_a ? idex_pc  : fwd_a;   // AUIPC uses PC
    wire [31:0] alu_b = idex_alu_src_b ? idex_imm : fwd_b;

    wire [31:0] ex_alu_result;
    wire        ex_alu_zero;
    alu ALU (.a(alu_a), .b(alu_b), .alu_op(idex_alu_op),
             .result(ex_alu_result), .zero(ex_alu_zero));

    // branch decision uses the forwarded values, not the raw idex_rs*_data
    wire signed [31:0] fa_s = fwd_a;
    wire signed [31:0] fb_s = fwd_b;
    reg branch_taken;
    always @(*) begin
        case (idex_funct3)
            3'b000: branch_taken = (fwd_a == fwd_b);   // BEQ
            3'b001: branch_taken = (fwd_a != fwd_b);   // BNE
            3'b100: branch_taken = (fa_s  <  fb_s );   // BLT
            3'b101: branch_taken = (fa_s  >= fb_s );   // BGE
            3'b110: branch_taken = (fwd_a <  fwd_b);   // BLTU
            3'b111: branch_taken = (fwd_a >= fwd_b);   // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    wire [31:0] ex_branch_target = idex_pc + idex_imm;
    wire [31:0] ex_jalr_target   = (fwd_a + idex_imm) & ~32'd1;
    wire        ex_take = idex_jump | idex_jalr | (idex_branch & branch_taken);

    // feeds back to IF: redirect the PC and flush the 2 instructions behind
    assign pc_redirect = ex_take;
    assign pc_target   = idex_jalr ? ex_jalr_target : ex_branch_target;
    assign flush       = ex_take;

    reg         exmem_mem_read, exmem_mem_write;
    reg [1:0]   exmem_result_src;
    reg [2:0]   exmem_funct3;
    reg [31:0]  exmem_store_data, exmem_pc4;
    always @(posedge clk) begin
        if (rst) begin
            exmem_reg_write <= 1'b0; exmem_mem_read <= 1'b0; exmem_mem_write <= 1'b0;
            exmem_result_src <= 2'b0; exmem_alu_result <= 32'd0; exmem_funct3 <= 3'b0;
            exmem_store_data <= 32'd0; exmem_pc4 <= 32'd0; exmem_rd <= 5'd0;
        end else begin
            exmem_reg_write  <= idex_reg_write;
            exmem_mem_read   <= idex_mem_read;
            exmem_mem_write  <= idex_mem_write;
            exmem_result_src <= idex_result_src;
            exmem_alu_result <= ex_alu_result;
            exmem_funct3     <= idex_funct3;
            exmem_store_data <= fwd_b;          // sw data (forwarded rs2)
            exmem_pc4        <= idex_pc4;
            exmem_rd         <= idex_rd;
        end
    end

    // ---- MEM ----
    wire [31:0] mem_rdata;
    dmem #(.DATA(DATA)) DMEM (
        .clk(clk), .rst(rst), .we(exmem_mem_write),
        .funct3(exmem_funct3),
        .addr(exmem_alu_result), .wdata(exmem_store_data), .rdata(mem_rdata),
        .halted(halted)
    );

    reg [1:0]  memwb_result_src;
    reg [31:0] memwb_mem_rdata, memwb_alu_result, memwb_pc4;
    reg        memwb_reg_write_r;
    reg [4:0]  memwb_rd_r;
    always @(posedge clk) begin
        if (rst) begin
            memwb_reg_write_r <= 1'b0; memwb_result_src <= 2'b0;
            memwb_mem_rdata <= 32'd0; memwb_alu_result <= 32'd0;
            memwb_pc4 <= 32'd0; memwb_rd_r <= 5'd0;
        end else begin
            memwb_reg_write_r <= exmem_reg_write;
            memwb_result_src  <= exmem_result_src;
            memwb_mem_rdata   <= mem_rdata;
            memwb_alu_result  <= exmem_alu_result;
            memwb_pc4         <= exmem_pc4;
            memwb_rd_r        <= exmem_rd;
        end
    end
    assign memwb_reg_write = memwb_reg_write_r;
    assign memwb_rd        = memwb_rd_r;

    // ---- WB ---- (the actual register write happens inside RF up in ID,
    // driven by memwb_reg_write/rd)
    assign wb_data =
        (memwb_result_src == `RES_MEM) ? memwb_mem_rdata :
        (memwb_result_src == `RES_PC4) ? memwb_pc4       :
                                         memwb_alu_result;

    hazard_unit HZD (
        .idex_mem_read(idex_mem_read), .idex_rd(idex_rd),
        .ifid_rs1(id_rs1), .ifid_rs2(id_rs2),
        .stall(stall)
    );

endmodule
