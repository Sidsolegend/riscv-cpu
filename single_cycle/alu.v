// ALU. Purely combinational -- always @(*), not a clocked block, so it
// resolves within the cycle instead of adding a pipeline stage of its own.
`include "defines.vh"

module alu #(
    // 0 drops the combinational dividers (div/divu/rem/remu return 0): four
    // 32-bit dividers alone are bigger than the Tang Nano 9K's whole LUT
    // budget, so the FPGA build divides in muldiv_seq instead
    parameter HAS_DIV = 1
)(
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  alu_op,
    output reg  [31:0] result,
    output wire        zero
);
    // signed views for SLT / SRA / div-rem
    wire signed [31:0] a_s = a;
    wire signed [31:0] b_s = b;

    // M-extension products, 64-bit, we slice out the half we want below
    wire signed [63:0] mul_ss = a_s * b_s;
    wire        [63:0] mul_uu = a   * b;
    wire signed [63:0] mul_su = a_s * $signed({1'b0, b});

    // div-by-zero / overflow per the RV32M spec: div->-1, divu->all-ones,
    // rem/remu->dividend, and INT_MIN/-1 -> div=INT_MIN, rem=0
    wire div0 = (b == 32'd0);
    wire ovfl = (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

    // keep these in their own signed wires -- mixing an unsigned operand
    // into the same expression (e.g. the div0 ? ... : a_s/b_s ternary below)
    // silently makes the whole thing unsigned in Verilog, so don't fold
    // the division itself into that ternary
    wire signed [31:0] b_nz    = div0 ? 32'sd1 : b_s;
    wire signed [31:0] quot_ss = HAS_DIV ? a_s / b_nz : 32'sd0;
    wire signed [31:0] rem_ss  = HAS_DIV ? a_s % b_nz : 32'sd0;
    wire        [31:0] quot_u  = HAS_DIV ? a / b      : 32'd0;
    wire        [31:0] rem_u   = HAS_DIV ? a % b      : 32'd0;

    always @(*) begin
        case (alu_op)
            `ALU_ADD  : result = a + b;
            `ALU_SUB  : result = a - b;
            `ALU_AND  : result = a & b;
            `ALU_OR   : result = a | b;
            `ALU_XOR  : result = a ^ b;
            `ALU_SLT  : result = (a_s < b_s) ? 32'd1 : 32'd0;
            `ALU_SLTU : result = (a   < b  ) ? 32'd1 : 32'd0;
            `ALU_SLL  : result = a << b[4:0];          // only low 5 bits count as shamt
            `ALU_SRL  : result = a >> b[4:0];
            `ALU_SRA  : result = a_s >>> b[4:0];       // fills with sign bit, not 0
            `ALU_PASSB: result = b;                    // LUI just forwards the immediate

            // M extension
            `ALU_MUL   : result = mul_ss[31:0];        // low 32 bits are the same regardless of sign
            `ALU_MULH  : result = mul_ss[63:32];
            `ALU_MULHSU: result = mul_su[63:32];
            `ALU_MULHU : result = mul_uu[63:32];
            `ALU_DIV   : result = div0 ? 32'hFFFF_FFFF :
                                  ovfl ? 32'h8000_0000 :
                                         quot_ss;
            `ALU_DIVU  : result = div0 ? 32'hFFFF_FFFF : quot_u;
            `ALU_REM   : result = div0 ? a :
                                  ovfl ? 32'd0 :
                                         rem_ss;
            `ALU_REMU  : result = div0 ? a : rem_u;

            default   : result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);

endmodule
