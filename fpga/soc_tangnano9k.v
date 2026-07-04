// ============================================================================
//  soc_tangnano9k.v  —  top level that puts the CPU on a real FPGA
// ----------------------------------------------------------------------------
//  This is the module you synthesize onto a Sipeed Tang Nano 9K. It takes the
//  board's 27 MHz oscillator and a reset button, and turns the simulated core
//  into an actual chip that:
//
//     * runs the program baked into imem/dmem (PROG/DATA hex, loaded into BRAM)
//     * prints to your computer over the on-board USB-serial bridge (uart_tx),
//       buffered through a FIFO so bursts of characters aren't dropped
//     * mirrors those characters to a 16x2 HD44780 LCD on the GPIO header
//     * blinks the on-board LEDs as a "the core is alive" heartbeat, and lights
//       one when the program executes its HALT store
//
//  No PLL is needed for a first bring-up: the core is comfortably fast enough
//  to run directly from the 27 MHz clock. The pin names below are mapped to
//  physical balls in fpga/tangnano9k.cst.
//
//  Bring-up order (see docs/FPGA.md): blink an LED first to prove the toolchain
//  and pin map, THEN synthesize this to run the CPU for real.
// ============================================================================
`include "defines.vh"

module soc_tangnano9k #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115200,
    parameter PROG   = "programs/hello.hex",
    parameter DATA   = "programs/hello.data.hex"
)(
    input  wire       clk,         // 27 MHz on-board oscillator
    input  wire       btn_rst_n,   // reset button (active low)
    output wire       uart_tx_pin, // -> on-board USB-serial bridge (to your PC)
    // HD44780 LCD (4-bit) on the GPIO header
    output wire       lcd_rs,
    output wire       lcd_e,
    output wire [3:0] lcd_db,      // DB7..DB4
    output wire [5:0] led_n        // 6 on-board LEDs (active LOW)
);
    // ---- reset: power-on reset OR the button --------------------------------
    wire por_rst;
    por #(.CYCLES(64)) POR (.clk(clk), .rst(por_rst));
    wire rst = por_rst | ~btn_rst_n;

    // ---- the CPU ------------------------------------------------------------
    wire [31:0] pc, instr;
    wire        halted;
    wire        io_uart_we, io_lcd_we;
    wire [7:0]  io_wbyte;

    riscv_single #(.PROG(PROG), .DATA(DATA)) CPU (
        .clk(clk), .rst(rst),
        .pc_out(pc), .instr_out(instr), .halted(halted),
        .io_uart_we(io_uart_we), .io_lcd_we(io_lcd_we), .io_wbyte(io_wbyte)
    );

    // ---- UART path: CPU store -> FIFO -> transmitter ------------------------
    wire [7:0] tx_data;
    wire       tx_empty, tx_busy;
    wire       tx_go = ~tx_busy & ~tx_empty;   // start a byte whenever one's ready

    fifo #(.WIDTH(8), .DEPTH(512)) UART_FIFO (
        .clk(clk), .rst(rst),
        .wr(io_uart_we), .din(io_wbyte),
        .rd(tx_go), .dout(tx_data), .empty(tx_empty), .full(/*unused*/)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) UART (
        .clk(clk), .rst(rst),
        .wr(tx_go), .data(tx_data), .tx(uart_tx_pin), .busy(tx_busy)
    );

    // ---- LCD path: CPU store -> FIFO -> HD44780 driver ----------------------
    wire [7:0] lcd_char;
    wire       lcd_empty, lcd_busy;
    wire       lcd_go = ~lcd_busy & ~lcd_empty;

    fifo #(.WIDTH(8), .DEPTH(64)) LCD_FIFO (
        .clk(clk), .rst(rst),
        .wr(io_lcd_we), .din(io_wbyte),
        .rd(lcd_go), .dout(lcd_char), .empty(lcd_empty), .full(/*unused*/)
    );

    lcd_hd44780 #(.CLK_HZ(CLK_HZ)) LCD (
        .clk(clk), .rst(rst),
        .wr(lcd_go), .char(lcd_char), .busy(lcd_busy),
        .lcd_rs(lcd_rs), .lcd_e(lcd_e), .lcd_data(lcd_db)
    );

    // ---- LEDs: a heartbeat + a halt indicator -------------------------------
    //  A free-running counter's top bit gives a ~1 Hz blink so you can see the
    //  clock is live; the halt store lights LED0. led_n is active-low, so we
    //  invert. The remaining LEDs show the low bits of the PC (activity).
    reg [24:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1'b1;

    wire [5:0] led = {heartbeat[24], pc[6:3], halted};
    assign led_n = ~led;

endmodule
