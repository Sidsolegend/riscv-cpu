// Snoops the SPI pins the way the panel would (sample MOSI on each rising
// SCLK edge, DC alongside) and checks the init bytes, the screen clear,
// and every pixel of a drawn character against the font file, plus
// newline, end-of-line wrap and end-of-screen wrap.
`timescale 1ns/1ps

module tb_st7789;
    reg        clk = 0, rst = 1, wr = 0;
    reg  [7:0] ch;
    wire       busy, sclk, mosi, dc, cs, rst_n, bl;

    st7789_term #(.CLK_HZ(20_000), .SPI_DIV(1)) DUT (
        .clk(clk), .rst(rst), .wr(wr), .char(ch), .busy(busy),
        .lcd_sclk(sclk), .lcd_mosi(mosi), .lcd_dc(dc), .lcd_cs(cs),
        .lcd_rst_n(rst_n), .lcd_bl(bl));

    always #5 clk = ~clk;

    reg [8:0] mon [0:262143];     // {dc, byte}
    integer   mon_n = 0;
    reg [7:0] shreg;
    integer   nbits = 0;
    always @(posedge sclk) begin
        shreg = {shreg[6:0], mosi};
        nbits = nbits + 1;
        if (nbits == 8) begin
            mon[mon_n] = {dc, shreg};
            mon_n = mon_n + 1;
            nbits = 0;
        end
    end

    reg [5:0] gfont [0:1151];
    integer errors = 0;

    task fail(input [255:0] msg);
        begin
            $display("  FAIL  %0s", msg);
            errors = errors + 1;
        end
    endtask

    task put(input [7:0] c);
        begin
            wait (!busy);
            @(posedge clk); ch <= c; wr <= 1'b1;
            @(posedge clk); wr <= 1'b0;
            #1;
            wait (!busy);
        end
    endtask

    task expect_byte(input integer i, input d, input [7:0] b);
        begin
            if (mon[i] !== {d, b}) begin
                $display("  FAIL  byte %0d = %03x (want %03x)", i, mon[i], {d, b});
                errors = errors + 1;
            end
        end
    endtask

    task check_window(input integer base, input [15:0] xs, xe, ys, ye);
        begin
            expect_byte(base + 0,  1'b0, 8'h2A);
            expect_byte(base + 1,  1'b1, xs[15:8]);
            expect_byte(base + 2,  1'b1, xs[7:0]);
            expect_byte(base + 3,  1'b1, xe[15:8]);
            expect_byte(base + 4,  1'b1, xe[7:0]);
            expect_byte(base + 5,  1'b0, 8'h2B);
            expect_byte(base + 6,  1'b1, ys[15:8]);
            expect_byte(base + 7,  1'b1, ys[7:0]);
            expect_byte(base + 8,  1'b1, ye[15:8]);
            expect_byte(base + 9,  1'b1, ye[7:0]);
            expect_byte(base + 10, 1'b0, 8'h2C);
        end
    endtask

    task check_clear(input integer base);
        integer i, bad;
        begin
            check_window(base, 16'd40, 16'd279, 16'd53, 16'd187);
            bad = 0;
            for (i = 0; i < 64800; i = i + 1)
                if (mon[base + 11 + i] !== 9'h100) bad = bad + 1;
            if (bad != 0 || mon_n - base != 11 + 64800) begin
                $display("  FAIL  clear: %0d bad bytes, %0d total (want 64811)", bad, mon_n - base);
                errors = errors + 1;
            end else $display("  PASS  screen clear: 240x135 window, 32400 black pixels");
        end
    endtask

    task check_char(input integer base, input [7:0] c, input integer col, row);
        integer p, r, cc, bad;
        reg [15:0] want;
        begin
            check_window(base, 40 + col * 6, 40 + col * 6 + 5, 53 + row * 12, 53 + row * 12 + 11);
            bad = 0;
            for (p = 0; p < 72; p = p + 1) begin
                r  = p / 6;
                cc = p % 6;
                want = gfont[(c - 32) * 12 + r][5 - cc] ? 16'hFFFF : 16'h0000;
                if (mon[base + 11 + 2*p] !== {1'b1, want[15:8]} ||
                    mon[base + 12 + 2*p] !== {1'b1, want[7:0]}) bad = bad + 1;
            end
            if (bad != 0 || mon_n - base != 155) begin
                $display("  FAIL  '%0s' at (%0d,%0d): %0d bad pixel bytes, %0d bytes (want 155)",
                         c, col, row, bad, mon_n - base);
                errors = errors + 1;
            end else $display("  PASS  '%0s' drawn at col %0d row %0d, all 72 pixels match the font", c, col, row);
        end
    endtask

    integer base, i;
    initial begin
        $readmemh("fpga/font6x12.hex", gfont);
        repeat (4) @(posedge clk); rst = 0;
        $display("---- ST7789 SPI text terminal ----");

        #1000;
        wait (busy);
        wait (!busy);

        expect_byte(0, 1'b0, 8'h01);
        expect_byte(1, 1'b0, 8'h11);
        expect_byte(2, 1'b0, 8'h3A);
        expect_byte(3, 1'b1, 8'h55);
        expect_byte(4, 1'b0, 8'h36);
        expect_byte(5, 1'b1, 8'h70);
        expect_byte(6, 1'b0, 8'h21);
        expect_byte(7, 1'b0, 8'h13);
        expect_byte(8, 1'b0, 8'h29);
        if (errors == 0) $display("  PASS  init command sequence");
        check_clear(9);

        base = mon_n; put("A"); check_char(base, "A", 0, 0);
        base = mon_n; put("h"); check_char(base, "h", 1, 0);

        put(8'h0A);                                   // newline: back to col 0, next row
        base = mon_n; put("B"); check_char(base, "B", 0, 1);

        base = mon_n; put(8'h07); put(8'h0D);         // ignored control byte, then CR
        if (mon_n != base) fail("control bytes must not draw");
        base = mon_n; put("C"); check_char(base, "C", 0, 1);

        for (i = 0; i < 38; i = i + 1) put("x");      // fill the rest of row 1 (cols 1..38)
        base = mon_n; put("Z"); check_char(base, "Z", 39, 1);
        base = mon_n; put("Q"); check_char(base, "Q", 0, 2);   // wrapped to the next row

        for (i = 0; i < 8; i = i + 1) put(8'h0A);     // rows 3..10
        base = mon_n; put("E"); check_char(base, "E", 0, 10);

        base = mon_n; put(8'h0A);                     // off the bottom: clear, back to row 0
        check_clear(base);
        base = mon_n; put("F"); check_char(base, "F", 0, 0);

        if (errors == 0) $display("RESULT: ALL ST7789 TESTS PASSED");
        else             $display("RESULT: %0d ST7789 TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("RESULT: TIMEOUT");
        $finish;
    end
endmodule
