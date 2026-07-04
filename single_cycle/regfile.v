// ============================================================================
//  regfile.v  —  Register File (the 32 general-purpose registers x0..x31)
// ----------------------------------------------------------------------------
//  RISC-V has 32 registers, each 32 bits wide. This module lets the CPU:
//    - READ two registers at once (rs1, rs2)  -> combinational, no clock
//    - WRITE one register (rd)                -> synchronous, on clock edge
//
//  Special rule: x0 is HARD-WIRED to zero. Writes to x0 are ignored, and
//  reading x0 always returns 0. This is a RISC-V invariant we must enforce.
//
//  Why are reads combinational but writes clocked? Because in a single-cycle
//  CPU the instruction needs its operands *immediately* (same cycle), but the
//  result is only committed at the END of the cycle (the rising clock edge),
//  so the next instruction sees the updated value.
// ============================================================================

module regfile (
    input  wire        clk,
    input  wire        we,          // write enable (RegWrite control signal)
    input  wire [4:0]  rs1_addr,    // read port 1 address
    input  wire [4:0]  rs2_addr,    // read port 2 address
    input  wire [4:0]  rd_addr,     // write port address
    input  wire [31:0] rd_data,     // value to write into rd
    output wire [31:0] rs1_data,    // value read from rs1
    output wire [31:0] rs2_data     // value read from rs2
);
    // The actual storage: 32 registers of 32 bits each.
    reg [31:0] regs [0:31];

    integer i;
    initial begin
        // Start every register at 0 so simulation is deterministic.
        for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
    end

    // ---- Synchronous write ----
    // On the rising edge, if write is enabled AND the target isn't x0,
    // store the new value.
    always @(posedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end

    // ---- Combinational reads ----
    // Reading x0 always yields 0 (even if something illegally wrote to it).
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

endmodule
