// Top level for the Tang Nano 9K: the CPU plus UART (through a FIFO so
// bursts don't drop bytes), a text terminal on the HDMI port for whatever
// the program writes to the LCD device, and status LEDs. Clocks come from
// the on-chip PLL (see the clock note below). Pins map to physical balls in fpga/tangnano9k.cst -- see docs/FPGA.md for bring-up order
// (blink an LED first to prove the toolchain/pin map before trusting this).
`include "defines.vh"

module soc_tangnano9k #(
    parameter CLK_HZ = 12_600_000,   // CPU/system clock (from the PLL on the board)
    parameter BAUD   = 115200,
    parameter PROG   = "programs/hello.hex",
    parameter DATA   = "programs/hello.data.hex",
    // the demos need <64 instructions and <64 words of data; programs sent
    // with tools/load.py must fit in these too
    parameter IMEM_WORDS = 128,
    parameter DMEM_WORDS = 64
)(
    input  wire       clk_in,      // 27 MHz on-board oscillator
    input  wire       btn_rst_n,   // reset button S1 (active low)
    output wire       uart_tx_pin, // -> on-board USB-serial bridge (to your PC)
    input  wire       uart_rx_pin, // <- the same bridge; carries uart_loader packets
    // HDMI port (DVI signalling), differential pairs
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire [5:0] led_n        // 6 on-board LEDs (active LOW)
);
    // Clocks, all from one PLL:
    //   126 MHz  = 27 * 14 / 3      HDMI serializers (10 bits per pixel, DDR)
    //   25.2 MHz = 126 / 5          pixel clock for 640x480 @ 60
    //   12.6 MHz = 126 / 10         CPU and everything else
    // The CPU can't run at the crystal's 27 MHz: its worst path is a load
    // (instruction ROM -> regfile -> address add -> data LUT-RAM read ->
    // register write), which is too slow on the real chip -- loaded bytes
    // came back with a flipped bit -- and nextpnr can't see it, because it
    // has no timing for the LUT-RAM read and reports ~32 MHz regardless.
    // In simulation clk_in drives everything directly.
    wire clk, pclk, clk_ser, pll_lock;
`ifdef SYNTHESIS
    rPLL #(
        .FCLKIN("27"), .IDIV_SEL(2), .FBDIV_SEL(13), .ODIV_SEL(4),
        .DYN_SDIV_SEL(10), .CLKOUTD_SRC("CLKOUT"),
        .DEVICE("GW1N-9C")
    ) PLL (
        .CLKIN(clk_in), .CLKOUT(clk_ser), .CLKOUTD(clk), .LOCK(pll_lock),
        .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
        .CLKOUTP(), .CLKOUTD3()
    );
    CLKDIV #(.DIV_MODE("5")) PIXDIV (
        .HCLKIN(clk_ser), .RESETN(pll_lock), .CALIB(1'b0), .CLKOUT(pclk)
    );
