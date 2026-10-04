// Bring-up check: send "HELLO" over the UART pin once a second, no CPU.
// Separates "serial pin / port wrong" from "CPU or SoC wrong".
module uart_test (
    input  wire       clk,
    output wire       uart_tx_pin,
    output wire [5:0] led_n
);
    reg [24:0] cnt = 0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    reg [2:0] idx = 0;
    reg       wr  = 0;
    wire      busy;
    reg [7:0] data;
    always @(*) case (idx)
        3'd0: data = "H"; 3'd1: data = "E"; 3'd2: data = "L";
        3'd3: data = "L"; 3'd4: data = "O"; default: data = 8'h0A;
    endcase

    reg running = 0;
    always @(posedge clk) begin
        wr <= 1'b0;
        if (&cnt) begin running <= 1'b1; idx <= 0; end    // about once a second
        else if (running && !busy && !wr) begin
            wr <= 1'b1;
            if (idx == 3'd5) running <= 1'b0; else idx <= idx + 1'b1;
        end
    end

    uart_tx #(.CLK_HZ(27_000_000), .BAUD(115200)) TX (
        .clk(clk), .rst(1'b0), .wr(wr), .data(data), .tx(uart_tx_pin), .busy(busy));

    assign led_n = ~{cnt[24], 5'b0};
endmodule
