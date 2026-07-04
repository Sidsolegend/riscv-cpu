// ============================================================================
//  alu.v  —  Arithmetic Logic Unit
// ----------------------------------------------------------------------------
//  The ALU is the "calculator" of the CPU. It takes two 32-bit operands (a, b)
//  and an operation select (alu_op), and produces a 32-bit result plus a
//  `zero` flag (used by branches to know if result == 0).
//
//  It is PURELY COMBINATIONAL: no clock. Given inputs, the output settles to
//  the right value after a small propagation delay. That is why it uses
//  `always @(*)` (recompute whenever ANY input changes) and NOT
//  `always @(posedge clk)`.
// ============================================================================
`include "defines.vh"

module alu (
    input  wire [31:0] a,        // first operand  (usually rs1)
    input  wire [31:0] b,        // second operand (rs2 or an immediate)
    input  wire [4:0]  alu_op,   // which operation to perform (see defines.vh)
    output reg  [31:0] result,   // the computed value
    output wire        zero      // 1 when result == 0  (branch condition helper)
);
    // Signed views of the operands, needed for signed comparison / arithmetic
    // shift. In Verilog, `$signed()` reinterprets the SAME bits as two's-complement.
    wire signed [31:0] a_s = a;
    wire signed [31:0] b_s = b;

    // ---- M extension products (64-bit; we pick the half we need) ----------
    wire signed [63:0] mul_ss = a_s * b_s;                    // signed   x signed
    wire        [63:0] mul_uu = a   * b;                      // unsigned x unsigned
    wire signed [63:0] mul_su = a_s * $signed({1'b0, b});     // signed   x unsigned

    // RISC-V division edge cases (the spec defines them — no traps in RV32M):
    //   divide by zero:  div -> -1,  divu -> all-ones,  rem/remu -> dividend
    //   overflow (INT_MIN / -1): div -> INT_MIN, rem -> 0
    wire div0 = (b == 32'd0);
    wire ovfl = (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

    // Signed divide/remainder computed in STANDALONE all-signed expressions.
    // (Verilog gotcha: mixing one unsigned operand anywhere in an expression
    //  — e.g. `div0 ? 32'hFFFF_FFFF : a_s / b_s` — silently makes the WHOLE
    //  expression unsigned, so the division itself would go unsigned. Keeping
    //  the division in its own signed wire sidesteps that.)
    wire signed [31:0] b_nz    = div0 ? 32'sd1 : b_s;   // avoid x's from %/0
    wire signed [31:0] quot_ss = a_s / b_nz;
    wire signed [31:0] rem_ss  = a_s % b_nz;

    always @(*) begin
        case (alu_op)
            `ALU_ADD  : result = a + b;
            `ALU_SUB  : result = a - b;
            `ALU_AND  : result = a & b;
            `ALU_OR   : result = a | b;
            `ALU_XOR  : result = a ^ b;
            // SLT: result is 1 if a < b (signed), else 0.
            `ALU_SLT  : result = (a_s < b_s) ? 32'd1 : 32'd0;
            // SLTU: same but unsigned.
            `ALU_SLTU : result = (a   < b  ) ? 32'd1 : 32'd0;
            // Shifts use only the low 5 bits of b as the shift amount
            // (you can only shift a 32-bit value by 0..31).
            `ALU_SLL  : result = a << b[4:0];
            `ALU_SRL  : result = a >> b[4:0];          // logical: fills with 0
            `ALU_SRA  : result = a_s >>> b[4:0];       // arithmetic: fills with sign bit
            `ALU_PASSB: result = b;                    // used by LUI (just forward imm)

            // ---- M extension ------------------------------------------------
            `ALU_MUL   : result = mul_ss[31:0];        // low half (same bits any signedness)
            `ALU_MULH  : result = mul_ss[63:32];
            `ALU_MULHSU: result = mul_su[63:32];
            `ALU_MULHU : result = mul_uu[63:32];
            `ALU_DIV   : result = div0 ? 32'hFFFF_FFFF :
                                  ovfl ? 32'h8000_0000 :
                                         quot_ss;
            `ALU_DIVU  : result = div0 ? 32'hFFFF_FFFF : a / b;
            `ALU_REM   : result = div0 ? a :
                                  ovfl ? 32'd0 :
                                         rem_ss;
            `ALU_REMU  : result = div0 ? a : a % b;

            default   : result = 32'd0;
        endcase
    end

    // zero flag: continuously reflects whether the result bus is all zeros.
    assign zero = (result == 32'd0);

endmodule
