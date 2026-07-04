// ============================================================================
//  branch_predictor.v  —  2-bit saturating-counter predictor + BTB
// ----------------------------------------------------------------------------
//  The pipeline resolves branches in EX, so every TAKEN branch throws away the
//  two instructions fetched behind it (a 2-cycle flush). On a loop that runs a
//  thousand times, that's two wasted cycles a thousand times. A branch
//  predictor guesses the outcome in the FETCH stage so the common case — the
//  loop branch that is taken again and again — costs nothing.
//
//  Two tables, indexed by the low PC bits:
//    * BHT — a 2-bit saturating counter per entry. Values mean
//        00 strongly-not-taken  01 weakly-not-taken
//        10 weakly-taken        11 strongly-taken
//      The top bit is the prediction. Two bits (not one) give hysteresis: a
//      single surprise doesn't flip a well-established prediction, so the last
//      iteration of a loop doesn't poison the next run.
//    * BTB — remembers the TARGET of a taken branch (tagged + valid), so the
//      fetch stage knows *where* to redirect, not just that it should.
//
//  Predict combinationally from `pc_predict`; when a branch resolves, pulse
//  `update_en` with its real PC/outcome/target to train both tables. This is a
//  drop-in module — see docs/ROADMAP.md for wiring it into the IF stage — and
//  is verified in tests/tb_bpred.v (counter hysteresis + BTB hit/miss).
// ============================================================================
module branch_predictor #(
    parameter IDX = 6                       // 2^IDX entries per table
)(
    input  wire        clk,
    input  wire        rst,
    // ---- predict port (FETCH) ----
    input  wire [31:0] pc_predict,
    output wire        predict_taken,
    output wire [31:0] predict_target,
    // ---- update port (EX, when a branch actually resolves) ----
    input  wire        update_en,
    input  wire [31:0] update_pc,
    input  wire        update_taken,
    input  wire [31:0] update_target
);
    localparam ENTRIES = (1 << IDX);
    localparam TAGW    = 32 - IDX - 2;      // bits above the index (word-aligned PC)

    reg [1:0]        bht [0:ENTRIES-1];
    reg [TAGW-1:0]   btb_tag [0:ENTRIES-1];
    reg [31:0]       btb_tgt [0:ENTRIES-1];
    reg              btb_val [0:ENTRIES-1];

    integer i;
    initial begin
        for (i = 0; i < ENTRIES; i = i + 1) begin
            bht[i]     = 2'b01;             // weakly not-taken
            btb_val[i] = 1'b0;
            btb_tag[i] = {TAGW{1'b0}};
            btb_tgt[i] = 32'd0;
        end
    end

    // ---- prediction (combinational) ----
    wire [IDX-1:0]  p_idx = pc_predict[IDX+1:2];
    wire [TAGW-1:0] p_tag = pc_predict[31:IDX+2];
    wire            hit   = btb_val[p_idx] && (btb_tag[p_idx] == p_tag);

    assign predict_taken  = hit && bht[p_idx][1];   // top counter bit = guess
    assign predict_target = btb_tgt[p_idx];

    // ---- training (sequential) ----
    wire [IDX-1:0]  u_idx = update_pc[IDX+1:2];
    wire [TAGW-1:0] u_tag = update_pc[31:IDX+2];
    wire [1:0]      c     = bht[u_idx];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                bht[i]     <= 2'b01;
                btb_val[i] <= 1'b0;
            end
        end else if (update_en) begin
            // saturating 2-bit counter
            if (update_taken) bht[u_idx] <= (c == 2'b11) ? 2'b11 : c + 2'b01;
            else              bht[u_idx] <= (c == 2'b00) ? 2'b00 : c - 2'b01;
            // record the target of taken branches in the BTB
            if (update_taken) begin
                btb_val[u_idx] <= 1'b1;
                btb_tag[u_idx] <= u_tag;
                btb_tgt[u_idx] <= update_target;
            end
        end
    end

endmodule
