// Runs the same program on both cores and diffs the final architectural
// state (all 32 registers + the low data memory). The two implementations
// share nothing but the ISA -- one instruction per cycle vs. five
// overlapping with forwarding/stalls/flushes -- so agreement here is the
// strongest evidence the pipeline's hazard handling is actually
// transparent. Same idea as validating real silicon against a reference
// model. Point at a different program with +define+PROG_HEX=...; the
// Makefile runs this on fib and the M-ext test.
`timescale 1ns/1ps

`ifndef SEQ_DIV_VAL
`define SEQ_DIV_VAL 0
`endif

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

    riscv_single #(.PROG(`PROG_HEX), .DATA(`DATA_HEX), .SEQ_DIV(`SEQ_DIV_VAL)) SC (
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
            $display("RESULT: CORES AGREE on registers + memory");
        else
            $display("RESULT: %0d DIFFERENCE(S) between the cores", errors);
        $finish;
    end
endmodule
