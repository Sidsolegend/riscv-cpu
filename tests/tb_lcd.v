// ============================================================================
//  tb_lcd.v  —  self-checking test for the HD44780 LCD driver
// ----------------------------------------------------------------------------
//  Can't attach a real panel in simulation, so instead we verify the part that
//  actually has logic: after the init sequence completes (busy falls), sending
//  a character must clock out its HIGH nibble then its LOW nibble, each with
//  RS=1 (data) and each latched by a rising edge on E. We snoop the E strobe
//  and check the (rs, nibble) pairs. Uses a tiny CLK_HZ so the datasheet delays
//  collapse to a few cycles.
// ============================================================================
`timescale 1ns/1ps

module tb_lcd;
    reg        clk = 0, rst = 1, wr = 0;
    reg  [7:0] ch;
    wire       busy, lcd_rs, lcd_e;
    wire [3:0] lcd_data;

    lcd_hd44780 #(.CLK_HZ(20_000)) DUT (
        .clk(clk), .rst(rst), .wr(wr), .char(ch),
        .busy(busy), .lcd_rs(lcd_rs), .lcd_e(lcd_e), .lcd_data(lcd_data));

    always #5 clk = ~clk;

    // snoop the E strobe: latch (rs,data) on each rising edge
    reg       prev_e = 0;
    reg [4:0] cap [0:1];      // {rs, data4}
    integer   ecount = 0;
    reg       capturing = 0;
    always @(posedge clk) begin
        if (capturing && lcd_e && !prev_e) begin
            if (ecount < 2) cap[ecount] = {lcd_rs, lcd_data};
            ecount = ecount + 1;
        end
        prev_e <= lcd_e;
    end

    integer errors = 0, i;
    initial begin
        repeat (4) @(posedge clk); rst = 0;
        $display("---- HD44780 LCD driver ----");

        // wait out the power-on + init sequence
        i = 0;
        while (busy && i < 100000) begin @(posedge clk); i = i + 1; end
        if (busy) begin
            $display("  FAIL  init never completed"); errors = errors + 1;
        end else begin
            $display("  PASS  init sequence completed, busy released");
        end

        // now send 'H' = 0x48 and watch the two nibbles go out
        capturing = 1;
        @(posedge clk); wr <= 1'b1; ch <= 8'h48;
        @(posedge clk); wr <= 1'b0;
        i = 0;
        while (ecount < 2 && i < 100000) begin @(posedge clk); i = i + 1; end

        if (cap[0] !== {1'b1, 4'h4}) begin
            $display("  FAIL  high nibble = %b (want 1_0100)", cap[0]);
            errors = errors + 1;
        end else $display("  PASS  high nibble: RS=1 data=0x4");

        if (cap[1] !== {1'b1, 4'h8}) begin
            $display("  FAIL  low nibble = %b (want 1_1000)", cap[1]);
            errors = errors + 1;
        end else $display("  PASS  low nibble:  RS=1 data=0x8");

        if (errors == 0) $display("RESULT: ALL LCD TESTS PASSED  \342\234\205");
        else             $display("RESULT: %0d LCD TEST(S) FAILED", errors);
        $finish;
    end

endmodule