`else
    assign clk      = clk_in;
    assign pclk     = clk_in;
    assign clk_ser  = 1'b0;
    assign pll_lock = 1'b1;
`endif

    wire por_rst;
    por #(.CYCLES(64)) POR (.clk(clk), .rst(por_rst));
    wire rst = por_rst | ~btn_rst_n | ~pll_lock;

    // Program loading over the UART (tools/load.py). While a packet comes in
    // the loader holds the CPU -- and the screen, so it starts out clear --
    // in reset; the UART transmit side stays up so it can reply.
    wire [7:0]  rx_byte;
    wire        rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) URX (
        .clk(clk), .rst(rst), .rx(uart_rx_pin), .data(rx_byte), .valid(rx_valid));

    wire        ld_hold, ld_imem_we, ld_dmem_we, ld_ack_we;
    wire [31:0] ld_addr, ld_data;
    wire [7:0]  ld_ack_byte;
    uart_loader #(.CLK_HZ(CLK_HZ), .IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS)) LOADER (
        .clk(clk), .rst(rst), .rx_valid(rx_valid), .rx_data(rx_byte),
        .hold(ld_hold), .imem_we(ld_imem_we), .dmem_we(ld_dmem_we),
        .addr(ld_addr), .wdata(ld_data), .ack_we(ld_ack_we), .ack_byte(ld_ack_byte));

    wire cpu_rst = rst | ld_hold;

    wire [31:0] pc, instr;
    wire        halted;
    wire        io_uart_we, io_lcd_we;
    wire [7:0]  io_wbyte;

    // divides run in the bit-serial unit instead of the ALU (see riscv_single)
    riscv_single #(.PROG(PROG), .DATA(DATA),
                   .IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS), .SEQ_DIV(1)) CPU (
        .clk(clk), .rst(cpu_rst),
        .pc_out(pc), .instr_out(instr), .halted(halted),
        .io_uart_we(io_uart_we), .io_lcd_we(io_lcd_we), .io_wbyte(io_wbyte),
        .ld_imem_we(ld_imem_we), .ld_dmem_we(ld_dmem_we), .ld_addr(ld_addr), .ld_data(ld_data)
    );

    // CPU store -> FIFO -> transmitter
    wire [7:0] tx_data;
    wire       tx_empty, tx_busy;
    wire       tx_go = ~tx_busy & ~tx_empty;   // start a byte whenever one's ready

    fifo #(.WIDTH(8), .DEPTH(512)) UART_FIFO (
        .clk(clk), .rst(rst),
        .wr(io_uart_we | ld_ack_we), .din(ld_ack_we ? ld_ack_byte : io_wbyte),
        .rd(tx_go), .dout(tx_data), .empty(tx_empty), .full(/*unused*/)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) UART (
        .clk(clk), .rst(rst),
        .wr(tx_go), .data(tx_data), .tx(uart_tx_pin), .busy(tx_busy)
    );

    // LCD device -> FIFO -> HDMI text terminal
    wire [7:0] lcd_char;
    wire       lcd_empty, lcd_busy;
    wire       lcd_go = ~lcd_busy & ~lcd_empty;

    fifo #(.WIDTH(8), .DEPTH(256)) LCD_FIFO (
        .clk(clk), .rst(cpu_rst),
        .wr(io_lcd_we), .din(io_wbyte),
        .rd(lcd_go), .dout(lcd_char), .empty(lcd_empty), .full(/*unused*/)
    );

    wire [9:0] sym_r, sym_g, sym_b;
    hdmi_term #(.SCALE(2)) SCREEN (
        .clk(clk), .rst(cpu_rst),
        .wr(lcd_go), .char(lcd_char), .busy(lcd_busy),
        .pclk(pclk), .tmds_r(sym_r), .tmds_g(sym_g), .tmds_b(sym_b)
    );

    // 10:1 serializers, bit 0 first, then the board's differential outputs.
    // DVI channel 0 is blue (it also carries hsync/vsync), 1 green, 2 red;
    // the clock pair just carries the pixel clock itself.
`ifdef SYNTHESIS
    wire [9:0] sym [0:2];
    assign sym[0] = sym_b;
    assign sym[1] = sym_g;
    assign sym[2] = sym_r;
    wire [2:0] ser;
    genvar ch;
    generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_ser
        OSER10 SER (
            .Q(ser[ch]),
            .D0(sym[ch][0]), .D1(sym[ch][1]), .D2(sym[ch][2]), .D3(sym[ch][3]),
            .D4(sym[ch][4]), .D5(sym[ch][5]), .D6(sym[ch][6]), .D7(sym[ch][7]),
            .D8(sym[ch][8]), .D9(sym[ch][9]),
            .PCLK(pclk), .FCLK(clk_ser), .RESET(~pll_lock)
        );
        ELVDS_OBUF OUT (.I(ser[ch]), .O(tmds_d_p[ch]), .OB(tmds_d_n[ch]));
    end endgenerate
    ELVDS_OBUF CLKOUT (.I(pclk), .O(tmds_clk_p), .OB(tmds_clk_n));
`else
    assign tmds_d_p = 3'b000;  assign tmds_d_n = 3'b111;
    assign tmds_clk_p = 1'b0;  assign tmds_clk_n = 1'b1;
`endif

    // LEDs, left to right as the chain a printed character travels:
    //   0 halted (program reached its HALT store)
    //   1 a UART store happened      2 the FIFO held a byte
    //   3 the transmitter started    4 CPU out of reset
    //   5 ~1 Hz heartbeat
    // 1-3 are sticky so a one-off event stays visible; they clear on reset.
    reg [24:0] heartbeat = 0;
    always @(posedge clk) heartbeat <= heartbeat + 1'b1;

    reg seen_we = 0, seen_fifo = 0, seen_tx = 0;
    always @(posedge clk) begin
        if (cpu_rst) begin
            seen_we <= 1'b0; seen_fifo <= 1'b0; seen_tx <= 1'b0;
        end else begin
            if (io_uart_we) seen_we   <= 1'b1;
            if (!tx_empty)  seen_fifo <= 1'b1;
            if (tx_busy)    seen_tx   <= 1'b1;
        end
    end

    wire [5:0] led = {heartbeat[24], ~cpu_rst, seen_tx, seen_fifo, seen_we, halted};
    assign led_n = ~led;

endmodule
