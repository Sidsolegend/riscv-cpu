// ============================================================================
//  tb_bpred.v  —  self-checking test for the branch predictor
// ----------------------------------------------------------------------------
//  Checks the two things that make the predictor correct:
//    1. 2-bit counter hysteresis — after training a branch taken repeatedly it
//       predicts taken, and a SINGLE not-taken outcome does not immediately
//       flip the prediction (that's the whole point of two bits).
//    2. BTB behaviour — an untrained PC misses (predict not-taken), and once a
//       taken branch is recorded the predictor returns its exact target.
// ============================================================================
`timescale 1ns/1ps

module tb_bpred;
    reg         clk = 0, rst = 1;
    reg  [31:0] pc_predict = 0;
    wire        predict_taken;
    wire [31:0] predict_target;
    reg         update_en = 0, update_taken = 0;
    reg  [31:0] update_pc = 0, update_target = 0;

    branch_predictor #(.IDX(6)) DUT (
        .clk(clk), .rst(rst),
        .pc_predict(pc_predict), .predict_taken(predict_taken),
        .predict_target(predict_target),
        .update_en(update_en), .update_pc(update_pc),
        .update_taken(update_taken), .update_target(update_target));

    always #5 clk = ~clk;

    integer errors = 0;
    localparam [31:0] BR_PC  = 32'h0000_1000;
    localparam [31:0] BR_TGT = 32'h0000_0F00;   // a backward (loop) branch

    task train(input taken, input [31:0] tgt);
        begin
            @(posedge clk);
            update_en <= 1; update_pc <= BR_PC; update_taken <= taken; update_target <= tgt;
            @(posedge clk);
            update_en <= 0;
            #1;
        end
    endtask

    task expect_pred(input [8*40-1:0] label, input exp_taken);
        begin
            pc_predict = BR_PC; #1;
            if (predict_taken !== exp_taken) begin
                $display("  FAIL  %0s: predict_taken=%b (want %b)", label, predict_taken, exp_taken);
                errors = errors + 1;
            end else $display("  PASS  %0s", label);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); rst = 0; #1;
        $display("---- branch predictor ----");

        // fresh entry: BTB miss -> not taken
        expect_pred("cold branch predicts not-taken", 1'b0);

        // train taken a few times -> should predict taken, BTB target set
        train(1, BR_TGT);
        train(1, BR_TGT);
        expect_pred("after 2 taken -> taken", 1'b1);

        pc_predict = BR_PC; #1;
        if (predict_target !== BR_TGT) begin
            $display("  FAIL  BTB target = %08x (want %08x)", predict_target, BR_TGT);
            errors = errors + 1;
        end else $display("  PASS  BTB returns the trained target");

        // now strongly-taken (11); one not-taken -> weakly-taken (10), STILL taken
        train(1, BR_TGT);                 // saturate to 11
        train(0, BR_TGT);                 // 11 -> 10
        expect_pred("hysteresis: 1 miss stays taken", 1'b1);

        // a second not-taken -> 01, now flips to not-taken
        train(0, BR_TGT);                 // 10 -> 01
        expect_pred("second miss flips to not-taken", 1'b0);

        if (errors == 0) $display("RESULT: ALL BRANCH-PREDICTOR TESTS PASSED  \342\234\205");
        else             $display("RESULT: %0d BRANCH-PREDICTOR TEST(S) FAILED", errors);
        $finish;
    end
endmodule
