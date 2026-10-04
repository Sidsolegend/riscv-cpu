// Generic app runner: load a program, release reset, run until it stores
// to HALT. UART writes just print to the console -- this is how hello/fib
// show their output. Program + core picked at compile time:
//   iverilog -DPROG_HEX='"programs/hello.hex"' \
//            -DDATA_HEX='"programs/hello.data.hex"' [-DUSE_PIPE] ...
`timescale 1ns/1ps

`ifndef SEQ_DIV_VAL
`define SEQ_DIV_VAL 0
`endif

`ifndef PROG_HEX
`define PROG_HEX "programs/hello.hex"
`endif
`ifndef DATA_HEX
`define DATA_HEX ""
`endif

module tb_run;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;
    wire halted;

`ifdef USE_PIPE
    riscv_pipeline #(.PROG(`PROG_HEX), .DATA(`DATA_HEX)) dut
        (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .halted(halted));
    localparam CORE = "5-stage pipeline";
`else
    riscv_single #(.PROG(`PROG_HEX), .DATA(`DATA_HEX), .SEQ_DIV(`SEQ_DIV_VAL)) dut
        (.clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr), .halted(halted));
    localparam CORE = "single-cycle";
`endif

    always #5 clk = ~clk;

    integer t;
    initial begin
        $display("---- running %0s on the %0s core ----", `PROG_HEX, CORE);
        repeat (2) @(posedge clk);
        rst = 0;

        // generous budget; every app halts itself long before this
        for (t = 0; t < 100000 && !halted; t = t + 1) @(posedge clk);

        if (halted)
            $display("---- HALT after %0d cycles ----", t);
        else
            $display("---- TIMEOUT: no HALT within %0d cycles ----", t);
        $finish;
    end

endmodule
