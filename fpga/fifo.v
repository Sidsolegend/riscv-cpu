// Small synchronous ring-buffer FIFO, sits between the CPU's UART store
// (one cycle) and the UART shift register (hundreds of cycles per byte) so
// a burst of back-to-back writes doesn't overrun the transmitter and drop
// characters. Writes while full / reads while empty are just ignored.
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
    reg [AW:0]      wptr_q = 0;           // wptr one clock late, see empty below
    reg [WIDTH-1:0] dout_q;

    wire do_wr = wr & ~full;
    wire do_rd = rd & ~empty;
    wire [AW:0] rptr_n = rptr + {{AW{1'b0}}, do_rd};

    always @(posedge clk) begin
        if (rst) begin
            wptr   <= 0;
            rptr   <= 0;
            wptr_q <= 0;
        end else begin
            wptr_q <= wptr;
            if (do_wr) begin
                mem[wptr[AW-1:0]] <= din;
                wptr <= wptr + 1'b1;
            end
            rptr <= rptr_n;
        end
    end

    // Synchronous read so this maps to block RAM (an async-read memory this
    // size becomes LUT-RAM, which the Gowin place-and-route can't place).
    // dout always shows the entry at rptr, one clock after rptr moves.
    always @(posedge clk) dout_q <= mem[rptr_n[AW-1:0]];
    assign dout = dout_q;

    // empty looks at wptr a clock late: a write lands in mem at the same
    // edge wptr moves, but dout only reflects it one edge after that, so
    // reporting not-empty any sooner would hand out the previous contents.
    assign empty = (wptr_q == rptr);
    // full: pointers equal in the low bits but differ in the wrap bit
    assign full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);

endmodule
