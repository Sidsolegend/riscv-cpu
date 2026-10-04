// Load-use hazard, the one case forwarding can't reach: `lw x1,0(x2)`
// followed immediately by something that reads x1. The loaded value isn't
// known until the end of MEM, but the next instruction needs it at the
// start of its EX -- one cycle too late for any bypass wire, so we stall
// instead: freeze PC + IF/ID for a cycle and let a bubble fall into ID/EX.
// After that, MEM/WB has the value and ordinary forwarding takes over.

module hazard_unit (
    input  wire        idex_mem_read,  // load sitting in EX
    input  wire [4:0]  idex_rd,
    input  wire [4:0]  ifid_rs1,       // registers the instruction behind it needs
    input  wire [4:0]  ifid_rs2,
    output wire        stall
);
    assign stall = idex_mem_read && (idex_rd != 5'd0) &&
                   ((idex_rd == ifid_rs1) || (idex_rd == ifid_rs2));

endmodule
