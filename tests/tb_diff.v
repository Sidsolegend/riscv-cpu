// ============================================================================
//  tb_diff.v  —  differential equivalence check: single-cycle vs pipeline
// ----------------------------------------------------------------------------
//  The strongest correctness argument in the whole project: take the SAME
//  program, run it on BOTH cores, and prove they end in byte-for-byte identical
//  architectural state (all 32 registers + the low data memory). The two cores
//  share nothing but the ISA — one executes an instruction per cycle, the other
//  overlaps five with forwarding, stalls and flushes — so if every register and
//  memory word agrees, the pipeline's hazard machinery is provably transparent.
//
//  This is exactly how real CPUs are validated: a simple reference model and a
//  fast implementation, cross-checked on the same stimulus. Point it at any
//  non-CSR program via +define+; the Makefile runs it on fib and the M-ext test.
// ============================================================================
`timescale 1ns/1ps

`ifndef PROG_HEX
`define PROG_HEX "programs/fib.hex"
`endif
`ifndef DATA_HEX
`define DATA_HEX "programs/fib.data.hex"
`endif

module tb_diff;
    reg clk = 0, rst = 1;
    wire [31:0] pc_a, ins_a, pc_b, ins_b;
    wire        halt_a, halt_b;

    riscv_single #(.PROG(`PROG_HEX), .DATA(`DATA_HEX)) SC (
        .clk(clk), .rst(rst), .pc_out(pc_a), .instr_out(ins_a), .halted(halt_a));

    riscv_pipeline #(.PROG(`PROG_HEX), .DATA(`DATA_HEX)) PIPE (
        .clk(clk), .rst(rst), .pc_out(pc_b), .instr_out(ins_b), .halted(halt_b));

    always #5 clk = ~clk;

    integer i, errors = 0, t;
    initial begin
        $display("---- differential check on %0s ----", `PROG_HEX);
        repeat (2) @(posedge clk); rst = 0;

        // run until BOTH cores have halted (or a generous timeout)
        for (t = 0; t < 200000 && !(halt_a && halt_b); t = t + 1) @(posedge clk);
        // let the last write-backs settle
        repeat (2) @(posedge clk);

        if (!halt_a || !halt_b) begin
            $display("  FAIL  a core never halted (sc=%b pipe=%b)", halt_a, halt_b);
            errors = errors + 1;
        end

        // compare all 32 architectural registers
        for (i = 0; i < 32; i = i + 1) begin
            if (SC.RF.regs[i] !== PIPE.RF.regs[i]) begin
                $display("  FAIL  x%0d: sc=%08x pipe=%08x", i, SC.RF.regs[i], PIPE.RF.regs[i]);
                errors = errors + 1;
            end
        end

        // compare the low 64 words of data memory
        for (i = 0; i < 64; i = i + 1) begin
            if (SC.DMEM.mem[i] !== PIPE.DMEM.mem[i]) begin
                $display("  FAIL  mem[%0d]: sc=%08x pipe=%08x", i, SC.DMEM.mem[i], PIPE.DMEM.mem[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("RESULT: CORES AGREE on registers + memory  \342\234\205");
        else
            $display("RESULT: %0d DIFFERENCE(S) between the cores", errors);
        $finish;
    end
endmodule
