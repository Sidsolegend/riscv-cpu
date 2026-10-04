// Reads (compressed16, golden32) pairs from tests/rvc_vectors.mem and
// checks the decompressor's output against them. The golden encodings
// come from the assembler (tools/asm.py) independently of the RTL, so
// this is a real cross-check rather than the same logic checking itself.
`timescale 1ns/1ps

module tb_rvc;
    localparam N = 22;                 // number of (c16, golden32) pairs
    reg [31:0] vec [0:2*N-1];

    reg  [15:0] c;
    wire [31:0] insn;
    wire        illegal;
    rvc_decompress DUT (.c(c), .insn(insn), .illegal(illegal));

    integer i, errors = 0;
    initial begin
        $readmemh("tests/rvc_vectors.mem", vec);
        $display("---- RVC decompressor vs assembler goldens ----");
        for (i = 0; i < N; i = i + 1) begin
            c = vec[2*i][15:0];
            #1;
            if (illegal) begin
                $display("  FAIL  c=0x%04x flagged illegal", c);
                errors = errors + 1;
            end else if (insn !== vec[2*i+1]) begin
                $display("  FAIL  c=0x%04x -> 0x%08x (want 0x%08x)",
                         c, insn, vec[2*i+1]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("RESULT: ALL %0d RVC TESTS PASSED", N);
        else
            $display("RESULT: %0d / %0d RVC TESTS FAILED", errors, N);
        $finish;
    end
endmodule
