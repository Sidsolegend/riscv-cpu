// ============================================================================
//  control.v  —  The Control Unit (the "brain" that decodes instructions)
// ----------------------------------------------------------------------------
//  This is the single most important module to understand. Everything else
//  (ALU, regfile, memories) is just plumbing; the control unit is what looks
//  at an instruction's opcode + funct3 + funct7 and decides HOW the plumbing
//  should route data this cycle.
//
//  It outputs a bundle of 1-bit "control signals" plus the ALU operation.
//  Think of each control signal as a switch position on the datapath:
//
//    reg_write   : should we write a result back into a register?
//    alu_src_a   : ALU's A input = rs1 (0) or PC (1, for AUIPC)?
//    alu_src_b   : ALU's B input = rs2 (0) or immediate (1)?
//    mem_read    : is this a load?
//    mem_write   : is this a store?
//    result_src  : what goes back to the register? ALU / memory / PC+4
//    branch      : is this a conditional branch?
//    jump        : is this an unconditional jal?
//    jalr        : is this a jalr (jump via register)?
//    alu_op      : which ALU operation to run
//
//  Purely combinational — it just decodes the current instruction.
// ============================================================================
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

    // -- helper: decode the ALU operation for R-type and I-type arithmetic --
    // For R-type, funct7 bit 5 distinguishes ADD/SUB and SRL/SRA.
    // For I-type shifts, the same bit lives in the instruction's funct7 field.
    // R-type with funct7 = 0000001 is the M EXTENSION (mul/div family):
    // funct3 then selects which of the 8 operations.
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
        // ---- Safe defaults: do nothing. Each case below turns on only what
        //      it needs. This "default off" style prevents accidental writes. ----
        reg_write  = 1'b0;
        alu_src_a  = 1'b0;      // rs1
        alu_src_b  = 1'b0;      // rs2
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        result_src = `RES_ALU;
        branch     = 1'b0;
        jump       = 1'b0;
        jalr       = 1'b0;
        alu_op     = `ALU_ADD;

        case (opcode)
            // ---- Register-register arithmetic: add x1, x2, x3 ----
            `OPC_RTYPE: begin
                reg_write = 1'b1;
                alu_src_b = 1'b0;     // second operand is rs2
                alu_op    = arith_op;
            end

            // ---- Register-immediate arithmetic: addi x1, x2, 10 ----
            `OPC_ITYPE: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1;     // second operand is the immediate
                alu_op    = arith_op;
            end

            // ---- Load: lw x1, 8(x2)  ->  address = x2 + imm, read memory ----
            `OPC_LOAD: begin
                reg_write  = 1'b1;
                alu_src_b  = 1'b1;    // address = rs1 + imm
                alu_op     = `ALU_ADD;
                mem_read   = 1'b1;
                result_src = `RES_MEM; // write the loaded value, not the ALU output
            end

            // ---- Store: sw x1, 8(x2)  ->  address = x2 + imm, write memory ----
            `OPC_STORE: begin
                alu_src_b = 1'b1;     // address = rs1 + imm
                alu_op    = `ALU_ADD;
                mem_write = 1'b1;
                // no reg_write: stores don't produce a register result
            end

            // ---- Branch: beq/bne/blt/bge  -> compare rs1,rs2; maybe jump ----
            `OPC_BRANCH: begin
                branch = 1'b1;
                alu_op = `ALU_SUB;    // subtract to test equality via zero flag
                // actual taken/not-taken decision is made in the datapath
                // using funct3 + the comparison result.
            end

            // ---- JAL: jump and link  -> rd = pc+4; pc = pc + imm ----
            `OPC_JAL: begin
                reg_write  = 1'b1;
                jump       = 1'b1;
                result_src = `RES_PC4; // store return address (pc+4) into rd
            end

            // ---- JALR: jump via register -> rd = pc+4; pc = (rs1+imm) & ~1 ----
            `OPC_JALR: begin
                reg_write  = 1'b1;
                jalr       = 1'b1;
                alu_src_b  = 1'b1;
                alu_op     = `ALU_ADD; // target base = rs1 + imm (computed in datapath)
                result_src = `RES_PC4;
            end

            // ---- LUI: load upper immediate -> rd = imm (imm<<12 already) ----
            `OPC_LUI: begin
                reg_write = 1'b1;
                alu_src_b = 1'b1;
                alu_op    = `ALU_PASSB; // just pass the immediate through
            end

            // ---- AUIPC: add upper immediate to pc -> rd = pc + imm ----
            `OPC_AUIPC: begin
                reg_write = 1'b1;
                alu_src_a = 1'b1;     // A input = PC
                alu_src_b = 1'b1;     // B input = imm
                alu_op    = `ALU_ADD;
            end

            // ---- SYSTEM: CSR read-modify-write, or a privileged op ----
            //  funct3 != 0  -> csrrw/csrrs/csrrc[i]: rd gets the OLD CSR value,
            //                  so this writes a register (result comes from the
            //                  CSR file, selected by RES_CSR). The CSR side
            //                  effect + all trap handling live in the top level.
            //  funct3 == 0  -> ecall/ebreak/mret/wfi: no register result; the
            //                  top level turns these into a trap or a return.
            `OPC_SYSTEM: begin
                if (funct3 != `SYS_PRIV) begin
                    reg_write  = 1'b1;
                    result_src = `RES_CSR;
                end
                // else: privileged op — leave every signal at its default (off)
            end

            // ---- FENCE / FENCE.I: ordering hints; a no-op on this in-order core
            `OPC_FENCE: ; // all defaults (off) => behaves as a nop

            default: ; // unknown opcode: all defaults (a harmless no-op)
        endcase
    end

endmodule
