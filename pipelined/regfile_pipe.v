// Same as single_cycle/regfile.v, but the write happens on the negedge
// instead of the posedge. Reason: WB and ID are 3 stages apart, so an
// instruction retiring in WB can be writing xN the same cycle a younger
// one in ID is reading xN, and forwarding doesn't cover that -- it only
// bypasses into EX. Writing on the posedge meant the ID read (which
// samples combinationally, mid-cycle) would grab the stale value before
// the write landed. That's the bug that made a 1+..+10 sum come out 54
// instead of 55. Moving the write to the negedge fixes it: write lands in
// the first half of the cycle, ID read samples the second half, no race.
//
// This trick only works because in the pipeline the writer (WB) and the
// reader (ID) are always different instructions. Doing the same thing in
// the single-cycle regfile would make an instruction race against its own
// write and create a combinational loop.

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

    always @(negedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end

    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

endmodule
