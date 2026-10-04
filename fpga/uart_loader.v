// Loads a new program over the UART without rebuilding the bitstream
// (tools/load.py is the sending side). Packet, all little-endian:
//
//   "RVLD"  n_text:u16  n_data:u16  text words...  data words...  sum:u32
//
// where sum is the 32-bit sum of every text and data word. On the magic
// bytes the CPU is held in reset (`hold`); text words go into instruction
// memory and data words into data memory. After the checksum, the rest of
// both memories is zeroed so nothing from the previous program is left
// behind -- only then, because the receiver isn't listening while it fills
// and a byte takes ~100 clocks to arrive, shorter than a long fill. Then it
// replies one byte on the UART:
//   'K' checksum good -- the CPU is released and runs from address 0
//   'E' bad checksum or sizes, 'T' sender went quiet mid-packet -- the CPU
//       stays held (the program is half-written), waiting for a retry
// Nothing is listening for anything else, so a board nobody sends to runs
// whatever program it was built with, exactly as before.
module uart_loader #(
    parameter CLK_HZ     = 12_600_000,
    parameter IMEM_WORDS = 128,
    parameter DMEM_WORDS = 64
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    output reg         hold,          // keep the CPU in reset
    output reg         imem_we,
    output reg         dmem_we,
    output reg  [31:0] addr,          // byte address
    output reg  [31:0] wdata,
    output reg         ack_we,        // one byte for the UART transmitter
    output reg  [7:0]  ack_byte
);
    localparam S_MAGIC = 3'd0, S_HDR = 3'd1, S_TEXT = 3'd2, S_TFILL = 3'd3,
               S_DATA = 3'd4, S_DFILL = 3'd5, S_SUM = 3'd6;
    localparam integer TIMEOUT = CLK_HZ / 4;     // 250 ms with no byte = give up

    reg [2:0]  state;
    reg [1:0]  bcnt;                 // byte within the current word/field
    reg [31:0] word;                 // little-endian assembly buffer
    reg [15:0] n_text, n_data, idx;
    reg [31:0] sum;
    reg        sum_ok;
    reg [23:0] quiet;

    wire [31:0] word_next = {rx_data, word[31:8]};
    wire [31:0] magic     = "DLVR";  // "RVLD" as it arrives, first byte lowest

    task reply(input [7:0] b, input release_cpu);
        begin
            ack_we   <= 1'b1;
            ack_byte <= b;
            if (release_cpu) hold <= 1'b0;
            state    <= S_MAGIC;
            bcnt     <= 0;
            word     <= 0;
        end
    endtask

    always @(posedge clk) begin
        imem_we <= 1'b0;
        dmem_we <= 1'b0;
        ack_we  <= 1'b0;
        if (rst) begin
            state <= S_MAGIC;
            hold  <= 1'b0;
            bcnt  <= 0;
            word  <= 0;
            quiet <= 0;
        end else begin
            if (state == S_MAGIC || state == S_TFILL || state == S_DFILL || rx_valid)
                quiet <= 0;
            else if (quiet == TIMEOUT)
                reply("T", 1'b0);
            else
                quiet <= quiet + 1'b1;

            case (state)
                // slide the last four bytes along and look for "RVLD"
                S_MAGIC: if (rx_valid) begin
                    word <= word_next;
                    if (word_next == magic) begin
                        hold  <= 1'b1;
                        state <= S_HDR;
                        bcnt  <= 0;
                        sum   <= 0;
                    end
                end

                S_HDR: if (rx_valid) begin
                    word <= word_next;
                    bcnt <= bcnt + 1'b1;
                    if (bcnt == 2'd3) begin
                        n_text <= word_next[15:0];
                        n_data <= word_next[31:16];
                        idx    <= 0;
                        if (word_next[15:0] > IMEM_WORDS || word_next[31:16] > DMEM_WORDS)
                            reply("E", 1'b0);
                        else if (word_next[15:0] != 0)
                            state <= S_TEXT;
                        else
                            state <= (word_next[31:16] != 0) ? S_DATA : S_SUM;
                    end
                end

                S_TEXT: if (rx_valid) begin
                    word <= word_next;
                    bcnt <= bcnt + 1'b1;
                    if (bcnt == 2'd3) begin
                        imem_we <= 1'b1;
                        addr    <= {idx, 2'b00};
                        wdata   <= word_next;
                        sum     <= sum + word_next;
                        idx     <= idx + 1'b1;
                        if (idx + 1'b1 == n_text) begin
                            idx   <= 0;
                            state <= (n_data != 0) ? S_DATA : S_SUM;
                        end
                    end
                end

                S_TFILL: begin
                    if (idx == IMEM_WORDS) begin
                        idx   <= n_data;
                        state <= S_DFILL;
                    end else begin
                        imem_we <= 1'b1;
                        addr    <= {idx, 2'b00};
                        wdata   <= 32'd0;
                        idx     <= idx + 1'b1;
                    end
                end

                S_DATA: if (rx_valid) begin
                    word <= word_next;
                    bcnt <= bcnt + 1'b1;
                    if (bcnt == 2'd3) begin
                        dmem_we <= 1'b1;
                        addr    <= {idx, 2'b00};
                        wdata   <= word_next;
                        sum     <= sum + word_next;
                        idx     <= idx + 1'b1;
                        if (idx + 1'b1 == n_data) state <= S_SUM;
                    end
                end

                S_DFILL: begin
                    if (idx == DMEM_WORDS) begin
                        reply(sum_ok ? "K" : "E", sum_ok);
                    end else begin
                        dmem_we <= 1'b1;
                        addr    <= {idx, 2'b00};
                        wdata   <= 32'd0;
                        idx     <= idx + 1'b1;
                    end
                end

                S_SUM: if (rx_valid) begin
                    word <= word_next;
                    bcnt <= bcnt + 1'b1;
                    if (bcnt == 2'd3) begin
                        sum_ok <= (word_next == sum);
                        idx    <= n_text;
                        state  <= S_TFILL;
                    end
                end

                default: state <= S_MAGIC;
            endcase
        end
    end
endmodule
