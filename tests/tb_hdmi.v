// Checks hdmi_term the way a TV would see it: decodes the three TMDS symbol
// streams with an independent DVI decoder (written from the spec, not
// shared with the encoder), then checks
//   - frame geometry: 640x480 active, 800x525 total, porches and sync pulse
//     widths, vsync edges landing on hsync edges, frame length
//   - DC balance: running disparity stays bounded during video
//   - every pixel of a whole frame against a reference grid rendered from
//     the font file, after writes that exercise newline, CR, ignored
//     control bytes, end-of-line wrap and end-of-screen clear.
`timescale 1ns/1ps

module tb_hdmi;
    localparam S = 1;                       // matches SCALE=2
    localparam COLS = 40, ROWS = 15;

    reg clk = 0, pclk = 0, rst = 1, wr = 0;
    reg [7:0] ch;
    wire busy;
    wire [9:0] tr, tg, tb;

    hdmi_term #(.SCALE(2)) DUT (
        .clk(clk), .rst(rst), .wr(wr), .char(ch), .busy(busy),
        .pclk(pclk), .tmds_r(tr), .tmds_g(tg), .tmds_b(tb));

    always #10 clk  = ~clk;    // CPU clock at half the pixel clock, as on the board
    always #5  pclk = ~pclk;

    reg [7:0] gfont [0:1535];
    reg [7:0] grid  [0:ROWS-1][0:COLS-1];
    integer   gcol = 0, grow = 0, errors = 0;

    // ---- reference terminal model ------------------------------------------
    task model_clear;
        integer r, c;
        begin
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1) grid[r][c] = 8'h20;
        end
    endtask

    task model_newline;
        begin
            gcol = 0;
            if (grow == ROWS - 1) begin grow = 0; model_clear; end
            else grow = grow + 1;
        end
    endtask

    task put(input [7:0] c);
        begin
            wait (!busy);
            @(posedge clk); ch <= c; wr <= 1'b1;
            @(posedge clk); wr <= 1'b0;
            @(posedge clk);
            if (c == 8'h0A) model_newline;
            else if (c == 8'h0D) gcol = 0;
            else if (c >= 8'h20 && c <= 8'h7E) begin
                grid[grow][gcol] = c;
                if (gcol == COLS - 1) model_newline;
                else gcol = gcol + 1;
            end
        end
    endtask

    // ---- independent TMDS decoder ------------------------------------------
    function is_ctrl(input [9:0] s);
        is_ctrl = (s == 10'b1101010100) || (s == 10'b0010101011) ||
                  (s == 10'b0101010100) || (s == 10'b1010101011);
    endfunction

    function [1:0] ctrl_bits(input [9:0] s);
        case (s)
            10'b1101010100: ctrl_bits = 2'b00;
            10'b0010101011: ctrl_bits = 2'b01;
            10'b0101010100: ctrl_bits = 2'b10;
            default:        ctrl_bits = 2'b11;
        endcase
    endfunction

    function [7:0] dec(input [9:0] s);
        reg [7:0] d;
        integer i;
        begin
            d = s[9] ? ~s[7:0] : s[7:0];
            dec[0] = d[0];
            for (i = 1; i < 8; i = i + 1)
                dec[i] = s[8] ? (d[i] ^ d[i-1]) : ~(d[i] ^ d[i-1]);
        end
    endfunction

    function integer disp(input [9:0] s);   // ones - zeros
        integer i;
        begin
            disp = 0;
            for (i = 0; i < 10; i = i + 1) disp = disp + (s[i] ? 1 : -1);
        end
    endfunction

    // ---- stream checker ------------------------------------------------------
    reg      checking = 0, frame_done = 0;
    reg      in_frame = 0;
    reg      de_p = 0, hs_p = 1, vs_p = 1;
    integer  t = 0, t_de_rise = 0, t_de_fall = 0, t_hs_fall = 0, t_hs_rise = 0, t_vs_fall = 0;
    integer  x = 0, y = 0, lines = 0, frame_err = 0, d_r, d_g, d_b, max_disp = 0;

    // only count errors inside a frame being checked; the stream before the
    // checker has locked onto a frame boundary isn't meaningful
    task ferr(input [8*48-1:0] msg);
        begin
            if (in_frame) begin
                if (frame_err < 8) $display("  FAIL  %0s (t=%0d y=%0d x=%0d)", msg, t, y, x);
                frame_err = frame_err + 1;
            end
        end
    endtask

    always @(posedge pclk) begin : chk
        reg de, hs, vs;
        reg [1:0] cb;
        reg [7:0] r8, g8, b8, ch_at, want;
        de = !is_ctrl(tb);
        cb = ctrl_bits(tb);
        hs = de ? hs_p : cb[0];
        vs = de ? vs_p : cb[1];
        t  = t + 1;

        if (de && (is_ctrl(tr) || is_ctrl(tg))) ferr("channels disagree on video period");
        if (!de && (!is_ctrl(tr) || !is_ctrl(tg) || ctrl_bits(tr) != 0 || ctrl_bits(tg) != 0))
            ferr("bad control token on red/green");

        // vsync fall = frame boundary
        if (vs_p && !vs) begin
            if (in_frame) begin
                if (lines != 480) ferr("active line count != 480");
                if (t - t_vs_fall != 420000) ferr("frame length != 800*525");
                in_frame   = 0;
                checking   = 0;
                frame_done = 1;
            end
            if (checking && !frame_done) begin
                in_frame = 1; lines = 0; frame_err = 0; y = -1;
            end
            if (!(hs_p && !hs)) ferr("vsync fall not on an hsync fall");
            // last active line ends at x=640 of line 479; vsync starts at
            // x=656 of line 490 (10 blank lines of front porch in between)
            if (t - t_de_fall != 11*800 + 16) ferr("vertical front porch != 10 lines");
            t_vs_fall = t;
        end
        if (!vs_p && vs) begin
            if (t - t_vs_fall != 1600) ferr("vsync pulse != 2 lines");
            if (!(hs_p && !hs)) ferr("vsync rise not on an hsync fall");
        end

        // horizontal
        if (!de_p && de) begin
            if (in_frame && lines > 0 && t - t_de_rise != 800) ferr("line length != 800");
            if (t - t_hs_rise != 48) ferr("horizontal back porch != 48");
            t_de_rise = t; x = 0; y = y + 1;
            if (in_frame) lines = lines + 1;
            d_r = 0; d_g = 0; d_b = 0;
        end
        if (de_p && !de) begin
            if (t - t_de_rise != 640) ferr("active width != 640");
            t_de_fall = t;
        end
        if (hs_p && !hs) begin
            if (t - t_hs_fall != 800) ferr("hsync period != 800");
            if (y < 479 && t - t_de_fall != 16 && lines > 0 && t - t_de_fall < 800)
                ferr("horizontal front porch != 16");
            t_hs_fall = t;
        end
        if (!hs_p && hs) begin
            if (t - t_hs_fall != 96) ferr("hsync pulse != 96");
            t_hs_rise = t;
        end

        if (de) begin
            d_r = d_r + disp(tr); d_g = d_g + disp(tg); d_b = d_b + disp(tb);
            if (d_r > max_disp) max_disp = d_r;  if (-d_r > max_disp) max_disp = -d_r;
            if (d_g > max_disp) max_disp = d_g;  if (-d_g > max_disp) max_disp = -d_g;
            if (d_b > max_disp) max_disp = d_b;  if (-d_b > max_disp) max_disp = -d_b;

            if (in_frame) begin
                r8 = dec(tr); g8 = dec(tg); b8 = dec(tb);
                ch_at = grid[y >> (4 + S)][x >> (3 + S)];
                want  = gfont[(ch_at - 8'h20) * 16 + ((y >> S) & 15)][7 - ((x >> S) & 7)] ? 8'hFF : 8'h00;
                if (r8 !== want || g8 !== want || b8 !== want) ferr("pixel mismatch");
            end
            x = x + 1;
        end

        de_p = de; hs_p = hs; vs_p = vs;
    end

    task check_frame(input [8*64-1:0] label);
        begin
            frame_done = 0;
            checking   = 1;
            wait (frame_done);
            if (frame_err == 0) $display("  PASS  %0s", label);
            else begin
                $display("  FAIL  %0s: %0d errors", label, frame_err);
                errors = errors + 1;
            end
        end
    endtask

    integer i;
    initial begin
        $readmemh("fpga/font8x16.hex", gfont);
        model_clear;
        repeat (4) @(posedge clk); rst = 0;
        $display("---- HDMI text terminal ----");
        @(posedge clk); wait (!busy);

        check_frame("blank screen after reset: geometry, sync, every pixel");

        put("A"); put("B"); put(8'h0A); put("C"); put(8'h07); put(8'h0D); put("D");
        for (i = 0; i < 39; i = i + 1) put("x");      // fills row 1, then wraps
        put("Q");
        check_frame("text frame: newline, CR, ignored control byte, line wrap");

        for (i = 0; i < 12; i = i + 1) put(8'h0A);    // down to the last row
        put("E");
        check_frame("text on the last row");

        put(8'h0A);                                   // off the bottom: clear
        put("F");
        check_frame("end of screen clears and restarts at the top");

        if (max_disp > 16) begin
            $display("  FAIL  running disparity reached %0d", max_disp);
            errors = errors + 1;
        end else $display("  PASS  DC balance: running disparity stayed within +/-%0d", max_disp);

        if (errors == 0) $display("RESULT: ALL HDMI TESTS PASSED");
        else             $display("RESULT: %0d HDMI TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("RESULT: TIMEOUT");
        $finish;
    end
endmodule
