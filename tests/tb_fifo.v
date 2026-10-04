// Fills the FIFO, checks full asserts at the right depth, drains it and
// checks FIFO ordering + empty, and verifies a write-while-full doesn't
// corrupt the pointers.
`timescale 1ns/1ps

module tb_fifo;
    localparam DEPTH = 8;
    reg        clk = 0, rst = 1, wr = 0, rd = 0;
    reg  [7:0] din;
    wire [7:0] dout;
    wire       full, empty;

    fifo #(.WIDTH(8), .DEPTH(DEPTH)) DUT (
        .clk(clk), .rst(rst), .wr(wr), .din(din), .rd(rd),
        .dout(dout), .full(full), .empty(empty));

    always #5 clk = ~clk;

    integer errors = 0, k;
    task push(input [7:0] v);
        begin @(posedge clk); wr <= 1; din <= v; @(posedge clk); wr <= 0; end
    endtask

    initial begin
        repeat (3) @(posedge clk); rst = 0; @(posedge clk);
        $display("---- byte FIFO ----");

        if (!empty) begin $display("  FAIL  not empty at reset"); errors=errors+1; end
        else $display("  PASS  empty at reset");

        for (k = 0; k < DEPTH; k = k + 1) push(8'h10 + k[7:0]);
        @(posedge clk);          // let the last write's pointer update settle

        if (!full) begin $display("  FAIL  not full after %0d writes", DEPTH); errors=errors+1; end
        else $display("  PASS  full after %0d writes", DEPTH);

        // write-while-full must be dropped, not overwrite the head
        @(posedge clk); wr <= 1; din <= 8'hEE; @(posedge clk); wr <= 0;

        for (k = 0; k < DEPTH; k = k + 1) begin
            @(posedge clk);
            if (dout !== (8'h10 + k[7:0])) begin
                $display("  FAIL  pos %0d = 0x%02x (want 0x%02x)", k, dout, 8'h10+k[7:0]);
                errors = errors + 1;
            end
            rd <= 1; @(posedge clk); rd <= 0;
        end
        @(posedge clk);          // let the last read's pointer update settle

        if (!empty) begin $display("  FAIL  not empty after draining"); errors=errors+1; end
        else $display("  PASS  FIFO order preserved and empty after drain");

        if (errors == 0) $display("RESULT: ALL FIFO TESTS PASSED");
        else             $display("RESULT: %0d FIFO TEST(S) FAILED", errors);
        $finish;
    end
endmodule
