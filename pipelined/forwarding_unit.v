// Forwarding unit. Looks at the two instructions ahead of the one currently
// in EX and picks, per ALU operand, where the freshest value for that
// register actually lives:
//   2'b00 = register file (no hazard)
//   2'b10 = EX/MEM        (producer is 1 instruction ahead -- most recent)
//   2'b01 = MEM/WB        (producer is 2 instructions ahead)
// EX/MEM is checked first on purpose: if both stages target the same
// register, the more recent write has to win.

module forwarding_unit (
    input  wire        exmem_reg_write,
    input  wire [4:0]  exmem_rd,
    input  wire        memwb_reg_write,
    input  wire [4:0]  memwb_rd,
    input  wire [4:0]  idex_rs1,
    input  wire [4:0]  idex_rs2,
    output reg  [1:0]  forward_a,
    output reg  [1:0]  forward_b
);

    always @(*) begin
        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs1)
            forward_a = 2'b10;
        else if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == idex_rs1)
            forward_a = 2'b01;
        else
            forward_a = 2'b00;

        if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs2)
            forward_b = 2'b10;
        else if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == idex_rs2)
            forward_b = 2'b01;
        else
            forward_b = 2'b00;
    end

endmodule
