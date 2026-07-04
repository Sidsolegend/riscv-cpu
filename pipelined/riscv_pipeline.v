// ============================================================================
//  riscv_pipeline.v  —  TOP LEVEL of the 5-stage pipelined RV32I CPU
// ----------------------------------------------------------------------------
//  Same instruction set as the single-cycle core, but now FIVE instructions
//  are in flight at once, each in a different stage — like an assembly line:
//
//     IF  -> ID  -> EX  -> MEM -> WB
//    fetch  decode exec  memory  write-back
//
//  Between each pair of stages sits a PIPELINE REGISTER (ifid, idex, exmem,
//  memwb) that carries an instruction's data + control signals forward one
//  step every clock edge. Throughput jumps to ~1 instruction/cycle.
//
//  The price of overlapping instructions is HAZARDS — cases where an
//  instruction needs something that isn't ready yet:
//     * data hazard   -> solved by the forwarding_unit (bypass the value)
//     * load-use      -> solved by the hazard_unit (stall one cycle)
//     * control hazard -> solved by resolving branches in EX and flushing the
//                         two wrong-path instructions behind them
//
//  Read the single-cycle core first (../single_cycle/) — this is that same
//  datapath, sliced into 5 stages with those three hazard mechanisms bolted on.
// ============================================================================
`include "defines.vh"

module riscv_pipeline #(
    parameter PROG = "program.hex",
    parameter DATA = ""              // optional .data image preloaded into dmem
)(
    input  wire clk,
    input  wire rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out,
    output wire        halted       // program stored to MMIO_HALT (see dmem.v)
);
    // A "bubble" instruction: addi x0, x0, 0  — does literally nothing.
    localparam [31:0] NOP = 32'h00000013;

    // Forward declarations of control signals produced downstream (in EX/WB)
    // but consumed upstream (in IF/ID). Verilog lets wires be used before the
    // line that drives them, which is what makes feedback paths like these work.
    wire        stall;         // from hazard_unit: freeze front of pipe 1 cycle
    wire        pc_redirect;   // from EX: a branch/jump was taken
    wire [31:0] pc_target;     // from EX: where to redirect to
    wire        flush;         // from EX: squash the 2 wrong-path instructions
    wire [31:0] wb_data;       // from WB: value written back (also forwarded)
    wire        memwb_reg_write;
    wire [4:0]  memwb_rd;

    // =====================================================================
    //  STAGE 1 — IF : Instruction Fetch
    // =====================================================================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] instr_if;

    imem #(.PROG(PROG)) IMEM (.addr(pc), .instr(instr_if));

    always @(posedge clk) begin
        if (rst)              pc <= 32'd0;
        else if (pc_redirect) pc <= pc_target;   // taken branch/jump wins
        else if (stall)       pc <= pc;          // load-use: hold still
        else                  pc <= pc_plus4;    // normal: next instruction
    end

    assign pc_out    = pc;
    assign instr_out = instr_if;

    // ---- IF/ID pipeline register ----
    reg [31:0] ifid_instr, ifid_pc, ifid_pc4;
    always @(posedge clk) begin
        if (rst || flush) begin
            // squash: whatever we just fetched is on the wrong path
            ifid_instr <= NOP;
            ifid_pc    <= 32'd0;
            ifid_pc4   <= 32'd0;
        end else if (stall) begin
            // hold the current instruction in place (re-decode it next cycle)
            ifid_instr <= ifid_instr;
            ifid_pc    <= ifid_pc;
            ifid_pc4   <= ifid_pc4;
        end else begin
            ifid_instr <= instr_if;
            ifid_pc    <= pc;
            ifid_pc4   <= pc_plus4;
        end
    end

    // =====================================================================
    //  STAGE 2 — ID : Instruction Decode + register read
    // =====================================================================
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
    // Uses the pipeline register file (writes on negedge = "write first half,
    // read second half") so a WB-stage write is visible to a same-cycle ID read.
    regfile_pipe RF (
        .clk(clk), .we(memwb_reg_write),
        .rs1_addr(id_rs1), .rs2_addr(id_rs2), .rd_addr(memwb_rd),
        .rd_data(wb_data),
        .rs1_data(id_rs1_data), .rs2_data(id_rs2_data)
    );

    // A bubble must be injected into ID/EX when we stall (load-use) OR flush
    // (branch taken squashes the instruction currently in ID).
    wire ctrl_kill = stall | flush;

    // ---- ID/EX pipeline register ----
    reg        idex_reg_write, idex_alu_src_a, idex_alu_src_b, idex_mem_read,
               idex_mem_write, idex_branch, idex_jump, idex_jalr;
    reg [1:0]  idex_result_src;
    reg [4:0]  idex_alu_op;
    reg [2:0]  idex_funct3;
    reg [31:0] idex_pc, idex_pc4, idex_rs1_data, idex_rs2_data, idex_imm;
    reg [4:0]  idex_rs1, idex_rs2, idex_rd;

    always @(posedge clk) begin
        if (rst || ctrl_kill) begin
            // insert a bubble: every control signal off => harmless no-op
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

    // =====================================================================
    //  STAGE 3 — EX : Execute (ALU, forwarding, branch resolution)
    // =====================================================================
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

    // Forwarding muxes: pick the freshest value for each operand.
    wire [31:0] fwd_a =
        (forward_a == 2'b10) ? exmem_alu_result :   // from EX/MEM
        (forward_a == 2'b01) ? wb_data          :   // from MEM/WB
                               idex_rs1_data;       // from register file
    wire [31:0] fwd_b =
        (forward_b == 2'b10) ? exmem_alu_result :
        (forward_b == 2'b01) ? wb_data          :
                               idex_rs2_data;

    // ALU operand selects (AUIPC uses PC on A; imm-type uses imm on B).
    wire [31:0] alu_a = idex_alu_src_a ? idex_pc  : fwd_a;
    wire [31:0] alu_b = idex_alu_src_b ? idex_imm : fwd_b;

    wire [31:0] ex_alu_result;
    wire        ex_alu_zero;
    alu ALU (.a(alu_a), .b(alu_b), .alu_op(idex_alu_op),
             .result(ex_alu_result), .zero(ex_alu_zero));

    // Branch decision, computed from the FORWARDED register values.
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

    wire [31:0] ex_branch_target = idex_pc + idex_imm;          // beq / jal
    wire [31:0] ex_jalr_target   = (fwd_a + idex_imm) & ~32'd1; // jalr
    wire        ex_take = idex_jump | idex_jalr | (idex_branch & branch_taken);

    // These feed all the way back to the IF stage.
    assign pc_redirect = ex_take;
    assign pc_target   = idex_jalr ? ex_jalr_target : ex_branch_target;
    assign flush       = ex_take;   // squash the 2 instructions behind the branch

    // ---- EX/MEM pipeline register ----
    reg         exmem_mem_read, exmem_mem_write;
    reg [1:0]   exmem_result_src;
    reg [2:0]   exmem_funct3;              // access size travels with the instruction
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

    // =====================================================================
    //  STAGE 4 — MEM : Data memory access
    // =====================================================================
    wire [31:0] mem_rdata;
    dmem #(.DATA(DATA)) DMEM (
        .clk(clk), .rst(rst), .we(exmem_mem_write),
        .funct3(exmem_funct3),
        .addr(exmem_alu_result), .wdata(exmem_store_data), .rdata(mem_rdata),
        .halted(halted)
    );

    // ---- MEM/WB pipeline register ----
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

    // =====================================================================
    //  STAGE 5 — WB : Write Back (choose value, write register file)
    // =====================================================================
    assign wb_data =
        (memwb_result_src == `RES_MEM) ? memwb_mem_rdata :
        (memwb_result_src == `RES_PC4) ? memwb_pc4       :
                                         memwb_alu_result;
    // (the actual register write happens inside RF, using memwb_reg_write/rd)

    // =====================================================================
    //  HAZARD UNIT (load-use detection) — drives `stall`
    // =====================================================================
    hazard_unit HZD (
        .idex_mem_read(idex_mem_read), .idex_rd(idex_rd),
        .ifid_rs1(id_rs1), .ifid_rs2(id_rs2),
        .stall(stall)
    );

endmodule
