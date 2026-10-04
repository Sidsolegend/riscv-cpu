// Same self-checking test as tb_single.v, run against the pipelined core.
// If forwarding/stalling/flush are all correct, the same program full of
// hazards should still land on identical final values.
`timescale 1ns/1ps

module tb_pipeline;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;

    riscv_pipeline #(.PROG("programs/sum.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .ld_imem_we(1'b0), .ld_dmem_we(1'b0), .ld_addr(32'd0), .ld_data(32'd0)
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

        repeat (400) @(posedge clk);   // more cycles than single-cycle: flush bubbles add up

        $display("");
        $display("==== pipelined CPU results ====");
        check("x1 (sum)   ", dut.RF.regs[1], 32'd55);
        check("x2 (i)     ", dut.RF.regs[2], 32'd11);
        check("x3 (limit) ", dut.RF.regs[3], 32'd11);
        check("x5 (reload)", dut.RF.regs[5], 32'd55);
        check("mem[0]     ", dut.DMEM.mem[0], 32'd55);

        $display("");
        if (errors == 0) $display("RESULT: ALL TESTS PASSED");
        else             $display("RESULT: %0d TEST(S) FAILED", errors);
        $display("");
        $finish;
    end

endmodule
