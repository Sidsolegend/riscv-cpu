// Immediate generator. RV32I splits the immediate bits across different
// positions per instruction format, so this just untangles them and
// sign-extends to 32 bits. Bit layout per format (instr[31] is always
// the sign bit, that part's consistent):
//
//   I-type : imm = instr[31:20]
//   S-type : imm = instr[31:25], instr[11:7]
//   B-type : imm = instr[31], instr[7], instr[30:25], instr[11:8], 0
//   U-type : imm = instr[31:12] << 12
//   J-type : imm = instr[31], instr[19:12], instr[20], instr[30:21], 0
`include "defines.vh"

module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);
    wire [6:0] opcode = instr[6:0];

    always @(*) begin
        case (opcode)
            // I-type (addi, lw, jalr, ...): 12-bit immediate at [31:20]
            `OPC_ITYPE, `OPC_LOAD, `OPC_JALR:
                imm = {{20{instr[31]}}, instr[31:20]};

            // S-type (sw): 12-bit immediate split as [31:25]+[11:7]
            `OPC_STORE:
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};

            // B-type (branches): 13-bit immediate, bit 0 always 0.
            //   note the odd bit order — this is exactly the RISC-V spec.
            `OPC_BRANCH:
                imm = {{19{instr[31]}}, instr[31], instr[7],
                       instr[30:25], instr[11:8], 1'b0};

            // U-type (lui, auipc): upper 20 bits, low 12 bits are zero.
            `OPC_LUI, `OPC_AUIPC:
                imm = {instr[31:12], 12'b0};

            // J-type (jal): 21-bit immediate, bit 0 always 0.
            `OPC_JAL:
                imm = {{11{instr[31]}}, instr[31], instr[19:12],
                       instr[20], instr[30:21], 1'b0};

            default:
                imm = 32'd0;
        endcase
    end

endmodule
