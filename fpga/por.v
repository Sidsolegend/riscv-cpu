// Power-on reset. There's no testbench on real hardware to pulse rst for
// us, so this counter holds reset high for the first CYCLES clocks after
// the bitstream loads, then releases it for good.
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
