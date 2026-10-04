// TX->RX loopback: wires uart_tx's serial line straight into uart_rx and
// round-trips a handful of bytes. Small clock/baud divisor to keep this
// fast in sim.
`timescale 1ns/1ps

module tb_uart;
    // small divisor so bit periods are short in sim (CLK_HZ/BAUD = 16)
    localparam CLK_HZ = 1_600_000, BAUD = 100_000;

    reg        clk = 0, rst = 1;
    reg        wr  = 0;
    reg  [7:0] tx_byte;
    wire       line;                 // the shared serial wire (TX -> RX)
    wire       tx_busy;
    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) TX (
        .clk(clk), .rst(rst), .wr(wr), .data(tx_byte), .tx(line), .busy(tx_busy));

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) RX (
        .clk(clk), .rst(rst), .rx(line), .data(rx_byte), .valid(rx_valid));

    always #5 clk = ~clk;

    integer errors = 0, i;
    reg [7:0] got;

    // capture whatever the receiver delivers; a monotonic counter lets the
    // task detect "a new byte arrived" without driving shared flags itself.
    reg [7:0] rx_cap;
    integer   rx_count = 0;
    always @(posedge clk) begin
        if (rx_valid) begin rx_cap <= rx_byte; rx_count <= rx_count + 1; end
    end

    task send_and_check(input [7:0] b);
        integer prev;
        begin
            prev = rx_count;
            // real firmware polls the transmitter before loading the next byte
            while (tx_busy) @(posedge clk);
            @(posedge clk); wr <= 1'b1; tx_byte <= b;
            @(posedge clk); wr <= 1'b0;
            // wait for the receiver to deliver a new byte (generous timeout)
            i = 0;
            while (rx_count == prev && i < 100000) begin @(posedge clk); i = i + 1; end
            got = rx_cap;
            if (rx_count == prev) begin
                $display("  FAIL  0x%02x -> (no byte received)", b);
                errors = errors + 1;
            end else if (got !== b) begin
                $display("  FAIL  0x%02x -> 0x%02x", b, got);
                errors = errors + 1;
            end else begin
                $display("  PASS  0x%02x round-tripped", b);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst = 0;
        $display("---- UART TX->RX loopback ----");
        send_and_check(8'h41);   // 'A'
        send_and_check(8'h00);   // all zeros
        send_and_check(8'hFF);   // all ones
        send_and_check(8'h55);   // 0101...
        send_and_check(8'hAA);   // 1010...
        if (errors == 0) $display("RESULT: ALL UART TESTS PASSED");
        else             $display("RESULT: %0d UART TEST(S) FAILED", errors);
        $finish;
    end

endmodule
