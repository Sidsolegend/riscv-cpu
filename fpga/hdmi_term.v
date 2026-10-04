// Text terminal on HDMI (strictly DVI: video only, no audio/data islands,
// which every HDMI TV still accepts). 640x480 @ 60 Hz, 8x16 font, drawn at
// SCALE x size: SCALE=2 gives 40x15 big characters, readable on a TV
// across the room; SCALE=1 gives the classic 80x30.
//
// Two clock domains, joined only by the character buffer (a dual-clock
// block RAM, no other crossing):
//   clk  - CPU side. Same wr/char/busy handshake as st7789_term / the
//          HD44780 driver. '\n' = new line, '\r' = column 0, other control
//          bytes ignored. Off the bottom, the screen clears and starts over
//          at the top (no scrolling), like the other terminals here.
//   pclk - 25.2 MHz pixel clock. Outputs one 10-bit TMDS symbol per channel
//          per pixel (bit 0 is sent first); the board top level serializes
//          them with OSER10s at 10x. Nothing Gowin-specific lives in here,
//          so it simulates as plain Verilog.
module hdmi_term #(
    parameter SCALE = 2,                    // 1 or 2
    parameter [23:0] FG = 24'hFFFFFF,       // {R, G, B}
    parameter [23:0] BG = 24'h000000,
    parameter FONT = "fpga/font8x16.hex"
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,
    input  wire [7:0] char,
    output wire       busy,

    input  wire       pclk,
    output reg  [9:0] tmds_r,
    output reg  [9:0] tmds_g,
    output reg  [9:0] tmds_b
);
    localparam S    = (SCALE == 2) ? 1 : 0;
    localparam COLS = 640 >> (3 + S);
    localparam ROWS = 480 >> (4 + S);
    localparam CELLS = COLS * ROWS;
    localparam AW   = $clog2(CELLS);

    // 640x480 @ 60: 800x525 total, sync pulses active low
    localparam H_VIS = 640, H_FP = 16, H_SYNC = 96, H_TOT = 800;
    localparam V_VIS = 480, V_FP = 10, V_SYNC = 2,  V_TOT = 525;

    // ---- character buffer --------------------------------------------------
    reg [7:0] cbuf [0:CELLS-1];
    reg [AW-1:0] waddr;
    reg [7:0]    wdata;
    reg          we;
    always @(posedge clk) if (we) cbuf[waddr] <= wdata;

    reg [AW-1:0] raddr;
    reg [7:0]    rchar;
    always @(posedge pclk) rchar <= cbuf[raddr];

    // ---- terminal state (CPU clock) -----------------------------------------
    reg [6:0]    col;
    reg [4:0]    row;
    reg          clearing;
    reg [AW-1:0] clr_addr;

    assign busy = clearing;

    wire [AW-1:0] cur_addr = row * COLS + col;

    always @(posedge clk) begin
        we <= 1'b0;
        if (rst) begin
            col      <= 0;
            row      <= 0;
            clearing <= 1'b1;
            clr_addr <= 0;
        end else if (clearing) begin
            we       <= 1'b1;
            waddr    <= clr_addr;
            wdata    <= 8'h20;
            if (clr_addr == CELLS - 1) clearing <= 1'b0;
            clr_addr <= clr_addr + 1'b1;
        end else if (wr) begin
            if (char == 8'h0A) begin
                col <= 0;
                if (row == ROWS - 1) begin
                    row      <= 0;
                    clearing <= 1'b1;
                    clr_addr <= 0;
                end else row <= row + 1'b1;
            end else if (char == 8'h0D) begin
                col <= 0;
            end else if (char >= 8'h20 && char <= 8'h7E) begin
                we    <= 1'b1;
                waddr <= cur_addr;
                wdata <= char;
                if (col == COLS - 1) begin
                    col <= 0;
                    if (row == ROWS - 1) begin
                        row      <= 0;
                        clearing <= 1'b1;
                        clr_addr <= 0;
                    end else row <= row + 1'b1;
                end else col <= col + 1'b1;
            end
        end
    end

    // ---- video timing (pixel clock) -----------------------------------------
    reg [9:0] hx = 0, vy = 0;
    always @(posedge pclk) begin
        if (hx == H_TOT - 1) begin
            hx <= 0;
            vy <= (vy == V_TOT - 1) ? 10'd0 : vy + 1'b1;
        end else hx <= hx + 1'b1;
    end

    // vsync starts and ends together with an hsync pulse, per VESA, rather
    // than at the start of the line -- some older TVs are picky about it
    localparam HS_AT = H_VIS + H_FP, VS_AT = V_VIS + V_FP;
    wire de0 = (hx < H_VIS) && (vy < V_VIS);
    wire hs0 = ~((hx >= HS_AT) && (hx < HS_AT + H_SYNC));
    wire vs0 = ~(  (vy == VS_AT && hx >= HS_AT)
                || (vy >  VS_AT && vy < VS_AT + V_SYNC)
                || (vy == VS_AT + V_SYNC && hx < HS_AT));

    // pipeline: 0 addr -> 1 char -> 2 font row -> 3 TMDS symbol. Everything
    // that describes "this pixel" travels alongside so it lines up again.
    always @(*) raddr = (vy >> (4 + S)) * COLS + (hx >> (3 + S));

    reg [7:0] font [0:96*16-1];
    initial $readmemh(FONT, font);

    reg [3:0] gy1;
    reg [2:0] gx1, gx2;
    reg       de1, hs1, vs1, de2, hs2, vs2;
    reg [7:0] frow2;

    always @(posedge pclk) begin
        gy1 <= vy[3+S:S];
        gx1 <= hx[2+S:S];
        de1 <= de0;  hs1 <= hs0;  vs1 <= vs0;

        frow2 <= font[{(rchar >= 8'h20 && rchar <= 8'h7F) ? rchar[6:0] - 7'h20 : 7'd0, gy1}];
        gx2   <= gx1;
        de2   <= de1;  hs2 <= hs1;  vs2 <= vs1;
    end

    wire [23:0] rgb = frow2[3'd7 - gx2] ? FG : BG;

    wire [9:0] sym_r, sym_g, sym_b;
    tmds_enc ENC_R (.clk(pclk), .de(de2), .d(rgb[23:16]), .c(2'b00),     .q(sym_r));
    tmds_enc ENC_G (.clk(pclk), .de(de2), .d(rgb[15:8]),  .c(2'b00),     .q(sym_g));
    tmds_enc ENC_B (.clk(pclk), .de(de2), .d(rgb[7:0]),   .c({vs2, hs2}), .q(sym_b));

    always @(*) begin
        tmds_r = sym_r;
        tmds_g = sym_g;
        tmds_b = sym_b;
    end
endmodule

// DVI 1.0 TMDS encoder: 8b -> 10b with transition minimisation and running
// DC balance during video, one of four control tokens during blanking.
// Registered output, one pixel clock of latency.
module tmds_enc (
    input  wire       clk,
    input  wire       de,
    input  wire [7:0] d,
    input  wire [1:0] c,
    output reg  [9:0] q
);
    function [3:0] ones8(input [7:0] v);
        integer i;
        begin
            ones8 = 0;
            for (i = 0; i < 8; i = i + 1) ones8 = ones8 + v[i];
        end
    endfunction

    wire [3:0] n1d    = ones8(d);
    wire       use_xn = (n1d > 4) || (n1d == 4 && !d[0]);

    reg [8:0] qm;
    integer k;
    always @(*) begin
        qm[0] = d[0];
        for (k = 1; k < 8; k = k + 1)
            qm[k] = use_xn ? ~(qm[k-1] ^ d[k]) : (qm[k-1] ^ d[k]);
        qm[8] = ~use_xn;
    end

    wire [3:0] n1q = ones8(qm[7:0]);
    wire signed [4:0] diff = $signed({1'b0, n1q}) - $signed(5'd4);   // (ones - zeros) / 2

    reg signed [4:0] cnt = 0;   // running disparity / 2

    always @(posedge clk) begin
        if (!de) begin
            cnt <= 0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || diff == 0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + qm[8] - diff;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - !qm[8] + diff;
        end
    end
endmodule
