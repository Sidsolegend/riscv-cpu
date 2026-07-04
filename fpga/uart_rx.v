// ============================================================================
//  uart_rx.v  —  synthesizable 8N1 UART receiver
// ----------------------------------------------------------------------------
//  The mirror image of uart_tx: it watches the serial line for a start bit
//  (a high->low transition), then samples the middle of each of the 8 data
//  bits one bit-period apart, and finally pulses `valid` for one clock with
//  the assembled byte on `data`.
//
//  Sampling at the MIDDLE of each bit (start + 1.5 bit periods for the first
//  data bit, then +1 each) is the standard way to tolerate small clock/baud
//  mismatches between the two ends — you're as far as possible from either
//  edge where the line is transitioning.
//
//  The incoming line is double-flopped first (rx_sync) to remove metastability
//  from this asynchronous input — mandatory for a real clock domain crossing.
// ============================================================================
module uart_rx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,        // serial line in
    output reg  [7:0] data,      // last byte received (valid when `valid`=1)
    output reg        valid      // one-clock pulse when a byte completes
);
    localparam integer DIVISOR = CLK_HZ / BAUD;

    // Two-flop synchroniser for the asynchronous rx input.
    reg rx_sync0, rx_sync;
    always @(posedge clk) begin
        rx_sync0 <= rx;
        rx_sync  <= rx_sync0;
    end

    localparam IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;
    reg [1:0]  state;
    reg [15:0] clkcnt;
    reg [2:0]  bitidx;
    reg [7:0]  shifter;

    always @(posedge clk) begin
        if (rst) begin
            state  <= IDLE;
            clkcnt <= 16'd0;
            bitidx <= 3'd0;
            valid  <= 1'b0;
            data   <= 8'd0;
        end else begin
            valid <= 1'b0;                          // default: no pulse
            case (state)
                IDLE: begin
                    if (~rx_sync) begin             // saw a start bit
                        state  <= START;
                        clkcnt <= 16'd0;
                    end
                end
                START: begin
                    // wait half a bit period, re-check the line is still low
                    if (clkcnt == (DIVISOR/2) - 1) begin
                        if (~rx_sync) begin
                            state  <= DATA;
                            clkcnt <= 16'd0;
                            bitidx <= 3'd0;
                        end else begin
                            state <= IDLE;          // glitch, not a real start
                        end
                    end else clkcnt <= clkcnt + 16'd1;
                end
                DATA: begin
                    // sample one full bit period apart -> lands mid-bit
                    if (clkcnt == DIVISOR - 1) begin
                        clkcnt         <= 16'd0;
                        shifter        <= {rx_sync, shifter[7:1]};  // LSB first
                        if (bitidx == 3'd7) state <= STOP;
                        else                bitidx <= bitidx + 3'd1;
                    end else clkcnt <= clkcnt + 16'd1;
                end
                STOP: begin
                    if (clkcnt == DIVISOR - 1) begin
                        data  <= shifter;
                        valid <= 1'b1;              // deliver the byte
                        state <= IDLE;
                    end else clkcnt <= clkcnt + 16'd1;
                end
            endcase
        end
    end

endmodule
