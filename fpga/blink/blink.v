// Bring-up check: a binary counter on the six LEDs. Proves the toolchain,
// the 27 MHz clock pin and the LED pins before the CPU is involved.
module blink (
    input  wire       clk,
    output wire [5:0] led_n
);
    reg [27:0] cnt = 0;
    always @(posedge clk) cnt <= cnt + 1'b1;
    assign led_n = ~cnt[27:22];   // fastest LED ~3 Hz, slowest ~0.1 Hz
endmodule
