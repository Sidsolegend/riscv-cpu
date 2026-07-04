// ============================================================================
//  dmem.v  —  Data Memory + Memory-Mapped I/O (the CPU's "bus")
// ----------------------------------------------------------------------------
//  This is where loads read from and stores write to. Like the register file:
//    - reads  are combinational (load gets its value the same cycle)
//    - writes are synchronous  (store commits on the rising clock edge)
//
//  Two things beyond a plain RAM live here:
//
//  1. SUB-WORD ACCESS. RV32I loads/stores come in three sizes, selected by
//     the instruction's funct3:
//        lb / lbu   1 byte   (sign- / zero-extended to 32 bits)
//        lh / lhu   2 bytes  (sign- / zero-extended)
//        lw         4 bytes
//        sb, sh, sw the store equivalents
//     The RAM itself stays word-wide; addr[1:0] picks which byte lane(s)
//     inside the word we touch. Stores are read-modify-write on byte lanes.
//
//  2. MEMORY-MAPPED I/O. Addresses at/above MMIO_BASE (0x10000000) are not
//     RAM — they are devices, exactly like a real SoC:
//        0x10000000  write -> UART: low byte prints to the console
//        0x10000004  read  -> free-running cycle counter (performance timing)
//        0x10000008  write -> HALT: raises `halted` (value = exit code)
//     This is what lets programs *print* and *stop* — i.e. behave like
//     applications instead of register puzzles.
// ============================================================================
`include "defines.vh"

module dmem #(
    parameter MEM_WORDS = 256,
    parameter DATA      = ""       // optional hex file preloaded into RAM
                                   // (the assembler's .data section)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        we,        // MemWrite: 1 for sb/sh/sw
    input  wire [2:0]  funct3,    // size + signedness of the access
    input  wire [31:0] addr,      // byte address = rs1 + imm
    input  wire [31:0] wdata,     // value to store (rs2)
    output reg  [31:0] rdata,     // value loaded
    output reg         halted,    // latched by a store to MMIO_HALT
    // ---- device write strobes (used by the FPGA top to drive real HW) ------
    //  Pulsed for one cycle when a store hits the UART / LCD device. In pure
    //  simulation these outputs are simply left unconnected.
    output wire        io_uart_we, // store to MMIO_UART this cycle
    output wire        io_lcd_we,  // store to MMIO_LCD  this cycle
    output wire [7:0]  io_wbyte    // the byte being written (low 8 bits)
);
    reg [31:0] mem [0:MEM_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;
        if (DATA != "") $readmemh(DATA, mem);   // preload .data if given
        halted = 1'b0;
    end

    // ---- bus decode: RAM or device? ----------------------------------------
    wire        is_io    = (addr >= `MMIO_BASE);
    wire [3:0]  io_reg   = addr[3:0];
    wire [31:0] ram_word = mem[addr[31:2] % MEM_WORDS];

    // ---- device write strobes (combinational; consumed by the FPGA top) ----
    assign io_uart_we = we & is_io & (io_reg == `MMIO_UART);
    assign io_lcd_we  = we & is_io & (io_reg == `MMIO_LCD);
    assign io_wbyte   = wdata[7:0];

    // ---- free-running cycle counter (readable at MMIO_CYCLE) ----------------
    reg [31:0] cycles;
    always @(posedge clk) begin
        if (rst) cycles <= 32'd0;
        else     cycles <= cycles + 32'd1;
    end

    // ---- combinational READ -------------------------------------------------
    //  Pick the addressed byte/half out of the word, then extend it.
    //  funct3: 000=lb  001=lh  010=lw  100=lbu  101=lhu
    reg [7:0]  rd_byte;
    reg [15:0] rd_half;
    always @(*) begin
        case (addr[1:0])
            2'd0: rd_byte = ram_word[7:0];
            2'd1: rd_byte = ram_word[15:8];
            2'd2: rd_byte = ram_word[23:16];
            2'd3: rd_byte = ram_word[31:24];
        endcase
        rd_half = addr[1] ? ram_word[31:16] : ram_word[15:0];

        if (is_io) begin
            case (io_reg)
                `MMIO_CYCLE: rdata = cycles;
                default    : rdata = 32'd0;
            endcase
        end else begin
            case (funct3)
                3'b000 : rdata = {{24{rd_byte[7]}},  rd_byte};   // lb  (signed)
                3'b001 : rdata = {{16{rd_half[15]}}, rd_half};   // lh  (signed)
                3'b100 : rdata = {24'b0, rd_byte};               // lbu
                3'b101 : rdata = {16'b0, rd_half};               // lhu
                default: rdata = ram_word;                       // lw
            endcase
        end
    end

    // ---- synchronous WRITE --------------------------------------------------
    //  RAM: read-modify-write on byte lanes so sb/sh leave the rest of the
    //  word untouched. Devices: side effects instead of storage.
    always @(posedge clk) begin
        if (we) begin
            if (is_io) begin
                case (io_reg)
                    `MMIO_UART: begin
                        $write("%c", wdata[7:0]);   // the "serial port"
                        $fflush;
                    end
                    `MMIO_LCD: begin
                        // On real hardware this byte is streamed to the HD44780
                        // character LCD (see fpga/lcd_hd44780.v). In simulation
                        // there is no panel, so we echo it to the console — the
                        // same program then works both in sim and on the board.
                        $write("%c", wdata[7:0]);
                        $fflush;
                    end
                    `MMIO_HALT: begin
                        halted <= 1'b1;
                        if (wdata != 32'd0)
                            $display("\n[dmem] HALT with exit code %0d", wdata);
                    end
                    default: ; // writes to unknown device addresses: ignored
                endcase
            end else begin
                case (funct3)
                    3'b000: case (addr[1:0])                     // sb
                        2'd0: mem[addr[31:2] % MEM_WORDS][7:0]   <= wdata[7:0];
                        2'd1: mem[addr[31:2] % MEM_WORDS][15:8]  <= wdata[7:0];
                        2'd2: mem[addr[31:2] % MEM_WORDS][23:16] <= wdata[7:0];
                        2'd3: mem[addr[31:2] % MEM_WORDS][31:24] <= wdata[7:0];
                    endcase
                    3'b001: begin                                 // sh
                        if (addr[1]) mem[addr[31:2] % MEM_WORDS][31:16] <= wdata[15:0];
                        else         mem[addr[31:2] % MEM_WORDS][15:0]  <= wdata[15:0];
                    end
                    default: mem[addr[31:2] % MEM_WORDS] <= wdata; // sw
                endcase
            end
        end
    end

endmodule
