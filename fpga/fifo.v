// ============================================================================
//  fifo.v  —  small synchronous FIFO (byte buffer for the CPU -> UART path)
// ----------------------------------------------------------------------------
//  The CPU issues a UART store in a single cycle, but the UART needs hundreds
//  of clocks to shift that byte out. Without buffering, a program that prints
//  "HELLO..." back-to-back would overrun the transmitter and lose characters.
//  This FIFO absorbs a burst of writes and lets the UART drain them at its own
//  pace, so the existing demo programs — which don't poll the UART — still
//  print correctly on real hardware.
//
//  Standard single-clock ring buffer: `wr`/`rd` strobes, `full`/`empty` flags.
//  Writes while full and reads while empty are ignored (the guards live here).
// ============================================================================
module fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 512          // must be a power of two
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              wr,
    input  wire [WIDTH-1:0]  din,
    input  wire              rd,
    output wire [WIDTH-1:0]  dout,
    output wire              full,
    output wire              empty
);
    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0]      wptr = 0, rptr = 0;   // extra bit distinguishes full/empty

    wire do_wr = wr & ~full;
    wire do_rd = rd & ~empty;

    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0;
            rptr <= 0;
        end else begin
            if (do_wr) begin
                mem[wptr[AW-1:0]] <= din;
                wptr <= wptr + 1'b1;
            end
            if (do_rd) rptr <= rptr + 1'b1;
        end
    end

    assign dout  = mem[rptr[AW-1:0]];
    assign empty = (wptr == rptr);
    // full: pointers equal in the low bits but differ in the wrap bit
    assign full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);

endmodule
