// HD44780 16x2 character LCD driver, 4-bit mode. A store to MMIO_LCD lands
// here as one byte; the HD44780 has its own character ROM, so we just push
// ASCII + a few control commands, no framebuffer needed.
//
// Only DB7..DB4 are wired, so every byte goes out as two nibbles (high
// then low), each latched by a pulse on E. RW is tied low on the board, so
// instead of polling the busy flag we wait the datasheet's worst-case
// delay after each nibble.
//
// On reset the FSM runs the mandatory power-on init sequence (the
// 0x3,0x3,0x3,0x2 wake-up, then function-set/display-on/clear/entry-mode)
// before accepting characters -- `busy` covers both that and any byte
// currently being clocked out. All timing is derived from CLK_HZ.
module lcd_hd44780 #(
    parameter CLK_HZ = 27_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,          // pulse to display `char` (ignored while busy)
    input  wire [7:0] char,
    output reg        busy,
    // physical pins to the panel (RW is tied to GND on the board)
    output reg        lcd_rs,      // 0 = command, 1 = data
    output reg        lcd_e,       // enable strobe
    output reg [3:0]  lcd_data     // DB7..DB4
);
    // ---- timing (in clock cycles) ------------------------------------------
    localparam integer T_PULSE = (CLK_HZ / 1_000_000) + 1;    // ~1 us E width
    localparam integer T_SHORT = (CLK_HZ / 20_000)    + 1;    // ~50 us per byte
    localparam integer T_LONG  = (CLK_HZ / 400)       + 1;    // ~2.5 ms (clear)
    localparam integer T_BOOT  = (CLK_HZ / 20)        + 1;    // ~50 ms power-on

    // ---- init micro-sequence: {rs, data4, long?} per nibble-op -------------
    //  These are single 4-bit ops (the wake-up nibbles), then full bytes given
    //  as two nibble-ops. `long` picks the post-op delay.
    localparam INIT_LEN = 13;
    reg [5:0] init_rom [0:INIT_LEN-1];
    initial begin
        //            {rs, data[3:0], long}
        init_rom[0]  = {1'b0, 4'h3, 1'b1};  // wake-up 1 (needs long settle)
        init_rom[1]  = {1'b0, 4'h3, 1'b1};  // wake-up 2
        init_rom[2]  = {1'b0, 4'h3, 1'b1};  // wake-up 3
        init_rom[3]  = {1'b0, 4'h2, 1'b0};  // switch to 4-bit interface
        init_rom[4]  = {1'b0, 4'h2, 1'b0};  // function set: hi nibble (0x28)
        init_rom[5]  = {1'b0, 4'h8, 1'b0};  //   lo nibble -> 4-bit, 2-line, 5x8
        init_rom[6]  = {1'b0, 4'h0, 1'b0};  // display control: hi (0x0C)
        init_rom[7]  = {1'b0, 4'hC, 1'b0};  //   lo -> display on, cursor off
        init_rom[8]  = {1'b0, 4'h0, 1'b0};  // clear display: hi (0x01)
        init_rom[9]  = {1'b0, 4'h1, 1'b1};  //   lo -> clear (needs long delay)
        init_rom[10] = {1'b0, 4'h0, 1'b0};  // entry mode: hi (0x06)
        init_rom[11] = {1'b0, 4'h6, 1'b0};  //   lo -> increment, no shift
        init_rom[12] = {1'b0, 4'h0, 1'b0};  // (unused padding / settle)
    end

    // ---- FSM ---------------------------------------------------------------
    localparam S_BOOT   = 3'd0,   // initial power-on delay
               S_INIT   = 3'd1,   // walk the init ROM
               S_IDLE   = 3'd2,   // wait for a character
               S_HI     = 3'd3,   // clock the high nibble of a data byte
               S_LO     = 3'd4;   // clock the low nibble
    reg [2:0]  state;
    reg [3:0]  init_idx;
    reg [7:0]  cur_char;

    // nibble-op executor: SETUP -> E high -> E low(+post delay)
    localparam OP_IDLE = 2'd0, OP_SETUP = 2'd1, OP_EHI = 2'd2, OP_HOLD = 2'd3;
    reg [1:0]  op;
    reg        op_start;      // request: run one nibble-op
    reg        op_rs;
    reg [3:0]  op_data;
    reg        op_long;
    reg        op_done;       // pulses when the nibble-op completes
    reg [23:0] dcnt;

    // ---- nibble-op executor -------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            op <= OP_IDLE; lcd_e <= 1'b0; op_done <= 1'b0; dcnt <= 24'd0;
        end else begin
            op_done <= 1'b0;
            case (op)
                OP_IDLE: begin
                    lcd_e <= 1'b0;
                    if (op_start) begin
                        lcd_rs   <= op_rs;
                        lcd_data <= op_data;
                        dcnt     <= T_PULSE;
                        op       <= OP_SETUP;
                    end
                end
                OP_SETUP: begin            // address/data setup before E rises
                    if (dcnt == 0) begin
                        lcd_e <= 1'b1;
                        dcnt  <= T_PULSE;
                        op    <= OP_EHI;
                    end else dcnt <= dcnt - 24'd1;
                end
                OP_EHI: begin              // E high for the pulse width
                    if (dcnt == 0) begin
                        lcd_e <= 1'b0;
                        dcnt  <= op_long ? T_LONG : T_SHORT;
                        op    <= OP_HOLD;
                    end else dcnt <= dcnt - 24'd1;
                end
                OP_HOLD: begin             // post-op execution delay
                    if (dcnt == 0) begin
                        op      <= OP_IDLE;
                        op_done <= 1'b1;
                    end else dcnt <= dcnt - 24'd1;
                end
            endcase
        end
    end

    // ---- top sequencer ------------------------------------------------------
    reg [23:0] bootcnt;
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_BOOT;
            busy     <= 1'b1;
            init_idx <= 4'd0;
            op_start <= 1'b0;
            bootcnt  <= T_BOOT;
        end else begin
            op_start <= 1'b0;                     // default: no new op
            case (state)
                S_BOOT: begin
                    if (bootcnt == 0) state <= S_INIT;
                    else bootcnt <= bootcnt - 24'd1;
                end
                S_INIT: begin
                    if (op == OP_IDLE && !op_start) begin
                        if (init_idx == INIT_LEN) begin
                            state <= S_IDLE;
                            busy  <= 1'b0;
                        end else begin
                            op_rs    <= init_rom[init_idx][5];
                            op_data  <= init_rom[init_idx][4:1];
                            op_long  <= init_rom[init_idx][0];
                            op_start <= 1'b1;
                            init_idx <= init_idx + 4'd1;
                        end
                    end
                end
                S_IDLE: begin
                    if (wr) begin
                        cur_char <= char;
                        busy     <= 1'b1;
                        // send the HIGH nibble first (RS=1: it's data)
                        op_rs    <= 1'b1;
                        op_data  <= char[7:4];
                        op_long  <= 1'b0;
                        op_start <= 1'b1;
                        state    <= S_HI;
                    end
                end
                S_HI: begin
                    if (op_done) begin
                        op_rs    <= 1'b1;
                        op_data  <= cur_char[3:0];   // then the LOW nibble
                        op_long  <= 1'b0;
                        op_start <= 1'b1;
                        state    <= S_LO;
                    end
                end
                S_LO: begin
                    if (op_done) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                    end
                end
            endcase
        end
    end

endmodule
