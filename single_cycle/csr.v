// Machine-mode CSRs + trap logic (Zicsr). Handles csrrw/csrrs/csrrc[i],
// taking a trap on ecall/ebreak/illegal-instr/timer-irq, and mret.
//
// The timer is intentionally minimal: mcycle free-runs, and an interrupt
// fires once mcycle >= mtimecmp (gated by mie.MTIE and mstatus.MIE).
// Writing mtimecmp (custom CSR 0x7C0) arms and acks it in one shot --
// same idea as a CLINT, just riding on a CSR instead of a separate MMIO
// register.
//
// Machine mode only, single hart, no delegation -- that's the whole scope.
`include "defines.vh"

module csr (
    input  wire        clk,
    input  wire        rst,

    input  wire        csr_access,   // a CSR instruction is executing
    input  wire [11:0] csr_addr,     // instr[31:20]
    input  wire [2:0]  csr_cmd,      // funct3: CSR_RW / CSR_RS / CSR_RC / *I
    input  wire [31:0] csr_wsrc,     // rs1 value, or the zero-extended imm
    input  wire        csr_rs1_nz,   // rs/rc skip the write when rs1 == 0
    output reg  [31:0] csr_rdata,    // old value of the addressed CSR -> rd

    input  wire        ex_valid,     // instruction in flight actually retires
    input  wire [31:0] pc,           // candidate mepc
    input  wire        exc_ecall,
    input  wire        exc_ebreak,
    input  wire        exc_illegal,
    input  wire        do_mret,

    output wire        trap,         // take a trap this cycle -> jump to mtvec
    output wire [31:0] trap_vector,
    output wire        mret,         // return from trap -> jump to mepc
    output wire [31:0] mret_target
);
    reg [31:0] mstatus;     // only MIE (bit 3) and MPIE (bit 7) are meaningful
    reg [31:0] mtvec;       // trap vector base (direct mode: low 2 bits = 0)
    reg [31:0] mepc;        // PC saved on trap
    reg [31:0] mcause;      // why we trapped
    reg [31:0] mtval;       // trap value (0 here; kept for spec-completeness)
    reg [31:0] mscratch;    // scratch word for the handler
    reg [31:0] mie;         // interrupt enables (only MTIE, bit 7)
    reg [31:0] mcycle;      // free-running cycle counter (the timer base)
    reg [31:0] minstret;    // retired-instruction counter
    reg [31:0] mtimecmp;    // machine-timer compare value

    // level-triggered while mcycle >= mtimecmp; mtimecmp == 0 (its reset
    // value) means the timer is off, so nothing fires until software arms it
    wire timer_fire = (mtimecmp != 32'd0) && (mcycle >= mtimecmp);
    wire mtip       = timer_fire;                       // mip.MTIP (live)
    wire irq_timer  = mstatus[`MSTATUS_MIE] & mie[`IRQ_MTIP] & mtip;

    wire exc_sync = exc_ecall | exc_ebreak | exc_illegal;

    assign trap        = ex_valid & (irq_timer | exc_sync);
    assign trap_vector = {mtvec[31:2], 2'b00};          // direct mode
    assign mret        = ex_valid & do_mret;
    assign mret_target = mepc;

    // interrupt wins if both fire in the same cycle
    wire [31:0] cause =
        irq_timer   ? `CAUSE_MTIMER  :
        exc_illegal ? `CAUSE_ILLEGAL :
        exc_ebreak  ? `CAUSE_EBREAK  :
                      `CAUSE_ECALL_M ;

    // unimplemented CSRs read as 0
    always @(*) begin
        case (csr_addr)
            `CSR_MSTATUS : csr_rdata = mstatus;
            `CSR_MISA    : csr_rdata = 32'h4000_1100;    // RV32IM (bits M, I)
            `CSR_MIE     : csr_rdata = mie;
            `CSR_MTVEC   : csr_rdata = mtvec;
            `CSR_MSCRATCH: csr_rdata = mscratch;
            `CSR_MEPC    : csr_rdata = mepc;
            `CSR_MCAUSE  : csr_rdata = mcause;
            `CSR_MTVAL   : csr_rdata = mtval;
            `CSR_MIP     : csr_rdata = {24'b0, mtip, 7'b0};   // MTIP at bit 7
            `CSR_MTIMECMP: csr_rdata = mtimecmp;
            `CSR_MCYCLE,
            `CSR_CYCLE,
            `CSR_TIME    : csr_rdata = mcycle;
            `CSR_MINSTRET,
            `CSR_INSTRET : csr_rdata = minstret;
            default      : csr_rdata = 32'd0;
        endcase
    end

    reg [31:0] csr_next;
    always @(*) begin
        case (csr_cmd)
            `CSR_RW, `CSR_RWI: csr_next = csr_wsrc;
            `CSR_RS, `CSR_RSI: csr_next = csr_rdata |  csr_wsrc;
            `CSR_RC, `CSR_RCI: csr_next = csr_rdata & ~csr_wsrc;
            default          : csr_next = csr_rdata;
        endcase
    end
    // csrrw always writes; csrrs/csrrc with rs1==0 don't (so a plain
    // csr-read has no side effect)
    wire csr_will_write = csr_access &
        ((csr_cmd == `CSR_RW) || (csr_cmd == `CSR_RWI) || csr_rs1_nz);

    // priority each cycle: reset > trap entry > mret > explicit CSR write
    integer unused;
    always @(posedge clk) begin
        if (rst) begin
            mstatus  <= 32'd0;    // interrupts disabled out of reset
            mtvec    <= 32'd0;
            mepc     <= 32'd0;
            mcause   <= 32'd0;
            mtval    <= 32'd0;
            mscratch <= 32'd0;
            mie      <= 32'd0;
            mcycle   <= 32'd0;
            minstret <= 32'd0;
            mtimecmp <= 32'd0;
        end else begin
            // counters: mcycle every cycle, minstret for each retired instr
            mcycle   <= mcycle + 32'd1;
            if (ex_valid && !trap)
                minstret <= minstret + 32'd1;

            if (trap) begin
                // enter the trap: save context, disable interrupts
                mepc              <= pc;
                mcause            <= cause;
                mtval             <= 32'd0;
                mstatus[`MSTATUS_MPIE] <= mstatus[`MSTATUS_MIE];
                mstatus[`MSTATUS_MIE]  <= 1'b0;
            end else if (mret) begin
                // return: restore the previous interrupt-enable
                mstatus[`MSTATUS_MIE]  <= mstatus[`MSTATUS_MPIE];
                mstatus[`MSTATUS_MPIE] <= 1'b1;
            end else if (csr_will_write) begin
                // an explicit CSR write from software
                case (csr_addr)
                    `CSR_MSTATUS : mstatus  <= csr_next;
                    `CSR_MIE     : mie       <= csr_next;
                    `CSR_MTVEC   : mtvec     <= csr_next;
                    `CSR_MSCRATCH: mscratch  <= csr_next;
                    `CSR_MEPC    : mepc       <= csr_next;
                    `CSR_MCAUSE  : mcause     <= csr_next;
                    `CSR_MTVAL   : mtval       <= csr_next;
                    `CSR_MCYCLE  : mcycle      <= csr_next;
                    `CSR_MINSTRET: minstret    <= csr_next;
                    `CSR_MTIMECMP: mtimecmp    <= csr_next;  // arms/acks the timer
                    default      : ; // read-only or unimplemented: ignore write
                endcase
            end
        end
    end

endmodule
