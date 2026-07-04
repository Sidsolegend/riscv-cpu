// ============================================================================
//  tb_soc.v  —  end-to-end test of the FPGA SoC (CPU -> FIFO -> real UART)
// ----------------------------------------------------------------------------
//  This is the closest thing to "flashing the board" that runs in simulation.
//  It instantiates the actual top level (soc_tangnano9k), lets the CPU execute
//  programs/hello.hex, and decodes the physical uart_tx_pin with a real uart_rx
//  — exactly what the USB-serial bridge does on the board. If the assembled
//  bytes spell out the greeting, the whole hardware path is proven: the store
//  strobe, the FIFO buffering, and the 8N1 serialisation, all together.
//
//  A tiny CLK_HZ/BAUD keeps the bit periods short so it finishes quickly.
// ============================================================================
`timescale 1ns/1ps

module tb_soc;
    localparam CLK_HZ = 1_000_000, BAUD = 100_000;

    reg clk = 0, btn_rst_n = 1, mon_rst = 1;
    wire uart_line, lcd_rs, lcd_e;
    wire [3:0] lcd_db;
    wire [5:0] led_n;

    soc_tangnano9k #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .PROG("programs/hello.hex"), .DATA("programs/hello.data.hex")
    ) DUT (
        .clk(clk), .btn_rst_n(btn_rst_n),
        .uart_tx_pin(uart_line),
        .lcd_rs(lcd_rs), .lcd_e(lcd_e), .lcd_db(lcd_db), .led_n(led_n)
    );

    // Decode the serial line the same way the board's USB bridge would.
    wire [7:0] rx_byte;
    wire       rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) MON (
        .clk(clk), .rst(mon_rst), .rx(uart_line), .data(rx_byte), .valid(rx_valid));

    always #5 clk = ~clk;

    // collect received characters
    reg [7:0] got [0:63];
    integer   n = 0;
    always @(posedge clk) begin
        if (rx_valid && n < 64) begin got[n] <= rx_byte; n <= n + 1; end
    end

    // expected greeting (without the trailing newline)
    localparam MLEN = 25;
    reg [8*MLEN-1:0] msgbuf;
    reg [7:0] want [0:MLEN-1];
    integer   i, errors = 0;

    initial begin
        msgbuf = "HELLO FROM MY RISC-V CPU!";
        for (i = 0; i < MLEN; i = i + 1)
            want[i] = msgbuf[(MLEN-1-i)*8 +: 8];   // unpack the string, char 0 first

        repeat (4) @(posedge clk); mon_rst = 0;   // release the monitor receiver

        $display("---- SoC end-to-end: hello over the real UART ----");
        // run long enough for the CPU to print and the UART to drain
        for (i = 0; i < 200000 && n < MLEN; i = i + 1) @(posedge clk);

        if (n < MLEN) begin
            $display("  FAIL  only %0d of %0d chars received", n, MLEN);
            errors = errors + 1;
        end else begin
            for (i = 0; i < MLEN; i = i + 1) begin
                if (got[i] !== want[i]) begin
                    $display("  FAIL  char %0d = 0x%02x (want 0x%02x)",
                             i, got[i], want[i]);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("  PASS  received \"HELLO FROM MY RISC-V CPU!\" over uart_tx_pin");
        end

        if (errors == 0) $display("RESULT: SoC END-TO-END TEST PASSED  \342\234\205");
        else             $display("RESULT: %0d SoC TEST FAILURE(S)", errors);
        $finish;
    end
endmodule
