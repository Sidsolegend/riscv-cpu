// ============================================================================
//  defines.vh  —  Shared constants for the RV32I single-cycle core
// ----------------------------------------------------------------------------
//  This file is `include`d by every module so the "magic numbers" (opcodes,
//  ALU operation codes, result-source selects) live in ONE place with names
//  instead of being scattered as raw bit patterns. Read this first — every
//  other file refers back to these names.
// ============================================================================
`ifndef RV32I_DEFINES
`define RV32I_DEFINES

// ---- RV32I opcodes (instruction bits [6:0]) --------------------------------
//  The opcode is the first thing the control unit looks at to decide what
//  kind of instruction this is (arithmetic? load? branch? jump?).
`define OPC_RTYPE   7'b0110011   // add sub and or xor slt sll srl sra  (reg,reg)
`define OPC_ITYPE   7'b0010011   // addi andi ori xori slti slli srli   (reg,imm)
`define OPC_LOAD    7'b0000011   // lw
`define OPC_STORE   7'b0100011   // sw
`define OPC_BRANCH  7'b1100011   // beq bne blt bge
`define OPC_JAL     7'b1101111   // jal
`define OPC_JALR    7'b1100111   // jalr
`define OPC_LUI     7'b0110111   // lui
`define OPC_AUIPC   7'b0010111   // auipc
`define OPC_SYSTEM  7'b1110011   // ecall ebreak mret + csrrw/s/c[i]  (Zicsr)
`define OPC_FENCE   7'b0001111   // fence / fence.i  (treated as a no-op here)

// ---- ALU operation select (internal, 5 bits) -------------------------------
//  These are OUR OWN codes (not part of RISC-V). The ALU control unit maps
//  the instruction's funct3/funct7 fields onto one of these.
//  (Widened from 4 to 5 bits when the M extension added 8 more operations.)
`define ALU_ADD   5'd0
`define ALU_SUB   5'd1
`define ALU_AND   5'd2
`define ALU_OR    5'd3
`define ALU_XOR   5'd4
`define ALU_SLT   5'd5   // set-less-than, signed
`define ALU_SLTU  5'd6   // set-less-than, unsigned
`define ALU_SLL   5'd7   // shift left logical
`define ALU_SRL   5'd8   // shift right logical
`define ALU_SRA   5'd9   // shift right arithmetic
`define ALU_PASSB 5'd10  // pass operand B straight through (used by LUI)

// ---- M extension (RV32M): multiply / divide --------------------------------
//  Encoded as R-type with funct7 = 0000001. In this teaching core they are
//  single-cycle combinational (fine in simulation; real silicon would iterate
//  or pipeline the divider — that's a speed concern, not a correctness one).
`define ALU_MUL    5'd16  // low 32 bits of rs1 * rs2
`define ALU_MULH   5'd17  // high 32 bits, signed * signed
`define ALU_MULHSU 5'd18  // high 32 bits, signed * unsigned
`define ALU_MULHU  5'd19  // high 32 bits, unsigned * unsigned
`define ALU_DIV    5'd20  // signed divide    (div-by-0 -> -1, overflow -> INT_MIN)
`define ALU_DIVU   5'd21  // unsigned divide  (div-by-0 -> 0xFFFFFFFF)
`define ALU_REM    5'd22  // signed remainder (rem-by-0 -> dividend)
`define ALU_REMU   5'd23  // unsigned remainder

`define FUNCT7_M  7'b0000001   // R-type funct7 that selects the M extension

// ---- Memory-mapped I/O (decoded in dmem.v, addresses 0x10000000+) ----------
//  Anything at or above `MMIO_BASE` is a device, not RAM. This is how real
//  SoCs work: the same lw/sw instructions talk to hardware registers.
`define MMIO_BASE   32'h1000_0000
`define MMIO_UART   4'h0   // write: low byte prints to the console / real UART TX
`define MMIO_CYCLE  4'h4   // read : cycles since reset (a free-running counter)
`define MMIO_HALT   4'h8   // write: stop the simulation (value = exit code)
`define MMIO_LCD    4'hC   // write: low byte -> HD44780 character LCD (real HW)

// ---- Result source select (which value gets written back to the register) --
`define RES_ALU    2'b00   // ALU output      (arithmetic / logic)
`define RES_MEM    2'b01   // data memory     (loads)
`define RES_PC4    2'b10   // PC + 4          (jal/jalr return address)
`define RES_CSR    2'b11   // CSR read value  (csrrw/csrrs/csrrc and immediates)

// ============================================================================
//  Zicsr + trap/interrupt support (machine mode only)
// ----------------------------------------------------------------------------
//  SYSTEM-opcode funct3 selects: 0 = privileged (ecall/ebreak/mret), else a
//  CSR read-modify-write. The immediate forms take a 5-bit zero-extended
//  constant from the rs1 field instead of a register.
// ============================================================================
`define SYS_PRIV    3'b000   // funct3==0 -> ecall / ebreak / mret / wfi
`define CSR_RW      3'b001   // csrrw  : csr = rs1
`define CSR_RS      3'b010   // csrrs  : csr |= rs1
`define CSR_RC      3'b011   // csrrc  : csr &= ~rs1
`define CSR_RWI     3'b101   // csrrwi : csr = zimm
`define CSR_RSI     3'b110   // csrrsi : csr |= zimm
`define CSR_RCI     3'b111   // csrrci : csr &= ~zimm

// funct12 (instr[31:20]) values for the privileged instructions
`define PRIV_ECALL  12'h000
`define PRIV_EBREAK 12'h001
`define PRIV_MRET   12'h302
`define PRIV_WFI    12'h105

// Machine-mode CSR addresses (the subset this core implements)
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MTIMECMP  12'h7C0   // custom: machine-timer compare (drives the IRQ)
`define CSR_CYCLE     12'hC00   // read-only user shadow of mcycle
`define CSR_TIME      12'hC01   // read-only: same cycle base
`define CSR_INSTRET   12'hC02   // read-only user shadow of minstret

// mstatus bit positions we use
`define MSTATUS_MIE   3    // global machine interrupt enable
`define MSTATUS_MPIE  7    // previous MIE (saved on trap, restored on mret)

// mie/mip bit position for the machine timer interrupt
`define IRQ_MTIP      7

// mcause values (top bit set => interrupt, else synchronous exception)
`define CAUSE_ILLEGAL   32'd2
`define CAUSE_EBREAK    32'd3
`define CAUSE_ECALL_M   32'd11
`define CAUSE_MTIMER    32'h8000_0007

`endif
