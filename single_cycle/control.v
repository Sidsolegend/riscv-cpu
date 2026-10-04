// Control unit: decodes opcode/funct3/funct7 into the datapath's control
// signals and the ALU op. Purely combinational.
`include "defines.vh"

module control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,
    output reg        reg_write,
    output reg        alu_src_a,   // 0 = rs1, 1 = pc
    output reg        alu_src_b,   // 0 = rs2, 1 = imm
    output reg        mem_read,
    output reg        mem_write,
    output reg [1:0]  result_src,  // RES_ALU / RES_MEM / RES_PC4
    output reg        branch,
    output reg        jump,        // jal
    output reg        jalr,
    output reg [4:0]  alu_op
);

    // funct7 == FUNCT7_M means this R-type is actually the M-extension
    // encoding (mul/div family), where funct3 picks which of the 8 ops.
    // Otherwise funct7[5] distinguishes ADD/SUB and SRL/SRA as usual.
    reg [4:0] arith_op;
    always @(*) begin
        if (opcode == `OPC_RTYPE && funct7 == `FUNCT7_M) begin
            case (funct3)
                3'b000: arith_op = `ALU_MUL;
                3'b001: arith_op = `ALU_MULH;
                3'b010: arith_op = `ALU_MULHSU;
                3'b011: arith_op = `ALU_MULHU;
                3'b100: arith_op = `ALU_DIV;
                3'b101: arith_op = `ALU_DIVU;
                3'b110: arith_op = `ALU_REM;
                3'b111: arith_op = `ALU_REMU;
                default: arith_op = `ALU_ADD;
            endcase
        end else begin
            case (funct3)
                3'b000: arith_op = (opcode == `OPC_RTYPE && funct7[5]) ? `ALU_SUB : `ALU_ADD;
                3'b001: arith_op = `ALU_SLL;
                3'b010: arith_op = `ALU_SLT;
                3'b011: arith_op = `ALU_SLTU;
                3'b100: arith_op = `ALU_XOR;
                3'b101: arith_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
                3'b110: arith_op = `ALU_OR;
                3'b111: arith_op = `ALU_AND;
                default: arith_op = `ALU_ADD;
            endcase
        end
    end

    always @(*) begin
        // default everything off, each branch below only sets what it needs
        reg_write  = 1'b0;
        alu_src_a  = 1'b0;
        alu_src_b  = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        result_src = `RES_ALU;
        branch     = 1'b0;
        jump       = 1'b0;
        jalr       = 1'b0;
        alu_op     = `ALU_ADD;

        case (opcode)
            `OPC_RTYPE: begin
                reg_write = 1'b1;
                alu_src_b = 1'b0;
                alu_op    = arith_op;
            end

            `OPC_ITYPE: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = arith_op;
            end

            `OPC_LOAD: begin
                reg_write  = 1'b1;
                alu_src_b  = 1'b1;
                alu_op     = `ALU_ADD;
                mem_read   = 1'b1;
                result_src = `RES_MEM;
            end

            `OPC_STORE: begin
                alu_src_b = 1'b1;
                alu_op    = `ALU_ADD;
                mem_write = 1'b1;
            end

            `OPC_BRANCH: begin
                branch = 1'b1;
                alu_op = `ALU_SUB;    // taken/not-taken decision itself happens in the datapath
            end

            `OPC_JAL: begin
                reg_write  = 1'b1;
                jump       = 1'b1;
                result_src = `RES_PC4;
            end

            `OPC_JALR: begin
                reg_write  = 1'b1;
                jalr       = 1'b1;
                alu_src_b  = 1'b1;
                alu_op     = `ALU_ADD;
                result_src = `RES_PC4;
            end

            `OPC_LUI: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = `ALU_PASSB;
            end

            `OPC_AUIPC: begin
                reg_write = 1'b1;
                alu_src_a = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = `ALU_ADD;
            end

            // csrrw/csrrs/csrrc[i] write rd with the old CSR value (RES_CSR);
            // the CSR side effect and trap handling live in the top level.
            // ecall/ebreak/mret fall into funct3 == SYS_PRIV and produce no
            // register result, they're handled entirely up there too.
            `OPC_SYSTEM: begin
                if (funct3 != `SYS_PRIV) begin
                    reg_write  = 1'b1;
                    result_src = `RES_CSR;
                end
            end

            `OPC_FENCE: ; // no-op on this in-order core

            default: ; // unknown opcode -- defaults act as a nop
        endcase
    end

endmodule
