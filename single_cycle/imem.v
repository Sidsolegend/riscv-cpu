// Instruction memory, preloaded from a hex file via $readmemh. Reads are
// combinational -- no fetch-stage latency in this model. The write port is
// only for loading a new program (fpga/uart_loader.v); the CPU itself never
// writes here.

module imem #(
    parameter MEM_WORDS = 256,
    parameter PROG      = "program.hex"
)(
    input  wire        clk,
    input  wire [31:0] addr,     // byte address (the PC)
    output wire [31:0] instr,
    input  wire        we,
    input  wire [31:0] waddr,    // byte address
    input  wire [31:0] wdata
);
    reg [31:0] mem [0:MEM_WORDS-1];

    integer i;
    initial begin
`ifndef SYNTHESIS
        // sim only: a short hex file would otherwise leave X's. Synthesis must
        // NOT do this -- Yosys lets the zero-fill override the $readmemh image.
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;
`endif
        $readmemh(PROG, mem);
    end

    // PC is a byte address, instructions are 4 bytes apart, so drop the
    // low 2 bits to get a word index
    assign instr = mem[addr[31:2] % MEM_WORDS];

    always @(posedge clk)
        if (we) mem[waddr[31:2] % MEM_WORDS] <= wdata;

endmodule
