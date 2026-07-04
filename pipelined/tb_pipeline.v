// ============================================================================
//  tb_pipeline.v  —  Self-checking testbench for the 5-stage pipelined core
// ----------------------------------------------------------------------------
//  Runs the SAME program as the single-cycle core and checks for the SAME
//  final results. If the pipeline's forwarding, stalling, and branch-flush
//  logic are all correct, a program full of data/control hazards must still
//  produce identical answers to the simple design — that's the whole test.
// ============================================================================
`timescale 1ns/1ps

module tb_pipeline;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;

    riscv_pipeline #(.PROG("programs/sum.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    always #5 clk = ~clk;   // 10 ns period

    integer errors = 0;

    task check;
        input [127:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp)
                $display("  PASS  %0s = %0d", name, got);
            else begin
                $display("  FAIL  %0s = %0d  (expected %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/pipeline.vcd");
        $dumpvars(0, tb_pipeline);

        repeat (2) @(posedge clk);
        rst = 0;

        // More cycles than single-cycle: each taken jump/branch costs a couple
        // flush bubbles, so the pipelined run takes longer in cycles (but each
        // cycle is far cheaper in a real chip). 400 is plenty for this program.
        repeat (400) @(posedge clk);

        $display("");
        $display("==== pipelined CPU results ====");
        check("x1 (sum)   ", dut.RF.regs[1], 32'd55);
        check("x2 (i)     ", dut.RF.regs[2], 32'd11);
        check("x3 (limit) ", dut.RF.regs[3], 32'd11);
        check("x5 (reload)", dut.RF.regs[5], 32'd55);
        check("mem[0]     ", dut.DMEM.mem[0], 32'd55);

        $display("");
        if (errors == 0) $display("RESULT: ALL TESTS PASSED  ✅");
        else             $display("RESULT: %0d TEST(S) FAILED  ❌", errors);
        $display("");
        $finish;
    end

endmodule
