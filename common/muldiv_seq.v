// Multi-cycle mul/div, one bit per cycle -- closer to what real silicon
// does than the single-cycle ALU's combinational `*`/`/` (a 32-bit divide
// isn't a one-fast-cycle carry chain on actual hardware). Multiply is
// shift-and-add on a 64-bit product register; divide is restoring
// division, shifting the dividend into a remainder one bit at a time and
// subtracting the divisor when it fits. Both work on magnitudes and fix
// up the sign at the end; div-by-zero and INT_MIN/-1 follow the RV32M spec.
//
// Handshake: pulse `start` with op/a/b, `busy` goes high, `done` pulses
// for one cycle when `result` is valid -- a real pipeline would stall on
// `busy`. Cross-checked against the ALU's combinational result plus a
// random sweep in tests/tb_muldiv.v.
`include "defines.vh"

module muldiv_seq (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,       // pulse to begin (ignored while busy)
    input  wire [2:0]  op,          // funct3 of the M instruction (0..7)
    input  wire [31:0] a,           // rs1
    input  wire [31:0] b,           // rs2
    output reg  [31:0] result,
    output reg         done,        // one-cycle pulse when result is valid
    output wire        busy
);
    localparam IDLE = 2'd0, MUL = 2'd1, DIV = 2'd2, FIN = 2'd3;
    reg [1:0]  state;
    assign busy = (state != IDLE);

    // operand signedness per operation
    // multiply: mul/mulh -> both signed; mulhsu -> a signed, b unsigned; mulhu -> both unsigned
    // divide:   div/rem  -> signed;      divu/remu -> unsigned
    function a_signed(input [2:0] o);
        a_signed = (o==3'd0)||(o==3'd1)||(o==3'd2)||(o==3'd4)||(o==3'd6);
    endfunction
    function b_signed(input [2:0] o);
        b_signed = (o==3'd0)||(o==3'd1)||(o==3'd4)||(o==3'd6);
    endfunction

    reg  [2:0]  cur_op;
    reg  [5:0]  cnt;
    reg         res_neg, rem_neg;
    reg  [31:0] multiplicand;
    reg  [63:0] P;                  // multiply: product; divide: {remainder, dividend}
    reg  [31:0] divisor;
    reg  [63:0] prod;               // scratch for FIN, blocking-assigned
    reg  [31:0] q, r;

    // magnitudes of the incoming operands (combinational, sampled at start)
    wire        na = a_signed(op) & a[31];
    wire        nb = b_signed(op) & b[31];
    wire [31:0] a_mag = na ? (~a + 32'd1) : a;
    wire [31:0] b_mag = nb ? (~b + 32'd1) : b;

    // one restoring-division step on {remainder, dividend} = P
    wire [63:0] p_sh   = {P[62:0], 1'b0};                 // shift left 1
    wire [31:0] rem_hi = p_sh[63:32];
    wire        fits   = (rem_hi >= divisor);
    wire [63:0] p_next = fits ? {rem_hi - divisor, p_sh[31:1], 1'b1} : p_sh;

    // one shift-and-add multiply step on P
    wire [32:0] addsum = P[63:32] + multiplicand;
    wire [64:0] p_full = P[0] ? {addsum, P[31:0]} : {1'b0, P};
    wire [63:0] m_next = p_full[64:1];                    // shift right 1

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; done <= 1'b0; result <= 32'd0; cnt <= 6'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    cur_op  <= op;
                    cnt     <= 6'd0;
                    if (op < 3'd4) begin
                        // ---- multiply ----
                        multiplicand <= a_mag;
                        P            <= {32'd0, b_mag};
                        res_neg      <= na ^ nb;
                        state        <= MUL;
                    end else begin
                        // ---- divide: handle the spec's edge cases up front --
                        if (b == 32'd0) begin
                            case (op)
                                3'd4: result <= 32'hFFFF_FFFF;   // div  ÷0 -> -1
                                3'd5: result <= 32'hFFFF_FFFF;   // divu ÷0 -> all ones
                                3'd6: result <= a;               // rem  ÷0 -> dividend
                                default: result <= a;            // remu ÷0 -> dividend
                            endcase
                            done  <= 1'b1;
                            state <= IDLE;
                        end else if ((op==3'd4 || op==3'd6) &&
                                     a==32'h8000_0000 && b==32'hFFFF_FFFF) begin
                            result <= (op==3'd4) ? 32'h8000_0000 : 32'd0; // overflow
                            done   <= 1'b1;
                            state  <= IDLE;
                        end else begin
                            divisor <= b_mag;
                            P       <= {32'd0, a_mag};
                            res_neg <= na ^ nb;              // quotient sign
                            rem_neg <= na;                   // remainder takes dividend's sign
                            state   <= DIV;
                        end
                    end
                end
                MUL: begin
                    P   <= m_next;
                    cnt <= cnt + 6'd1;
                    if (cnt == 6'd31) state <= FIN;
                end
                DIV: begin
                    P   <= p_next;
                    cnt <= cnt + 6'd1;
                    if (cnt == 6'd31) state <= FIN;
                end
                FIN: begin
                    if (cur_op < 3'd4) begin
                        // multiply: apply sign, then pick the requested half
                        prod = res_neg ? (~P + 64'd1) : P;
                        result <= (cur_op==3'd0) ? prod[31:0] : prod[63:32];
                    end else begin
                        // divide: quotient=P[31:0], remainder=P[63:32]
                        q = P[31:0];
                        r = P[63:32];
                        case (cur_op)
                            3'd4: result <= res_neg ? (~q + 32'd1) : q;  // div
                            3'd5: result <= q;                           // divu
                            3'd6: result <= rem_neg ? (~r + 32'd1) : r;  // rem
                            default: result <= r;                        // remu
                        endcase
                    end
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
