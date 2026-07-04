// ============================================================================
//  forwarding_unit.v  —  solves most DATA HAZARDS without stalling
// ----------------------------------------------------------------------------
//  THE PROBLEM (a data hazard):
//      add x1, x2, x3     <- produces x1, but x1 only reaches the register
//      sub x4, x1, x5     <- needs x1 NOW, one cycle later
//  In a pipeline, `add` hasn't written x1 back yet when `sub` needs it. If we
//  just read the register file, `sub` would grab the OLD x1. Wrong answer.
//
//  THE FIX (forwarding, a.k.a. bypassing):
//      The value `add` computes is already sitting in a pipeline register
//      (EX/MEM, then MEM/WB) before it's written back. So we "forward" it
//      straight to the ALU inputs of `sub`, skipping the register file.
//
//  This unit looks at the two instructions AHEAD of the one in EX and decides,
//  for each ALU operand, where the freshest value lives:
//      2'b00 = use the value from the register file (no hazard)
//      2'b10 = forward from EX/MEM stage  (instruction 1 ahead — most recent)
//      2'b01 = forward from MEM/WB stage  (instruction 2 ahead)
//
//  Priority matters: EX/MEM is checked first because it's the MORE RECENT
//  producer, so its value must win over an older MEM/WB value.
// ============================================================================

module forwarding_unit (
    input  wire        exmem_reg_write,  // will EX/MEM stage write a register?
    input  wire [4:0]  exmem_rd,         // ...which register?
    input  wire        memwb_reg_write,  // will MEM/WB stage write a register?
    input  wire [4:0]  memwb_rd,         // ...which register?
    input  wire [4:0]  idex_rs1,         // register the EX instruction reads (A)
    input  wire [4:0]  idex_rs2,         // register the EX instruction reads (B)
    output reg  [1:0]  forward_a,        // mux select for ALU input A
    output reg  [1:0]  forward_b         // mux select for ALU input B
);

    always @(*) begin
        // ---- operand A ----
        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs1)
            forward_a = 2'b10;                 // freshest: from EX/MEM
        else if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == idex_rs1)
            forward_a = 2'b01;                 // next best: from MEM/WB
        else
            forward_a = 2'b00;                 // no hazard: use register file

        // ---- operand B (same logic) ----
        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs2)
            forward_b = 2'b10;
        else if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == idex_rs2)
            forward_b = 2'b01;
        else
            forward_b = 2'b00;
    end

endmodule
