// 8N1 UART transmitter -- $write in the sim testbenches is a simulator
// shortcut, this is the actual serializer: start bit, 8 data bits LSB
// first, stop bit, each held for CLK_HZ/BAUD clocks (234 clocks/bit at
// 27 MHz / 115200 on the Tang Nano 9K). Wire `tx` to the board's USB-serial
// bridge and it shows up in a terminal over the same USB cable.
//
// Handshake: pulse `wr` with `data` while `busy` is low; busy stays high
// until the stop bit finishes.
module uart_tx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,       // pulse high to send `data` (ignored while busy)
    input  wire [7:0] data,
    output reg        tx,        // serial line (idles high)
    output wire       busy       // 1 while a byte is in flight
);
    localparam integer DIVISOR = CLK_HZ / BAUD;

    // State: idle, or shifting out {stop, data[7:0], start} = 10 bits.
    localparam IDLE = 1'b0, SEND = 1'b1;
    reg        state;
    reg [15:0] clkcnt;        // counts clocks within one bit period
    reg [3:0]  bitidx;        // which of the 10 bits we're on
    reg [9:0]  shifter;       // {stop(1), data(8), start(0)}, shifted out LSB-first

    assign busy = (state == SEND);

    always @(posedge clk) begin
        if (rst) begin
            state   <= IDLE;
            tx      <= 1'b1;      // idle line is high
            clkcnt  <= 16'd0;
            bitidx  <= 4'd0;
            shifter <= 10'h3FF;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (wr) begin
                        // frame = stop(1) : data(8) : start(0), sent LSB first
                        shifter <= {1'b1, data, 1'b0};
                        state   <= SEND;
                        clkcnt  <= 16'd0;
                        bitidx  <= 4'd0;
                        tx      <= 1'b0;      // drive the start bit immediately
                    end
                end
                SEND: begin
                    if (clkcnt == DIVISOR - 1) begin
                        clkcnt <= 16'd0;
                        if (bitidx == 4'd9) begin
                            state <= IDLE;     // stop bit finished
                            tx    <= 1'b1;
                        end else begin
                            bitidx  <= bitidx + 4'd1;
                            shifter <= {1'b1, shifter[9:1]};  // next bit -> LSB
                            tx      <= shifter[1];
                        end
                    end else begin
                        clkcnt <= clkcnt + 16'd1;
                    end
                end
            endcase
        end
    end

endmodule
