// ============================================================================
//  regfile_pipe.v  —  Register File for the PIPELINED core (write-first)
// ----------------------------------------------------------------------------
//  Identical to single_cycle/regfile.v EXCEPT the write happens on the
//  NEGATIVE clock edge instead of the positive one. Here's why that matters.
//
//  THE HAZARD IT FIXES:
//    In the pipeline, an instruction in WB may be writing register xN in the
//    very same cycle that a younger instruction in ID is trying to read xN.
//    (They are 3 stages apart: WB and ID overlap.) Forwarding only bypasses
//    values into the EX stage, so it does NOT cover this ID-stage read.
//
//    If the register file wrote on the POSEDGE (end of cycle), the ID read —
//    which happens combinationally DURING the cycle — would grab the OLD value,
//    because the write hasn't landed yet. Result: a stale operand, a wrong answer.
//    (That's the exact bug that made "sum" come out as 54 instead of 55.)
//
//  THE FIX (classic Patterson & Hennessy trick):
//    Write on the NEGEDGE — the middle of the cycle. Now the sequence within
//    one cycle is: (1) write lands at the negedge, (2) the ID read is sampled
//    at the following posedge, by which point the new value is already there.
//    "Write in the first half, read in the second half."
//
//  Why not just do this in the single-cycle regfile too? Because there the
//  write port and the read ports belong to the SAME instruction, so bypassing
//  a just-written value back into its own operand read would create a
//  combinational loop. In the pipeline, the writer (WB) and reader (ID) are
//  always DIFFERENT instructions, so it's safe.
// ============================================================================

module regfile_pipe (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    reg [31:0] regs [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
    end

    // Write in the FIRST HALF of the cycle (negedge), so the value is visible
    // to a same-cycle ID read that samples at the next posedge.
    always @(negedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end

    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

endmodule
