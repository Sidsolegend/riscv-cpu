// Byte/half load-store test: programs/memops_test.hex builds a word out of
// individual byte stores and reads it back at every size; checks both the
// register results and that the bytes actually landed correctly in RAM.
// -DUSE_PIPE selects the pipeline instead of single-cycle.
`timescale 1ns/1ps

module tb_memops;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;
    wire halted;

`ifdef USE_PIPE
    riscv_pipeline #(.PROG("programs/memops_test.hex")) dut
        (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .halted(halted));
    localparam CORE = "pipeline";
`else
    riscv_single #(.PROG("programs/memops_test.hex")) dut
        (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .halted(halted), .ld_imem_we(1'b0), .ld_dmem_we(1'b0), .ld_addr(32'd0), .ld_data(32'd0));
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

        for (t = 0; t < 2000 && !halted; t = t + 1) @(posedge clk);

        $display("");
        $display("==== byte/half load-store test (%0s core) ====", CORE);
        if (!halted) begin
            $display("  FAIL  program never reached HALT");
            errors = errors + 1;
        end
        check("lw  word from sb's", dut.RF.regs[18],  32'h8091A2B3);
        check("lb  sign-extend   ", dut.RF.regs[19],  32'hFFFFFF80);
        check("lbu zero-extend   ", dut.RF.regs[20],  32'h00000080);
        check("lh  sign-extend   ", dut.RF.regs[21],  32'hFFFF8091);
        check("lhu zero-extend   ", dut.RF.regs[22],  32'h00008091);
        check("sh  upper half    ", dut.RF.regs[23], 32'hBEEF0000);
        check("lb  0xB3 sign-ext ", dut.RF.regs[24], 32'hFFFFFFB3);
        check("mem[0] raw word   ", dut.DMEM.mem[0], 32'h8091A2B3);
        check("mem[1] raw word   ", dut.DMEM.mem[1], 32'hBEEF0000);

        $display("");
        if (errors == 0) $display("RESULT: ALL MEM-OP TESTS PASSED  (%0s)", CORE);
        else             $display("RESULT: %0d TEST(S) FAILED  (%0s)", errors, CORE);
        $display("");
        $finish;
    end

endmodule
