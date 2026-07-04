// ============================================================================
//  rvc_decompress.v  —  expand a 16-bit RVC instruction into its 32-bit form
// ----------------------------------------------------------------------------
//  The "C" (compressed) extension lets the most common instructions be encoded
//  in 16 bits instead of 32, shrinking code by ~25-30%. The elegant part: a
//  compressed instruction is always exactly equivalent to one ordinary 32-bit
//  instruction, so a core can support C with a purely combinational
//  DECOMPRESSOR in front of the decoder — the rest of the datapath never has to
//  know. This is that block.
//
//  It covers the RV32C set (the quadrants below). Anything reserved/unknown
//  raises `illegal`. Wiring it into fetch also needs a PC that can step by 2
//  and reassemble 32-bit instructions that straddle a 4-byte boundary — see
//  docs/ROADMAP.md; this module is the hard combinational core of that work and
//  is verified against golden 32-bit encodings in tests/tb_rvc.v.
//
//  The RVC immediate bit-scrambling is famously irregular; each case below is
//  annotated with the field mapping from the RISC-V spec.
// ============================================================================
module rvc_decompress (
    input  wire [15:0] c,          // the 16-bit compressed instruction
    output reg  [31:0] insn,       // equivalent 32-bit instruction
    output reg         illegal
);
    // common field extractions
    wire [1:0] quad   = c[1:0];
    wire [2:0] funct3 = c[15:13];
    wire [4:0] rd     = c[11:7];        // also rs1 (full 5-bit)
    wire [4:0] rs2    = c[6:2];         // full 5-bit
    wire [4:0] rd_p   = {2'b01, c[4:2]};   // x8..x15  (compressed 3-bit)
    wire [4:0] rs1_p  = {2'b01, c[9:7]};
    wire [4:0] rs2_p  = {2'b01, c[4:2]};

    // 32-bit encoders (mirrors of the assembler's)
    function [31:0] enc_i(input [11:0] imm, input [4:0] r1, input [2:0] f3,
                          input [4:0] rdst, input [6:0] opc);
        enc_i = {imm, r1, f3, rdst, opc};
    endfunction
    function [31:0] enc_r(input [6:0] f7, input [4:0] r2, input [4:0] r1,
                          input [2:0] f3, input [4:0] rdst, input [6:0] opc);
        enc_r = {f7, r2, r1, f3, rdst, opc};
    endfunction
    function [31:0] enc_s(input [11:0] imm, input [4:0] r2, input [4:0] r1,
                          input [2:0] f3, input [6:0] opc);
        enc_s = {imm[11:5], r2, r1, f3, imm[4:0], opc};
    endfunction
    function [31:0] enc_b(input [12:0] imm, input [4:0] r2, input [4:0] r1,
                          input [2:0] f3, input [6:0] opc);
        enc_b = {imm[12], imm[10:5], r2, r1, f3, imm[4:1], imm[11], opc};
    endfunction
    function [31:0] enc_j(input [20:0] imm, input [4:0] rdst, input [6:0] opc);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rdst, opc};
    endfunction
    function [31:0] enc_u(input [19:0] imm20, input [4:0] rdst, input [6:0] opc);
        enc_u = {imm20, rdst, opc};
    endfunction

    // ---- immediates (each per the spec's scrambled bit order) --------------
    // CI-type ADDI/LI/SLLI: imm[5]=c[12], imm[4:0]=c[6:2], sign-extended
    wire [31:0] imm_ci  = {{26{c[12]}}, c[12], c[6:2]};
    // C.ADDI16SP: imm[9]=c[12],[8:7]? -> {c[12],c[4:3],c[5],c[2],c[6]}<<4
    wire [31:0] imm_16sp= {{22{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'b0};
    // C.LUI: imm[17]=c[12], imm[16:12]=c[6:2], sign-extended (nzimm<<12)
    wire [31:0] imm_lui = {{14{c[12]}}, c[12], c[6:2], 12'b0};
    // C.ADDI4SPN: zero-extended scaled-by-4 immediate off x2
    wire [11:0] imm_4spn= {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b00};
    // CL/CS word offset (C.LW/C.SW): uimm[5:3]=c[12:10], [2]=c[6], [6]=c[5]
    wire [11:0] imm_lw  = {5'b0, c[5], c[12:10], c[6], 2'b00};
    // C.LWSP: uimm[5]=c[12], [4:2]=c[6:4], [7:6]=c[3:2]
    wire [11:0] imm_lwsp= {4'b0, c[3:2], c[12], c[6:4], 2'b00};
    // C.SWSP: uimm[5:2]=c[12:9], [7:6]=c[8:7]
    wire [11:0] imm_swsp= {4'b0, c[8:7], c[12:9], 2'b00};
    // CB shift amount (C.SRLI/SRAI/SLLI): shamt = {c[12],c[6:2]}
    wire [4:0]  shamt   = c[6:2];
    // CB branch offset (C.BEQZ/BNEZ)
    wire [12:0] imm_cb  = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
    // CJ jump offset (C.J/C.JAL)
    wire [20:0] imm_cj  = {{9{c[12]}}, c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
    // CI ANDI immediate (sign-extended 6-bit)
    wire [11:0] imm_andi= {{6{c[12]}}, c[12], c[6:2]};

    always @(*) begin
        insn    = 32'h00000013;    // default: NOP (addi x0,x0,0)
        illegal = 1'b0;
        case ({funct3, quad})
            // ================= Quadrant 0 =================
            {3'b000, 2'b00}: begin  // C.ADDI4SPN -> addi rd', x2, nzuimm
                if (c[12:5] == 8'b0) illegal = 1'b1;   // all-zero imm reserved
                else insn = enc_i(imm_4spn, 5'd2, 3'b000, rd_p, 7'b0010011);
            end
            {3'b010, 2'b00}:        // C.LW -> lw rd', off(rs1')
                insn = enc_i(imm_lw, rs1_p, 3'b010, rd_p, 7'b0000011);
            {3'b110, 2'b00}:        // C.SW -> sw rs2', off(rs1')
                insn = enc_s(imm_lw, rs2_p, rs1_p, 3'b010, 7'b0100011);

            // ================= Quadrant 1 =================
            {3'b000, 2'b01}:        // C.ADDI -> addi rd, rd, imm (or NOP)
                insn = enc_i(imm_ci[11:0], rd, 3'b000, rd, 7'b0010011);
            {3'b001, 2'b01}:        // C.JAL -> jal x1, off   (RV32 only)
                insn = enc_j(imm_cj, 5'd1, 7'b1101111);
            {3'b010, 2'b01}:        // C.LI -> addi rd, x0, imm
                insn = enc_i(imm_ci[11:0], 5'd0, 3'b000, rd, 7'b0010011);
            {3'b011, 2'b01}: begin  // C.LUI / C.ADDI16SP
                if (rd == 5'd2)     // rd==x2 -> C.ADDI16SP
                    insn = enc_i(imm_16sp[11:0], 5'd2, 3'b000, 5'd2, 7'b0010011);
                else if (rd != 5'd0 && imm_lui[31:12] != 20'b0)
                    insn = enc_u(imm_lui[31:12], rd, 7'b0110111);   // C.LUI
                else illegal = 1'b1;
            end
            {3'b100, 2'b01}: begin  // C.SRLI/SRAI/ANDI + reg-reg (SUB/XOR/OR/AND)
                case (c[11:10])
                    2'b00: insn = enc_r(7'b0000000, shamt, rs1_p, 3'b101, rs1_p, 7'b0010011); // SRLI
                    2'b01: insn = enc_r(7'b0100000, shamt, rs1_p, 3'b101, rs1_p, 7'b0010011); // SRAI
                    2'b10: insn = enc_i(imm_andi, rs1_p, 3'b111, rs1_p, 7'b0010011);          // ANDI
                    2'b11: case (c[6:5])                                                       // reg-reg
                        2'b00: insn = enc_r(7'b0100000, rs2_p, rs1_p, 3'b000, rs1_p, 7'b0110011); // SUB
                        2'b01: insn = enc_r(7'b0000000, rs2_p, rs1_p, 3'b100, rs1_p, 7'b0110011); // XOR
                        2'b10: insn = enc_r(7'b0000000, rs2_p, rs1_p, 3'b110, rs1_p, 7'b0110011); // OR
                        2'b11: insn = enc_r(7'b0000000, rs2_p, rs1_p, 3'b111, rs1_p, 7'b0110011); // AND
                    endcase
                endcase
            end
            {3'b101, 2'b01}:        // C.J -> jal x0, off
                insn = enc_j(imm_cj, 5'd0, 7'b1101111);
            {3'b110, 2'b01}:        // C.BEQZ -> beq rs1', x0, off
                insn = enc_b(imm_cb, 5'd0, rs1_p, 3'b000, 7'b1100011);
            {3'b111, 2'b01}:        // C.BNEZ -> bne rs1', x0, off
                insn = enc_b(imm_cb, 5'd0, rs1_p, 3'b001, 7'b1100011);

            // ================= Quadrant 2 =================
            {3'b000, 2'b10}:        // C.SLLI -> slli rd, rd, shamt
                insn = enc_r(7'b0000000, shamt, rd, 3'b001, rd, 7'b0010011);
            {3'b010, 2'b10}: begin  // C.LWSP -> lw rd, off(x2)
                if (rd == 5'd0) illegal = 1'b1;
                else insn = enc_i(imm_lwsp, 5'd2, 3'b010, rd, 7'b0000011);
            end
            {3'b100, 2'b10}: begin  // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
                if (c[12] == 1'b0) begin
                    if (rs2 == 5'd0) begin
                        if (rd == 5'd0) illegal = 1'b1;                 // reserved
                        else insn = enc_i(12'b0, rd, 3'b000, 5'd0, 7'b1100111); // C.JR -> jalr x0,0(rd)
                    end else
                        insn = enc_r(7'b0, rs2, 5'd0, 3'b000, rd, 7'b0110011);  // C.MV -> add rd,x0,rs2
                end else begin
                    if (rs2 == 5'd0) begin
                        if (rd == 5'd0)
                            insn = 32'h00100073;                       // C.EBREAK
                        else
                            insn = enc_i(12'b0, rd, 3'b000, 5'd1, 7'b1100111); // C.JALR -> jalr x1,0(rd)
                    end else
                        insn = enc_r(7'b0, rs2, rd, 3'b000, rd, 7'b0110011);   // C.ADD -> add rd,rd,rs2
                end
            end
            {3'b110, 2'b10}:        // C.SWSP -> sw rs2, off(x2)
                insn = enc_s(imm_swsp, rs2, 5'd2, 3'b010, 7'b0100011);

            default: illegal = 1'b1;
        endcase
        if (quad == 2'b11) illegal = 1'b1;   // not compressed at all
    end

endmodule
