// Cycle-by-cycle trace of the single-cycle core: prints PC, raw instruction,
// a rough disassembly, and the watched registers every clock. Useful for
// tracking down exactly where a wrong result comes from (this is what
// caught the WB/ID hazard on the pipeline -- see the debugging notes).
`timescale 1ns/1ps

module tb_watch;

    reg clk = 0;
    reg rst = 1;
    wire [31:0] pc, instr;

    riscv_single #(.PROG("programs/sum.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    always #5 clk = ~clk;

    // ---- a tiny disassembler: turns the raw instruction bits into text ----
    function automatic string disasm;
        input [31:0] ins;
        reg [6:0] opc; reg [4:0] rd, rs1, rs2; reg [2:0] f3;
        begin
            opc = ins[6:0]; rd = ins[11:7]; f3 = ins[14:12];
            rs1 = ins[19:15]; rs2 = ins[24:20];
            case (opc)
                7'b0010011: case(f3)
                    3'b000: disasm = $sformatf("addi x%0d, x%0d, %0d", rd, rs1, $signed(ins[31:20]));
                    default: disasm = "i-type";
                endcase
                7'b0110011: begin
                    case(f3)
                        3'b000: begin
                            if (ins[30]) disasm = $sformatf("sub  x%0d, x%0d, x%0d", rd, rs1, rs2);
                            else         disasm = $sformatf("add  x%0d, x%0d, x%0d", rd, rs1, rs2);
                        end
                        default: disasm = "r-type";
                    endcase
                end
                7'b1100011: disasm = $sformatf("beq  x%0d, x%0d, offset", rs1, rs2);
                7'b1101111: disasm = $sformatf("jal  x%0d, offset", rd);
                7'b0100011: disasm = $sformatf("sw   x%0d, offset(x%0d)", rs2, rs1);
                7'b0000011: disasm = $sformatf("lw   x%0d, offset(x%0d)", rd, rs1);
                default: disasm = "?";
            endcase
        end
    endfunction

    integer cycle = 0;
    reg [31:0] prev_x1, prev_x2, prev_x3, prev_x5;

    initial begin
        repeat (2) @(posedge clk);
        rst = 0;
        $display("");
        $display("cyc | PC   | instruction (raw) | decoded          | registers (x1 x2 x3 x5)");
        $display("----|------|--------------------|-----------------  |-----------------------");

        repeat (30) begin
            @(posedge clk);
            cycle = cycle + 1;
            #1; // let signals settle just after the clock edge
            $display("%3d | %04h | %h          | %-16s | x1=%0d x2=%0d x3=%0d x5=%0d",
                cycle, pc, instr, disasm(instr),
                dut.RF.regs[1], dut.RF.regs[2], dut.RF.regs[3], dut.RF.regs[5]);
        end

        $display("");
        $display("Final: x1(sum)=%0d  x2(i)=%0d  x3(limit)=%0d  x5(reload)=%0d  mem[0]=%0d",
            dut.RF.regs[1], dut.RF.regs[2], dut.RF.regs[3], dut.RF.regs[5], dut.DMEM.mem[0]);
        $finish;
    end

endmodule
