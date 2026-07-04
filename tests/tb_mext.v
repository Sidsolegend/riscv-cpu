// ============================================================================
//  tb_mext.v — self-checking test for the M extension (mul/div family)
// ----------------------------------------------------------------------------
//  Runs programs/mext_test.hex, which leaves known answers in x5..x16 —
//  including every division edge case the RISC-V spec defines (divide by
//  zero, INT_MIN / -1 overflow).
//
//  The SAME testbench checks BOTH cores:
//     iverilog ... tests/tb_mext.v                 -> single-cycle
//     iverilog -DUSE_PIPE ... tests/tb_mext.v      -> 5-stage pipeline
// ============================================================================
`timescale 1ns/1ps

module tb_mext;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;
    wire halted;

`ifdef USE_PIPE
    riscv_pipeline #(.PROG("programs/mext_test.hex")) dut
        (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .halted(halted));
    localparam CORE = "pipeline";
`else
    riscv_single #(.PROG("programs/mext_test.hex")) dut
        (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .halted(halted));
    localparam CORE = "single-cycle";
`endif

    always #5 clk = ~clk;

    integer errors = 0;
    task check;
        input [159:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp)
                $display("  PASS  %0s = 0x%08x", name, got);
            else begin
                $display("  FAIL  %0s = 0x%08x  (expected 0x%08x)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    integer t;
    initial begin
        repeat (2) @(posedge clk);
        rst = 0;

        // run until the program halts itself (or give up)
        for (t = 0; t < 2000 && !halted; t = t + 1) @(posedge clk);

        $display("");
        $display("==== M extension test (%0s core) ====", CORE);
        if (!halted) begin
            $display("  FAIL  program never reached HALT");
            errors = errors + 1;
        end
        check("mul   7*6        ", dut.RF.regs[18],  32'd42);
        check("mulh  -3*5 hi    ", dut.RF.regs[19],  32'hFFFFFFFF);
        check("mulhu -1*2 hi    ", dut.RF.regs[20],  32'd1);
        check("div  -100/7      ", dut.RF.regs[21],  -32'd14);
        check("rem  -100%7      ", dut.RF.regs[22],  -32'd2);
        check("divu  100/7      ", dut.RF.regs[23], 32'd14);
        check("remu  100%7      ", dut.RF.regs[24], 32'd2);
        check("div   5/0        ", dut.RF.regs[25], 32'hFFFFFFFF);
        check("rem   5%0        ", dut.RF.regs[26], 32'd5);
        check("div  MIN/-1      ", dut.RF.regs[27], 32'h80000000);
        check("rem  MIN%-1      ", dut.RF.regs[28], 32'd0);
        check("mulhsu -1,max hi ", dut.RF.regs[29], 32'hFFFFFFFF);

        $display("");
        if (errors == 0) $display("RESULT: ALL M-EXTENSION TESTS PASSED  (%0s)", CORE);
        else             $display("RESULT: %0d TEST(S) FAILED  (%0s)", errors, CORE);
        $display("");
        $finish;
    end

endmodule
