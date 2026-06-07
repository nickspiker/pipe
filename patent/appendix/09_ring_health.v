// =============================================================================
// ring_health.v — per-ring TRNG health monitor (Claim 3c, layered)
// =============================================================================
//
// Three concurrent checks per ring. Ring is declared healthy iff all pass:
//
//   1. RCT — NIST SP 800-90B Repetition Count Test. Instantaneous max-run detector. rct_fail latches if any run of identical samples exceeds RCT_C cycles.
//
//   2. APT — NIST SP 800-90B Adaptive Proportion Test. Windowed bias detector with sliding window of APT_W=1024 samples. apt_ref is captured as the first sample of each window; apt_count counts occurrences of apt_ref over the window; apt_fail latches if apt_count > APT_T for any window in the gather.
//
//   3. Iterated GF(2) differencing — K-level predictability detector. level_sample[0] = current sample level_sample[k] = level_sample[k-1] XOR level_prev[k-1]   (for k >= 1) Each level has its own popcount counter; at end-of-gather, every level's popcount must lie in [LVL_LO, LVL_HI]. Periodic patterns of period <= 2^K manifest as a level-k popcount far from W/2 at some k <= K.
//
// W samples per gather. First K samples are warmup (level prev chain fills up); popcount accumulators start on cycle K+1. Total accumulated samples per level = W - K = 65530 for default params, statistically indistinguishable from W under +/- 6sigma tolerance.
//
// Caller contract:
//   - `sample` is the already-synchronized ring output (2-FF sync upstream)
//   - assert `start` for exactly one cycle to begin a gather
//   - sample is valid every cycle while gather is in progress
//   - `done` pulses one cycle when gather completes; `healthy` is valid that cycle
//   - module returns to idle, ready for next `start`
//
// Defaults (W=65536, K=6, LVL_LO/HI = W/2 +/- 768) match the existing TRNG gather length in trng.v. Override parameters to retune.
//
// =============================================================================

