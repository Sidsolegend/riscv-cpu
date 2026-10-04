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
// replies with a tagged line on the UART, "[load X]\n":
//   K  checksum good -- the CPU is released and runs from address 0
//   E  bad checksum or sizes, T  sender went quiet mid-packet -- the CPU
//      stays held (the program is half-written), waiting for a retry
// A tag rather than a single byte because the host can also receive junk
// (the line glitches whenever the FPGA is reconfigured) and leftover output
// from the old program; `flush` empties the transmit FIFO when a packet
// starts, and the CPU is only released after the whole reply is queued, so
// its own output always comes after the tag.
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
    output reg  [7:0]  ack_byte,
    output reg         flush          // empty the UART transmit FIFO
);
    localparam S_MAGIC = 3'd0, S_HDR = 3'd1, S_TEXT = 3'd2, S_TFILL = 3'd3,
               S_DATA = 3'd4, S_DFILL = 3'd5, S_SUM = 3'd6, S_ACK = 3'd7;
    localparam integer TIMEOUT = CLK_HZ / 4;     // 250 ms with no byte = give up

    reg [2:0]  state;
    reg [1:0]  bcnt;                 // byte within the current word/field
    reg [31:0] word;                 // little-endian assembly buffer
    reg [15:0] n_text, n_data, idx;
    reg [31:0] sum;
    reg        sum_ok;
    reg [23:0] quiet;
    reg [7:0]  ack_code;
    reg        ack_release;
    reg [3:0]  ack_idx;

    function [7:0] ack_text(input [3:0] i, input [7:0] code);
        case (i)
            4'd0: ack_text = "[";  4'd1: ack_text = "l";  4'd2: ack_text = "o";
            4'd3: ack_text = "a";  4'd4: ack_text = "d";  4'd5: ack_text = " ";
            4'd6: ack_text = code; 4'd7: ack_text = "]";  default: ack_text = 8'h0A;
        endcase
    endfunction

    wire [31:0] word_next = {rx_data, word[31:8]};
    wire [31:0] magic     = "DLVR";  // "RVLD" as it arrives, first byte lowest

    task reply(input [7:0] code, input release_cpu);
        begin
            ack_code    <= code;
            ack_release <= release_cpu;
            ack_idx     <= 0;
            state       <= S_ACK;
        end
    endtask

    always @(posedge clk) begin
        imem_we <= 1'b0;
        dmem_we <= 1'b0;
        ack_we  <= 1'b0;
        flush   <= 1'b0;
        if (rst) begin
            state <= S_MAGIC;
            hold  <= 1'b0;
            bcnt  <= 0;
            word  <= 0;
            quiet <= 0;
        end else begin
            if (state == S_MAGIC || state == S_TFILL || state == S_DFILL ||
                state == S_ACK || rx_valid)
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
                        flush <= 1'b1;
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

                // the tagged reply, one byte a clock into the transmit FIFO;
                // the CPU goes only once all of it is queued
                S_ACK: begin
                    ack_we   <= 1'b1;
                    ack_byte <= ack_text(ack_idx, ack_code);
                    ack_idx  <= ack_idx + 1'b1;
                    if (ack_idx == 4'd8) begin
                        if (ack_release) hold <= 1'b0;
                        state <= S_MAGIC;
                        bcnt  <= 0;
                        word  <= 0;
                    end
                end
            endcase
        end
    end
endmodule
