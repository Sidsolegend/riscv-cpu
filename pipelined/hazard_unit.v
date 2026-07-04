// ============================================================================
//  hazard_unit.v  —  handles the ONE data hazard forwarding can't fix
// ----------------------------------------------------------------------------
//  Forwarding solves almost everything, but not the LOAD-USE hazard:
//
//      lw  x1, 0(x2)      <- x1 isn't known until the END of the MEM stage
//      add x4, x1, x5     <- needs x1 at the START of its EX stage
//
//  The loaded value simply doesn't exist yet in time to forward — there's a
//  one-cycle gap that no wire can close. The only fix is to STALL: freeze the
//  younger instruction for one cycle (insert a "bubble"), after which the
//  loaded value is available in MEM/WB and normal forwarding takes over.
//
//  Detecting it: the instruction in EX is a load (idex_mem_read), and the
//  instruction right behind it (in ID) reads the register that load targets.
//
//  When detected we assert `stall`, which the top level uses to:
//     - freeze the PC          (don't fetch a new instruction)
//     - freeze the IF/ID reg   (hold the stalled instruction in place)
//     - inject a bubble into ID/EX (clear its control signals for one cycle)
// ============================================================================

module hazard_unit (
    input  wire        idex_mem_read,  // is the instruction in EX a load?
    input  wire [4:0]  idex_rd,        // the load's destination register
    input  wire [4:0]  ifid_rs1,       // registers the ID instruction needs
    input  wire [4:0]  ifid_rs2,
    output wire        stall
);
    // Stall for exactly one cycle when a load is immediately followed by an
    // instruction that uses its result.
    assign stall = idex_mem_read && (idex_rd != 5'd0) &&
                   ((idex_rd == ifid_rs1) || (idex_rd == ifid_rs2));

endmodule
