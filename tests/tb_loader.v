// End-to-end test of program loading on the full SoC: real UART frames into
// uart_rx_pin (what tools/load.py sends), the replies and the program's own
// output decoded from uart_tx_pin. The board boots hello, then:
//   bad checksum            -> 'E', CPU stays stopped (no output)
//   too-big program         -> 'E'
//   fib                     -> 'K', then fib's output
//   hello again             -> 'K', then hello's output (nothing left over
//                              from fib breaks it, including the halt flag)
//   memops_test (no .data)  -> 'K', then its register results check out
//   sender stops mid-packet -> 'T'
`timescale 1ns/1ps

module tb_loader;
    localparam CLK_HZ = 1_000_000, BAUD = 100_000;

    reg  clk = 0, mon_rst = 1;
    wire tx_line, rx_line;
    wire tmds_clk_p, tmds_clk_n;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire [5:0] led_n;

    soc_tangnano9k #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .PROG("programs/hello.hex"), .DATA("programs/hello.data.hex")
    ) DUT (
        .clk_in(clk), .btn_rst_n(1'b1),
        .uart_tx_pin(tx_line), .uart_rx_pin(rx_line),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n), .led_n(led_n));

    always #5 clk = ~clk;

    // host -> board
    reg        h_wr = 0;
    reg  [7:0] h_byte;
    wire       h_busy;
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) HOST (
        .clk(clk), .rst(mon_rst), .wr(h_wr), .data(h_byte), .tx(rx_line), .busy(h_busy));

    // board -> host
    wire [7:0] m_byte;
    wire       m_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) MON (
        .clk(clk), .rst(mon_rst), .rx(tx_line), .data(m_byte), .valid(m_valid));

    reg [7:0] got [0:4095];
    integer   n = 0;
    always @(posedge clk) if (m_valid) begin got[n] = m_byte; n = n + 1; end

    integer errors = 0;

    task send(input [7:0] b);
        begin
            wait (!h_busy);
            @(posedge clk); h_byte <= b; h_wr <= 1'b1;
            @(posedge clk); h_wr <= 1'b0;
            @(posedge clk);
            wait (!h_busy);
        end
    endtask

    task send32(input [31:0] w);
        begin send(w[7:0]); send(w[15:8]); send(w[23:16]); send(w[31:24]); end
    endtask

    reg [31:0] text [0:255];
    reg [31:0] data [0:255];
    integer    nt, nd;

    task load_hex(input [8*64-1:0] tfile, input [8*64-1:0] dfile);
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1) begin text[i] = 32'bx; data[i] = 32'bx; end
            $readmemh(tfile, text);
            if (dfile != "") $readmemh(dfile, data);
            nt = 0; while (text[nt] !== 32'bx) nt = nt + 1;
            nd = 0; while (data[nd] !== 32'bx) nd = nd + 1;
        end
    endtask

    task send_packet(input integer ntext, input integer ndata, input bad_sum);
        integer i;
        reg [31:0] sum;
        begin
            sum = 0;
            send("R"); send("V"); send("L"); send("D");
            send(ntext[7:0]); send(ntext[15:8]); send(ndata[7:0]); send(ndata[15:8]);
            for (i = 0; i < ntext; i = i + 1) begin send32(text[i]); sum = sum + text[i]; end
            for (i = 0; i < ndata; i = i + 1) begin send32(data[i]); sum = sum + data[i]; end
            send32(bad_sum ? sum + 1 : sum);
        end
    endtask

    // wait for `want` to show up as the next bytes received after `from`
    task expect_text(input integer from, input [8*40-1:0] want, input integer len,
                     input integer budget, input [8*48-1:0] label);
        integer i, t;
        reg ok;
        begin
            t = 0;
            while (n < from + len && t < budget) begin @(posedge clk); t = t + 1; end
            ok = (n >= from + len);
            for (i = 0; i < len && ok; i = i + 1)
                if (got[from + i] !== want[8*(len-1-i) +: 8]) ok = 0;
            if (ok) $display("  PASS  %0s", label);
            else begin
                $display("  FAIL  %0s (got %0d bytes)", label, n - from);
                errors = errors + 1;
            end
        end
    endtask

    task expect_silence(input integer cycles, input [8*48-1:0] label);
        integer n0;
        begin
            n0 = n;
            repeat (cycles) @(posedge clk);
            if (n == n0) $display("  PASS  %0s", label);
            else begin
                $display("  FAIL  %0s (%0d unexpected bytes)", label, n - n0);
                errors = errors + 1;
            end
        end
    endtask

    integer mark;
    initial begin
        repeat (4) @(posedge clk); mon_rst = 0;
        $display("---- UART program loader ----");

        expect_text(0, "HELLO FROM MY RISC-V CPU!", 25, 200000, "boots the built-in program");
        repeat (5000) @(posedge clk);

        load_hex("programs/fib.hex", "programs/fib.data.hex");
        mark = n; send_packet(nt, nd, 1);
        expect_text(mark, "E", 1, 20000, "bad checksum is refused with 'E'");
        expect_silence(50000, "and the CPU stays stopped");

        mark = n; send("R"); send("V"); send("L"); send("D");
        send(8'd200); send(8'd0); send(8'd0); send(8'd0);     // 200 > 128 words
        expect_text(mark, "E", 1, 20000, "too-big program is refused with 'E'");

        mark = n; send_packet(nt, nd, 0);
        expect_text(mark, "Kfib(15) = 610", 14, 400000, "fib loads, replies 'K', and runs");

        repeat (20000) @(posedge clk);
        load_hex("programs/hello.hex", "programs/hello.data.hex");
        mark = n; send_packet(nt, nd, 0);
        expect_text(mark, "KHELLO FROM MY RISC-V CPU!", 26, 400000, "a second program loads over the first");

        // a program with no data section (n_data = 0); it prints nothing,
        // so check the registers it leaves behind instead
        repeat (20000) @(posedge clk);
        load_hex("programs/memops_test.hex", "");
        mark = n; send_packet(nt, 0, 0);
        expect_text(mark, "K", 1, 400000, "program with no data section loads");
        repeat (5000) @(posedge clk);
        if (DUT.CPU.halted && DUT.CPU.RF.regs[18] === 32'h8091A2B3 && DUT.CPU.RF.regs[23] === 32'hBEEF0000)
            $display("  PASS  and runs correctly (byte/half load-store results)");
        else begin
            $display("  FAIL  memops_test after loading: halted=%b x18=%h x23=%h",
                     DUT.CPU.halted, DUT.CPU.RF.regs[18], DUT.CPU.RF.regs[23]);
            errors = errors + 1;
        end

        repeat (20000) @(posedge clk);
        mark = n; send("R"); send("V"); send("L"); send("D"); send(8'd5);
        expect_text(mark, "T", 1, CLK_HZ, "sender going quiet mid-packet times out with 'T'");

        if (errors == 0) $display("RESULT: ALL LOADER TESTS PASSED");
        else             $display("RESULT: %0d LOADER TEST(S) FAILED", errors);
        $finish;
    end
endmodule
