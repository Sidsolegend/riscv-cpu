// ============================================================================
//  tb_single.v  —  Self-checking testbench for the single-cycle core
// ----------------------------------------------------------------------------
//  A testbench is NOT part of the CPU — it's the "lab bench" that surrounds it
//  in simulation. It:
//    1. generates a clock,
//    2. pulses reset,
//    3. lets the CPU run the program for a while,
//    4. peeks inside the register file / data memory and checks the results
//       against what we expect, printing PASS or FAIL.
//
//  Because it never gets synthesized to hardware, it's allowed to use
//  simulation-only features: `#` delays, `$display`, `$readmemh`, and
//  "hierarchical references" like dut.RF.regs[1] to look inside the design.
// ============================================================================
`timescale 1ns/1ps

module tb_single;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;

    // The Device Under Test: our CPU, loaded with the sum program.
    // (Path is relative to the project root, where the Makefile runs it.)
    riscv_single #(.PROG("programs/sum.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    // Clock: flip every 5 ns -> a 10 ns period.
    always #5 clk = ~clk;

    integer errors = 0;

    // A small helper task: compare an actual value to an expected one.
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
        // Record a waveform so you can open it in GTKWave later.
        // (Kept short — this program finishes in well under 100 cycles.)
        $dumpfile("sim/single.vcd");
        $dumpvars(0, tb_single);

        // Hold reset for 2 clock edges, then release.
        repeat (2) @(posedge clk);
        rst = 0;

        // Let the program run to completion (it then spins on `halt`).
        repeat (200) @(posedge clk);

        // ---- Check the results by peeking inside the design ----
        $display("");
        $display("==== single-cycle CPU results ====");
        check("x1 (sum)  ", dut.RF.regs[1], 32'd55);
        check("x2 (i)    ", dut.RF.regs[2], 32'd11);
        check("x3 (limit)", dut.RF.regs[3], 32'd11);
        check("x5 (reload)", dut.RF.regs[5], 32'd55);
        check("mem[0]    ", dut.DMEM.mem[0], 32'd55);

        $display("");
        if (errors == 0) $display("RESULT: ALL TESTS PASSED  ✅");
        else             $display("RESULT: %0d TEST(S) FAILED  ❌", errors);
        $display("");
        $finish;
    end

endmodule
