// ============================================================================
//  por.v  —  Power-On Reset generator
// ----------------------------------------------------------------------------
//  In simulation a testbench just drives `rst` high for a couple of cycles.
//  On a real FPGA there is no testbench, so the design must reset ITSELF after
//  configuration: this counter holds `rst` high for the first few cycles after
//  the bitstream loads, then releases it and stays low forever. Every flop in
//  the CPU therefore starts from a known state on power-up.
// ============================================================================
module por #(
    parameter CYCLES = 64          // how many clocks to assert reset
)(
    input  wire clk,
    output wire rst
);
    reg [$clog2(CYCLES):0] cnt = 0;
    reg                    rst_r = 1'b1;

    always @(posedge clk) begin
        if (cnt == CYCLES) begin
            rst_r <= 1'b0;         // release reset and latch it low
        end else begin
            cnt   <= cnt + 1'b1;
            rst_r <= 1'b1;
        end
    end

    assign rst = rst_r;

endmodule
