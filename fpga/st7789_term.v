// Text terminal for a 1.14" 135x240 ST7789 SPI panel. Same wr/char/busy
// handshake as lcd_hd44780, so it slots into the SoC in its place. No
// framebuffer: each character is drawn straight into a CW x CH window
// (CASET/RASET/RAMWR, then one RGB565 pixel per font bit), which is why the
// only state is the cursor.
//
// The panel is run in landscape (240 wide x 135 tall), giving a 40 x 11
// grid with the 6x12 font in fpga/font6x12.hex (tools/genfont.py). '\n'
// returns to column 0 and moves down a row, '\r' just returns; other
// control bytes are ignored. Running off the bottom clears the screen and
// starts again at the top instead of scrolling.
//
// OFF_X / OFF_Y are where the 240x135 visible area sits inside the
// controller's 240x320 RAM. 40/53 and MADCTL 0x70 (landscape) match Sipeed's
// own example for the Tang Nano 9K's onboard screen connector. SPI is mode
// 0, write-only, CS held low.
module st7789_term #(
    parameter CLK_HZ  = 27_000_000,
    parameter SPI_DIV = 2,                  // clocks per SCLK half-period
    parameter OFF_X   = 40,
    parameter OFF_Y   = 53,
    parameter [15:0] FG = 16'hFFFF,
    parameter [15:0] BG = 16'h0000,
    parameter FONT    = "fpga/font6x12.hex"
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,
    input  wire [7:0] char,
    output wire       busy,
    output reg        lcd_sclk,
    output reg        lcd_mosi,
    output reg        lcd_dc,
    output wire       lcd_cs,
    output reg        lcd_rst_n,
    output wire       lcd_bl
);
    localparam CW = 6, CH = 12;
    localparam W = 240, H = 135;
    localparam COLS = W / CW;               // 40
    localparam ROWS = H / CH;               // 11
    localparam integer MS = CLK_HZ / 1000;

    assign lcd_cs = 1'b0;
    assign lcd_bl = 1'b1;

    // ---- SPI byte engine ----------------------------------------------------
    reg        tx_go;
    reg        tx_dc;
    reg  [7:0] tx_data;
    reg        spi_active;
    reg  [7:0] sh;
    reg  [3:0] bitcnt;
    reg  [$clog2(SPI_DIV)+1:0] dcnt;
    wire       spi_busy = spi_active | tx_go;

    always @(posedge clk) begin
        if (rst) begin
            spi_active <= 1'b0;
            lcd_sclk   <= 1'b0;
            lcd_mosi   <= 1'b0;
            lcd_dc     <= 1'b0;
            bitcnt     <= 4'd0;
            dcnt       <= 0;
        end else if (tx_go) begin
            sh         <= tx_data;
            lcd_dc     <= tx_dc;
            lcd_mosi   <= tx_data[7];
            lcd_sclk   <= 1'b0;
            spi_active <= 1'b1;
            bitcnt     <= 4'd0;
            dcnt       <= 0;
        end else if (spi_active) begin
            if (dcnt == SPI_DIV - 1) begin
                dcnt <= 0;
                if (!lcd_sclk) begin
                    lcd_sclk <= 1'b1;               // panel samples MOSI here
                end else begin
                    lcd_sclk <= 1'b0;
                    if (bitcnt == 4'd7) begin
                        spi_active <= 1'b0;
                    end else begin
                        bitcnt   <= bitcnt + 4'd1;
                        sh       <= {sh[6:0], 1'b0};
                        lcd_mosi <= sh[6];
                    end
                end
            end else begin
                dcnt <= dcnt + 1'b1;
            end
        end
    end

    // ---- power-on command sequence -------------------------------------------
    // {wait_sel, dc, byte}; wait_sel 1/2/3 = 150/120/20 ms after the byte
    localparam INIT_LEN = 9;
    function [10:0] init_rom(input [3:0] i);
        case (i)
            4'd0:    init_rom = {2'd1, 1'b0, 8'h01};   // SWRESET
            4'd1:    init_rom = {2'd2, 1'b0, 8'h11};   // SLPOUT
            4'd2:    init_rom = {2'd0, 1'b0, 8'h3A};   // COLMOD
            4'd3:    init_rom = {2'd0, 1'b1, 8'h55};   //   16 bpp (RGB565)
            4'd4:    init_rom = {2'd0, 1'b0, 8'h36};   // MADCTL
            4'd5:    init_rom = {2'd0, 1'b1, 8'h70};   //   landscape
            4'd6:    init_rom = {2'd0, 1'b0, 8'h21};   // INVON (IPS panels need it)
            4'd7:    init_rom = {2'd3, 1'b0, 8'h13};   // NORON
            default: init_rom = {2'd3, 1'b0, 8'h29};   // DISPON
        endcase
    endfunction

    function [23:0] wait_cycles(input [1:0] sel);
        case (sel)
            2'd1:    wait_cycles = MS * 150;
            2'd2:    wait_cycles = MS * 120;
            2'd3:    wait_cycles = MS * 20;
            default: wait_cycles = 0;
        endcase
    endfunction

    // ---- draw window: CASET, RASET, RAMWR ---------------------------------------
    reg [15:0] xs, xe, ys, ye;
    reg [3:0]  step;
    reg [8:0]  win_word;
    always @(*) begin
        case (step)
            4'd0:    win_word = {1'b0, 8'h2A};
            4'd1:    win_word = {1'b1, xs[15:8]};
            4'd2:    win_word = {1'b1, xs[7:0]};
            4'd3:    win_word = {1'b1, xe[15:8]};
            4'd4:    win_word = {1'b1, xe[7:0]};
            4'd5:    win_word = {1'b0, 8'h2B};
            4'd6:    win_word = {1'b1, ys[15:8]};
            4'd7:    win_word = {1'b1, ys[7:0]};
            4'd8:    win_word = {1'b1, ye[15:8]};
            4'd9:    win_word = {1'b1, ye[7:0]};
            default: win_word = {1'b0, 8'h2C};
        endcase
    end

    // ---- font ROM (synchronous read so it maps to block RAM) ---------------------
    reg [CW-1:0] font_mem [0:96*CH-1];
    initial $readmemh(FONT, font_mem);

    reg  [11:0]   font_base;
    reg  [3:0]    px_r, px_c;
    reg  [CW-1:0] font_q;
    always @(posedge clk) font_q <= font_mem[font_base + px_r];

    // ---- main FSM -------------------------------------------------------------------
    localparam S_RSTLO = 4'd0,  S_RSTHI = 4'd1,  S_INIT   = 4'd2,  S_INIT_W = 4'd3,
               S_INIT_D = 4'd4, S_IDLE  = 4'd5,  S_WIN    = 4'd6,  S_WIN_W  = 4'd7,
               S_PREP   = 4'd8, S_HI    = 4'd9,  S_HI_W   = 4'd10, S_LO     = 4'd11,
               S_LO_W   = 4'd12, S_DONE = 4'd13;

    reg [3:0]  state;
    reg [3:0]  idx;
    reg [23:0] dly;
    reg [5:0]  col;
    reg [3:0]  row;
    reg        is_char;
    reg [15:0] pix_left;

    assign busy = (state != S_IDLE);

    wire [10:0] init_word = init_rom(idx);
    wire        pix_on    = is_char & font_q[CW-1-px_c];
    wire [15:0] pix       = pix_on ? FG : BG;

    task start_clear;
        begin
            xs <= OFF_X;  xe <= OFF_X + W - 1;
            ys <= OFF_Y;  ye <= OFF_Y + H - 1;
            pix_left <= W * H;
            is_char  <= 1'b0;
            px_r     <= 4'd0;
            px_c     <= 4'd0;
            font_base <= 12'd0;
            step     <= 4'd0;
            state    <= S_WIN;
        end
    endtask

    task start_char(input [7:0] c);
        begin
            xs <= OFF_X + col * CW;  xe <= OFF_X + col * CW + CW - 1;
            ys <= OFF_Y + row * CH;  ye <= OFF_Y + row * CH + CH - 1;
            pix_left <= CW * CH;
            is_char  <= 1'b1;
            px_r     <= 4'd0;
            px_c     <= 4'd0;
            font_base <= (c - 8'h20) * CH;
            step     <= 4'd0;
            state    <= S_WIN;
        end
    endtask

    always @(posedge clk) begin
        tx_go <= 1'b0;
        if (rst) begin
            state     <= S_RSTLO;
            lcd_rst_n <= 1'b0;
            dly       <= MS * 10;
            idx       <= 4'd0;
            col       <= 6'd0;
            row       <= 4'd0;
            tx_go     <= 1'b0;
        end else begin
            case (state)
                S_RSTLO: begin
                    if (dly == 0) begin
                        lcd_rst_n <= 1'b1;
                        dly       <= MS * 120;
                        state     <= S_RSTHI;
                    end else dly <= dly - 24'd1;
                end
                S_RSTHI: begin
                    if (dly == 0) begin
                        idx   <= 4'd0;
                        state <= S_INIT;
                    end else dly <= dly - 24'd1;
                end

                S_INIT: begin
                    if (idx == INIT_LEN) begin
                        start_clear;
                    end else if (!spi_busy) begin
                        tx_go   <= 1'b1;
                        tx_dc   <= init_word[8];
                        tx_data <= init_word[7:0];
                        state   <= S_INIT_W;
                    end
                end
                S_INIT_W: begin
                    if (!spi_busy) begin
                        if (init_word[10:9] != 2'd0) begin
                            dly   <= wait_cycles(init_word[10:9]);
                            state <= S_INIT_D;
                        end else begin
                            idx   <= idx + 4'd1;
                            state <= S_INIT;
                        end
                    end
                end
                S_INIT_D: begin
                    if (dly == 0) begin
                        idx   <= idx + 4'd1;
                        state <= S_INIT;
                    end else dly <= dly - 24'd1;
                end

                S_IDLE: begin
                    if (wr) begin
                        if (char == 8'h0A) begin
                            col <= 6'd0;
                            if (row == ROWS - 1) begin
                                row <= 4'd0;
                                start_clear;
                            end else row <= row + 4'd1;
                        end else if (char == 8'h0D) begin
                            col <= 6'd0;
                        end else if (char >= 8'h20 && char <= 8'h7E) begin
                            start_char(char);
                        end
                    end
                end

                S_WIN: begin
                    if (!spi_busy) begin
                        tx_go   <= 1'b1;
                        tx_dc   <= win_word[8];
                        tx_data <= win_word[7:0];
                        state   <= S_WIN_W;
                    end
                end
                S_WIN_W: begin
                    if (!spi_busy) begin
                        if (step == 4'd10) state <= S_PREP;
                        else begin
                            step  <= step + 4'd1;
                            state <= S_WIN;
                        end
                    end
                end

                // one idle cycle so font_q catches up after px_r changes
                S_PREP: state <= S_HI;

                S_HI: begin
                    if (!spi_busy) begin
                        tx_go   <= 1'b1;
                        tx_dc   <= 1'b1;
                        tx_data <= pix[15:8];
                        state   <= S_HI_W;
                    end
                end
                S_HI_W: if (!spi_busy) state <= S_LO;
                S_LO: begin
                    if (!spi_busy) begin
                        tx_go   <= 1'b1;
                        tx_dc   <= 1'b1;
                        tx_data <= pix[7:0];
                        state   <= S_LO_W;
                    end
                end
                S_LO_W: begin
                    if (!spi_busy) begin
                        if (pix_left == 16'd1) begin
                            state <= S_DONE;
                        end else begin
                            pix_left <= pix_left - 16'd1;
                            if (px_c == CW - 1) begin
                                px_c <= 4'd0;
                                px_r <= px_r + 4'd1;
                            end else px_c <= px_c + 4'd1;
                            state <= S_PREP;
                        end
                    end
                end

                S_DONE: begin
                    if (!is_char) begin
                        state <= S_IDLE;
                    end else if (col == COLS - 1) begin
                        col <= 6'd0;
                        if (row == ROWS - 1) begin
                            row <= 4'd0;
                            start_clear;
                        end else begin
                            row   <= row + 4'd1;
                            state <= S_IDLE;
                        end
                    end else begin
                        col   <= col + 6'd1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