`timescale 1ns / 1ps

module ring_health #(
    parameter integer W       = 65536,    // gather window (samples)
    parameter integer K       = 6,        // iterated diff levels
    parameter integer RCT_C   = 32,       // max run length before RCT fails
    parameter integer APT_W   = 1024,     // APT window
    parameter integer APT_T   = 614,      // APT cutoff (W=1024, H=1, alpha=2^-30)
    parameter integer LVL_LO  = 32000,    // level popcount lower bound
    parameter integer LVL_HI  = 33536     // level popcount upper bound
) (
    input  wire clk,
    input  wire reset_n,
    input  wire start,                    // 1-cycle pulse to begin gather
    input  wire sample,                   // 1-bit ring sample this cycle
    output reg  done,                     // 1-cycle pulse at end of gather
    output reg  healthy,                  // valid in cycle of done
    // Diagnostic surface (valid in cycle of done; unused ports default to wire)
    output reg          rct_fail_out,     // RCT (Repetition Count Test) tripped
    output reg          apt_fail_out,     // APT (Adaptive Proportion Test) tripped
    output reg  [K:0]   level_fail_mask   // bit k set if level k popcount out of range
);

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [1:0] ST_IDLE   = 2'd0,
                     ST_GATHER = 2'd1,
                     ST_DONE   = 2'd2;
    reg [1:0]  state;
    reg [16:0] sample_cnt;

    // -------------------------------------------------------------------------
    // RCT
    // -------------------------------------------------------------------------
    reg [6:0] rct_run;
    reg       rct_prev;
    reg       rct_fail;

    // -------------------------------------------------------------------------
    // APT
    // -------------------------------------------------------------------------
    reg [9:0]  apt_pos;
    reg [10:0] apt_count;
    reg        apt_ref;
    reg        apt_fail;

    // -------------------------------------------------------------------------
    // Iterated GF(2) differencing — K+1 levels (indices 0..K)
    // -------------------------------------------------------------------------
    wire [K:0]  level_sample;
    reg  [K:0]  level_prev;
    reg  [16:0] level_pop [0:K];
    reg  [3:0]  warmup_cnt;
    wire        warmup_done = (warmup_cnt >= K[3:0]);

    assign level_sample[0] = sample;
    genvar gk;
    generate
        for (gk = 1; gk <= K; gk = gk + 1) begin : g_level_xor
            assign level_sample[gk] = level_sample[gk-1] ^ level_prev[gk-1];
        end
    endgenerate

    // Per-level range check (combinational, valid at end of gather)
    wire [K:0] level_in_range;
    generate
        for (gk = 0; gk <= K; gk = gk + 1) begin : g_level_range
            assign level_in_range[gk] = (level_pop[gk] >= LVL_LO[16:0])
                                     && (level_pop[gk] <= LVL_HI[16:0]);
        end
    endgenerate
    wire all_levels_pass = &level_in_range;

    // -------------------------------------------------------------------------
    // Main always
    // -------------------------------------------------------------------------
    integer k_i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= ST_IDLE;
            sample_cnt  <= 17'd0;
            rct_run     <= 7'd0;
            rct_prev    <= 1'b0;
            rct_fail    <= 1'b0;
            apt_pos     <= 10'd0;
            apt_count   <= 11'd0;
            apt_ref     <= 1'b0;
            apt_fail    <= 1'b0;
            level_prev  <= {(K+1){1'b0}};
            for (k_i = 0; k_i <= K; k_i = k_i + 1)
                level_pop[k_i] <= 17'd0;
            warmup_cnt  <= 4'd0;
            done        <= 1'b0;
            healthy     <= 1'b0;
            rct_fail_out    <= 1'b0;
            apt_fail_out    <= 1'b0;
            level_fail_mask <= {(K+1){1'b0}};
        end else begin
            done <= 1'b0;
            case (state)

                ST_IDLE: begin
                    if (start) begin
                        state       <= ST_GATHER;
                        sample_cnt  <= 17'd0;
                        rct_run     <= 7'd0;
                        rct_prev    <= 1'b0;
                        rct_fail    <= 1'b0;
                        apt_pos     <= 10'd0;
                        apt_count   <= 11'd0;
                        apt_ref     <= 1'b0;
                        apt_fail    <= 1'b0;
                        level_prev  <= {(K+1){1'b0}};
                        for (k_i = 0; k_i <= K; k_i = k_i + 1)
                            level_pop[k_i] <= 17'd0;
                        warmup_cnt  <= 4'd0;
                        healthy     <= 1'b0;
                    end
                end

                ST_GATHER: begin
                    // ---- RCT ----
                    if (sample_cnt == 17'd0) begin
                        // first sample seeds the run
                        rct_prev <= sample;
                        rct_run  <= 7'd1;
                    end else if (sample == rct_prev) begin
                        rct_run <= rct_run + 7'd1;
                        if (rct_run + 7'd1 > RCT_C[6:0])
                            rct_fail <= 1'b1;
                    end else begin
                        rct_run  <= 7'd1;
                        rct_prev <= sample;
                    end

                    // ---- APT ----
                    if (apt_pos == 10'd0) begin
                        // capture new ref, start counting (self matches self)
                        apt_ref   <= sample;
                        apt_count <= 11'd1;
                        apt_pos   <= 10'd1;
                    end else if (apt_pos == APT_W[9:0]-10'd1) begin
                        // end of APT window
                        if (apt_count + ((sample == apt_ref) ? 11'd1 : 11'd0)
                            > APT_T[10:0])
                            apt_fail <= 1'b1;
                        apt_pos <= 10'd0;   // next cycle captures new ref
                    end else begin
                        apt_pos   <= apt_pos + 10'd1;
                        apt_count <= apt_count +
                                     ((sample == apt_ref) ? 11'd1 : 11'd0);
                    end

                    // ---- Iterated GF(2) diff ----
                    // shift current level_sample[*] into level_prev[*]
                    for (k_i = 0; k_i <= K; k_i = k_i + 1)
                        level_prev[k_i] <= level_sample[k_i];

                    // accumulate popcounts only after warmup
                    if (warmup_done) begin
                        for (k_i = 0; k_i <= K; k_i = k_i + 1)
                            if (level_sample[k_i])
                                level_pop[k_i] <= level_pop[k_i] + 17'd1;
                    end else begin
                        warmup_cnt <= warmup_cnt + 4'd1;
                    end

                    // ---- end-of-gather ----
                    if (sample_cnt == W[16:0] - 17'd1) begin
                        // evaluate verdict
                        done    <= 1'b1;
                        healthy <= !rct_fail
                                && !apt_fail
                                && all_levels_pass;
                        rct_fail_out    <= rct_fail;
                        apt_fail_out    <= apt_fail;
                        level_fail_mask <= ~level_in_range;
                        state   <= ST_DONE;
                    end else begin
                        sample_cnt <= sample_cnt + 17'd1;
                    end
                end

                ST_DONE: begin
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
