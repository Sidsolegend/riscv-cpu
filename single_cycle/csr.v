// ============================================================================
//  csr.v  —  Control & Status Registers + machine-mode trap logic (Zicsr)
// ----------------------------------------------------------------------------
//  This is what turns a bare datapath into something an operating system (or
//  at least an interrupt handler) could run on. It holds the machine-mode CSRs
//  and implements the three things a trap needs:
//
//    1. CSR read-modify-write  — csrrw / csrrs / csrrc (and the *i immediate
//       forms). Software reads the old value into rd and writes a new one.
//
//    2. Taking a trap          — on ecall / ebreak / illegal-instruction, or a
//       pending machine-timer interrupt, we save the current PC into mepc, the
//       reason into mcause, disable interrupts (MPIE<-MIE, MIE<-0), and hand
//       the top level a vector address (mtvec) to jump to.
//
//    3. Returning from a trap  — mret restores MIE from MPIE and hands back
//       mepc so the top level can resume the interrupted program.
//
//  The machine timer is deliberately simple: mcycle is a free-running counter,
//  and an interrupt is requested whenever (mie.MTIE & mcycle >= mtimecmp).
//  Writing mtimecmp (custom CSR 0x7C0) both arms and acknowledges the timer,
//  exactly like a real CLINT — just via a CSR instead of a memory-mapped reg,
//  to keep the datapath self-contained.
//
//  Purely machine mode, single hart — no delegation, no user/supervisor. That
//  is all this core needs, and it maps 1:1 onto the RISC-V privileged spec.
// ============================================================================
`include "defines.vh"

module csr (
    input  wire        clk,
    input  wire        rst,

    // ---- CSR access port (driven by csrrw/csrrs/csrrc[i]) ------------------
    input  wire        csr_access,   // a CSR instruction is executing
    input  wire [11:0] csr_addr,     // which CSR (instr[31:20])
    input  wire [2:0]  csr_cmd,      // funct3: CSR_RW / CSR_RS / CSR_RC / *I
    input  wire [31:0] csr_wsrc,     // rs1 value, or the zero-extended imm
    input  wire        csr_rs1_nz,   // rs1 field != 0 (rs/rc skip write if zero)
    output reg  [31:0] csr_rdata,    // old value of the addressed CSR -> rd

    // ---- trap request from the datapath ------------------------------------
    input  wire        ex_valid,     // the instruction in flight actually retires
    input  wire [31:0] pc,           // PC of that instruction (candidate mepc)
    input  wire        exc_ecall,    // ecall  encountered
    input  wire        exc_ebreak,   // ebreak encountered
    input  wire        exc_illegal,  // illegal / unimplemented instruction
    input  wire        do_mret,      // mret encountered

    // ---- trap response to the datapath -------------------------------------
    output wire        trap,         // take a trap THIS cycle -> redirect to mtvec
    output wire [31:0] trap_vector,  // where to jump on a trap (mtvec, direct)
    output wire        mret,         // returning from a trap -> redirect to mepc
    output wire [31:0] mret_target   // mepc
);
    // -------------------------------------------------------------------------
    //  The register state
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    //  Interrupt request: level-triggered while mcycle has reached mtimecmp.
    //  Gated by both the global enable (mstatus.MIE) and the timer enable
    //  (mie.MTIE). mtimecmp==0 means "timer disabled" (its reset state), so
    //  none of the existing programs ever see an interrupt.
    // -------------------------------------------------------------------------
    wire timer_fire = (mtimecmp != 32'd0) && (mcycle >= mtimecmp);
    wire mtip       = timer_fire;                       // mip.MTIP (live)
    wire irq_timer  = mstatus[`MSTATUS_MIE] & mie[`IRQ_MTIP] & mtip;

    // A synchronous exception from the current instruction.
    wire exc_sync = exc_ecall | exc_ebreak | exc_illegal;

    // Take a trap when the in-flight instruction retires and either an
    // interrupt is pending or it raised a synchronous exception. Interrupts
    // are taken with priority (checked first below when forming the cause).
    assign trap        = ex_valid & (irq_timer | exc_sync);
    assign trap_vector = {mtvec[31:2], 2'b00};          // direct mode
    assign mret        = ex_valid & do_mret;
    assign mret_target = mepc;

    // Cause encoding (interrupt wins over a simultaneous synchronous exception).
    wire [31:0] cause =
        irq_timer   ? `CAUSE_MTIMER  :
        exc_illegal ? `CAUSE_ILLEGAL :
        exc_ebreak  ? `CAUSE_EBREAK  :
                      `CAUSE_ECALL_M ;

    // -------------------------------------------------------------------------
    //  CSR read (combinational). Unimplemented CSRs read as 0.
    // -------------------------------------------------------------------------
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

    // The value a csrrw/csrrs/csrrc[i] wants to store (based on the old value).
    reg [31:0] csr_next;
    always @(*) begin
        case (csr_cmd)
            `CSR_RW, `CSR_RWI: csr_next = csr_wsrc;
            `CSR_RS, `CSR_RSI: csr_next = csr_rdata |  csr_wsrc;
            `CSR_RC, `CSR_RCI: csr_next = csr_rdata & ~csr_wsrc;
            default          : csr_next = csr_rdata;
        endcase
    end
    // csrrs/csrrc (and their immediate forms) with a zero source do NOT write
    // (so a plain csr-read has no side effects). csrrw always writes.
    wire csr_will_write = csr_access &
        ((csr_cmd == `CSR_RW) || (csr_cmd == `CSR_RWI) || csr_rs1_nz);

    // -------------------------------------------------------------------------
    //  Sequential update. Precedence each cycle:
    //     reset  >  trap entry  >  mret  >  explicit CSR write
    //  The counters always advance.
    // -------------------------------------------------------------------------
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
