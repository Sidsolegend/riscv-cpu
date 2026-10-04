// Data memory + memory-mapped I/O bus. Reads are combinational, writes are
// synchronous, same as the register file. Two things beyond plain RAM:
//
//  - sub-word access: RV32I loads/stores are byte/half/word (funct3 picks
//    size + signedness), but the RAM stays word-wide, so addr[1:0] selects
//    the byte lane(s) and stores are read-modify-write.
//  - memory-mapped I/O above MMIO_BASE (0x10000000): a UART write byte, a
//    free-running cycle counter, and a HALT register -- this is what lets
//    a program print and exit instead of just leaving a result in a register.
`include "defines.vh"

module dmem #(
    parameter MEM_WORDS = 256,
    parameter DATA      = "",      // optional .data hex preload
    parameter CLK_HZ    = 0        // reported at MMIO_CLKHZ, so programs can time themselves
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        we,        // MemWrite, i.e. sb/sh/sw
    input  wire [2:0]  funct3,    // size + signedness
    input  wire [31:0] addr,      // rs1 + imm
    input  wire [31:0] wdata,     // rs2
    output reg  [31:0] rdata,
    output reg         halted,
    // device write strobes -- unconnected in plain sim, used by the FPGA
    // top to drive real UART/LCD hardware
    output wire        io_uart_we,
    output wire        io_lcd_we,
    output wire [7:0]  io_wbyte
);
    reg [31:0] mem [0:MEM_WORDS-1];

    integer i;
    initial begin
`ifndef SYNTHESIS
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;   // see imem.v
`endif
        if (DATA != "") $readmemh(DATA, mem);
        halted = 1'b0;
    end

    wire        is_io    = (addr >= `MMIO_BASE);
    wire [4:0]  io_reg   = addr[4:0];
    wire [31:0] ram_word = mem[addr[31:2] % MEM_WORDS];

    assign io_uart_we = we & is_io & (io_reg == `MMIO_UART);
    assign io_lcd_we  = we & is_io & (io_reg == `MMIO_LCD);
    assign io_wbyte   = wdata[7:0];

    reg [31:0] cycles;
    always @(posedge clk) begin
        if (rst) cycles <= 32'd0;
        else     cycles <= cycles + 32'd1;
    end

    // funct3: 000=lb  001=lh  010=lw  100=lbu  101=lhu
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
                `MMIO_CLKHZ: rdata = CLK_HZ;
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

    always @(posedge clk) begin
        if (rst) halted <= 1'b0;
        if (we) begin
            if (is_io) begin
                case (io_reg)
                    // console echo is sim-only; on the FPGA the strobes
                    // io_uart_we / io_lcd_we drive the real peripherals
                    `MMIO_UART: begin
`ifndef SYNTHESIS
                        $write("%c", wdata[7:0]);
                        $fflush;
`endif
                    end
                    `MMIO_LCD: begin
`ifndef SYNTHESIS
                        $write("%c", wdata[7:0]);
                        $fflush;
`endif
                    end
                    `MMIO_HALT: begin
                        halted <= 1'b1;
`ifndef SYNTHESIS
                        if (wdata != 32'd0)
                            $display("\n[dmem] HALT with exit code %0d", wdata);
`endif
                    end
                    default: ;
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
