// Self-checking testbench for the single-cycle core: runs programs/sum.hex
// to completion and pokes inside the register file / data memory to check
// the result.
`timescale 1ns/1ps

module tb_single;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;

    riscv_single #(.PROG("programs/sum.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    task check;
        input [127:0] name;   // label (packed ASCII)
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
        $dumpfile("sim/single.vcd");
        $dumpvars(0, tb_single);

        repeat (2) @(posedge clk);
        rst = 0;

        repeat (200) @(posedge clk);   // program spins on halt once done

        $display("");
        $display("==== single-cycle CPU results ====");
        check("x1 (sum)  ", dut.RF.regs[1], 32'd55);
        check("x2 (i)    ", dut.RF.regs[2], 32'd11);
        check("x3 (limit)", dut.RF.regs[3], 32'd11);
        check("x5 (reload)", dut.RF.regs[5], 32'd55);
        check("mem[0]    ", dut.DMEM.mem[0], 32'd55);

        $display("");
        if (errors == 0) $display("RESULT: ALL TESTS PASSED");
        else             $display("RESULT: %0d TEST(S) FAILED", errors);
        $display("");
        $finish;
    end

endmodule
