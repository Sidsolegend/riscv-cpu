// ============================================================================
//  tb_rvc.v  —  self-checking test for the RVC decompressor
// ----------------------------------------------------------------------------
//  Reads (compressed16, golden32) pairs from tests/rvc_vectors.mem and checks
//  the decompressor turns each 16-bit instruction into exactly the 32-bit one
//  it is defined to be equivalent to. The golden 32-bit encodings are produced
//  independently by the project's assembler (tools/asm.py), so this is a true
//  cross-check, not a restatement of the same logic.
// ============================================================================
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
            $display("RESULT: ALL %0d RVC TESTS PASSED  \342\234\205", N);
        else
            $display("RESULT: %0d / %0d RVC TESTS FAILED", errors, N);
        $finish;
    end
endmodule
