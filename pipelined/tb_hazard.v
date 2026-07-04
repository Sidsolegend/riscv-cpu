// ============================================================================
//  tb_hazard.v  —  proves forwarding + load-use stall work on the pipeline
// ----------------------------------------------------------------------------
//  Runs programs/hazards.hex, whose every instruction depends on the previous
//  one. Correct results here mean the forwarding_unit and hazard_unit are
//  doing their jobs.
// ============================================================================
`timescale 1ns/1ps

module tb_hazard;
    reg clk = 0, rst = 1;
    wire [31:0] pc, instr;

    riscv_pipeline #(.PROG("programs/hazards.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    always #5 clk = ~clk;
    integer errors = 0;

    task check;
        input [127:0] name; input [31:0] got; input [31:0] exp;
        begin
            if (got === exp) $display("  PASS  %0s = %0d", name, got);
            else begin
                $display("  FAIL  %0s = %0d  (expected %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/hazard.vcd");
        $dumpvars(0, tb_hazard);
        repeat (2) @(posedge clk); rst = 0;
        repeat (60) @(posedge clk);

        $display("");
        $display("==== pipeline hazard stress test ====");
        check("x1", dut.RF.regs[1], 32'd5);
        check("x2", dut.RF.regs[2], 32'd10);
        check("x3 (fwd)     ", dut.RF.regs[3], 32'd15);
        check("x4 (fwd EX/MEM)", dut.RF.regs[4], 32'd10);
        check("x5 (fwd)     ", dut.RF.regs[5], 32'd25);
        check("x6 (load)    ", dut.RF.regs[6], 32'd25);
        check("x7 (load-use stall)", dut.RF.regs[7], 32'd30);
        check("mem[0]", dut.DMEM.mem[0], 32'd25);

        $display("");
        if (errors == 0) $display("RESULT: ALL HAZARD TESTS PASSED  ✅");
        else             $display("RESULT: %0d HAZARD TEST(S) FAILED  ❌", errors);
        $display("");
        $finish;
    end
endmodule
