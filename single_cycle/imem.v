// ============================================================================
//  imem.v  —  Instruction Memory (read-only program storage)
// ----------------------------------------------------------------------------
//  Holds the program. In a real chip this would be ROM or a cache; here it's a
//  simple array preloaded from a hex file at simulation start via $readmemh.
//
//  IMPORTANT addressing detail: the PC counts in BYTES and every instruction
//  is 4 bytes, so addresses go 0, 4, 8, 12, ...  To index a WORD array we drop
//  the bottom 2 bits (addr >> 2). That's what addr[<hi>:2] does below.
//
//  Reads are combinational: give it a PC, it returns that instruction the same
//  cycle (instruction fetch has no clock delay in this simple model).
// ============================================================================

module imem #(
    parameter MEM_WORDS = 256,               // 256 instructions = 1 KB of code
    parameter PROG      = "program.hex"      // hex file to preload
)(
    input  wire [31:0] addr,     // byte address (the PC)
    output wire [31:0] instr     // the 32-bit instruction at that address
);
    reg [31:0] mem [0:MEM_WORDS-1];

    integer i;
    initial begin
        // Fill with 0 first (0x00000000 is not a valid instr, harmless if fetched).
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;
        // Then overlay the program. $readmemh reads whitespace/newline-separated
        // hex words, one per line, into mem[0], mem[1], ...
        $readmemh(PROG, mem);
    end

    // Word index = byte address / 4. We assume the program fits in MEM_WORDS.
    assign instr = mem[addr[31:2] % MEM_WORDS];

endmodule
