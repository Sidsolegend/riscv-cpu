// ============================================================================
//  tb_muldiv.v  —  differential test: sequential mul/div vs the trusted ALU
// ----------------------------------------------------------------------------
//  The combinational ALU already passes the full M-extension suite, so it makes
//  a perfect reference oracle. This bench drives the same (op, a, b) into both
//  the ALU and the multi-cycle muldiv_seq unit and asserts the results match —
//  first on the spec's nasty edge cases, then across a large pseudo-random
//  sweep. If the bit-serial shift-add / restoring-divide datapaths are correct,
//  they agree with the reference on every single input.
// ============================================================================
`timescale 1ns/1ps
`include "defines.vh"

module tb_muldiv;
    reg         clk = 0, rst = 1, start = 0;
    reg  [2:0]  op;
    reg  [31:0] a, b;
    wire [31:0] seq_result;
    wire        seq_done, seq_busy;

    // reference: the combinational ALU (alu_op = 16 + funct3 for the M ops)
    wire [31:0] ref_result;
    alu REF (.a(a), .b(b), .alu_op(5'd16 + op), .result(ref_result), .zero());

    muldiv_seq DUT (
        .clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
        .result(seq_result), .done(seq_done), .busy(seq_busy));

    always #5 clk = ~clk;

    integer errors = 0, total = 0, k;
    reg [8*8-1:0] opname [0:7];
    initial begin
        opname[0]="mul";  opname[1]="mulh"; opname[2]="mulhsu"; opname[3]="mulhu";
        opname[4]="div";  opname[5]="divu"; opname[6]="rem";    opname[7]="remu";
    end

    task check(input [2:0] o, input [31:0] x, input [31:0] y);
        reg [31:0] expected;
        begin
            op = o; a = x; b = y;
            #1 expected = ref_result;            // settle the combinational ref
            @(posedge clk); start <= 1'b1;
            @(posedge clk); start <= 1'b0;
            k = 0;
            while (!seq_done && k < 200) begin @(posedge clk); k = k + 1; end
            total = total + 1;
            if (seq_result !== expected) begin
                errors = errors + 1;
                $display("  FAIL  %0s(%08x,%08x) = %08x (ref %08x)",
                         opname[o], x, y, seq_result, expected);
            end
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(posedge clk); rst = 0;
        $display("---- sequential mul/div vs ALU reference ----");

        // ---- edge cases across all eight ops ----
        for (i = 0; i < 8; i = i + 1) begin
            check(i[2:0], 32'd0,          32'd0);
            check(i[2:0], 32'd1,          32'd0);          // ÷0 for the div ops
            check(i[2:0], 32'hFFFF_FFFF,  32'hFFFF_FFFF);  // -1,-1
            check(i[2:0], 32'h8000_0000,  32'hFFFF_FFFF);  // INT_MIN / -1 overflow
            check(i[2:0], 32'h8000_0000,  32'd1);
            check(i[2:0], 32'h7FFF_FFFF,  32'h7FFF_FFFF);
            check(i[2:0], 32'hFFFF_FFFF,  32'd2);
            check(i[2:0], 32'd100,        32'd7);
            check(i[2:0], -32'sd100,      32'd7);
        end

        // ---- pseudo-random sweep ----
        for (i = 0; i < 2000; i = i + 1)
            check($random % 8, $random, $random);

        if (errors == 0)
            $display("RESULT: ALL %0d MULDIV TESTS PASSED  \342\234\205", total);
        else
            $display("RESULT: %0d / %0d MULDIV TESTS FAILED", errors, total);
        $finish;
    end
endmodule
