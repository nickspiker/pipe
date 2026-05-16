// deps: (none — self-contained)
// =============================================================================
// ring_health_mux.v — time-multiplexed per-ring health check (Variant E)
// =============================================================================
//
// Implements Claim 3c (layered RCT + APT + iterated GF(2) diff) with a single shared arithmetic + comparator block time-multiplexed across N_RINGS=16 rings. All 16 rings are sampled in parallel by the caller; this module visits each ring's state on successive fast-clock cycles inside one slow-clock sample period.
//
// Clock contract:
//   - `clk` is the FAST clock, running at exactly N_RINGS× the slow sample rate. Typically: clk = ring_osc directly, and the slow clock = ring_osc / N_RINGS feeds the rest of the chip.
//   - `ring_sample[15:0]` holds the 16 latched ring samples for the current slow tick. It must be STABLE for the entire N_RINGS=16 fast cycles of one slow period.
//   - assert `start` for one fast cycle to begin a gather; this fast edge must align with the slow rising edge (phase 0).
//   - after W slow samples have been processed and verdicts computed, `done` pulses one fast cycle and `healthy_mask[15:0]` is valid in that cycle.
//
// Time-multiplexing rule:
//   On fast cycle whose phase = p (p in 0..N_RINGS-1):
//     1. read ring_state[p] (per-ring counters)
//     2. update state using ring_sample[p]
//     3. write state back to ring_state[p]
//   When phase wraps 15→0, slow_cnt increments. Gather completes after W slow ticks. ST_VERDICT then walks rings 0..15 (one fast cycle each) computing the verdict bit.
//
// Total wall-clock time = W slow periods = W / enclave_clk. Same as 16-instance parallel — time-multiplexing recovers all parallelism by clocking 16× faster.
//
// =============================================================================

`timescale 1ns / 1ps

module ring_health_mux #(
    parameter integer N_RINGS = 16,
    parameter integer W       = 65536,
    parameter integer K       = 6,
    parameter integer RCT_C   = 32,
    parameter integer APT_W   = 1024,
    parameter integer APT_T   = 614,
    parameter integer LVL_LO  = 32000,
    parameter integer LVL_HI  = 33536
) (
    input  wire                clk,
    input  wire                reset_n,
    input  wire                start,
    input  wire [N_RINGS-1:0]  ring_sample,
    output reg                 done,
    output reg  [N_RINGS-1:0]  healthy_mask
);

    localparam integer PHASE_W = (N_RINGS <= 1) ? 1 : $clog2(N_RINGS);

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [1:0] ST_IDLE    = 2'd0,
                     ST_GATHER  = 2'd1,
                     ST_VERDICT = 2'd2,
                     ST_DONE    = 2'd3;
    reg [1:0]          state;
    reg [PHASE_W-1:0]  phase;
    reg [16:0]         slow_cnt;
    reg [3:0]          warmup_cnt;
    wire               warmup_done   = (warmup_cnt >= K[3:0]);
    wire               phase_last    = (phase == N_RINGS[PHASE_W-1:0] - {{(PHASE_W-1){1'b0}}, 1'b1});

    // =========================================================================
    // Per-ring state register files
    // =========================================================================
    // RCT
    reg [6:0]  rct_run_mem    [0:N_RINGS-1];
    reg        rct_prev_mem   [0:N_RINGS-1];
    reg        rct_fail_mem   [0:N_RINGS-1];

    // APT
    reg [9:0]  apt_pos_mem    [0:N_RINGS-1];
    reg [10:0] apt_count_mem  [0:N_RINGS-1];
    reg        apt_ref_mem    [0:N_RINGS-1];
    reg        apt_fail_mem   [0:N_RINGS-1];

    // Iterated diff: K+1 prev bits (packed) and K+1 popcount counters per ring
    reg [K:0]  level_prev_mem [0:N_RINGS-1];
    reg [16:0] level_pop_mem_0 [0:N_RINGS-1];
    reg [16:0] level_pop_mem_1 [0:N_RINGS-1];
    reg [16:0] level_pop_mem_2 [0:N_RINGS-1];
    reg [16:0] level_pop_mem_3 [0:N_RINGS-1];
    reg [16:0] level_pop_mem_4 [0:N_RINGS-1];
    reg [16:0] level_pop_mem_5 [0:N_RINGS-1];
    reg [16:0] level_pop_mem_6 [0:N_RINGS-1];

    // =========================================================================
    // Current ring read
    // =========================================================================
    wire               sample = ring_sample[phase];
    wire [6:0]  cur_rct_run   = rct_run_mem[phase];
    wire        cur_rct_prev  = rct_prev_mem[phase];
    wire        cur_rct_fail  = rct_fail_mem[phase];
    wire [9:0]  cur_apt_pos   = apt_pos_mem[phase];
    wire [10:0] cur_apt_count = apt_count_mem[phase];
    wire        cur_apt_ref   = apt_ref_mem[phase];
    wire        cur_apt_fail  = apt_fail_mem[phase];
    wire [K:0]  cur_level_prev = level_prev_mem[phase];
    wire [16:0] cur_pop [0:K];
    assign cur_pop[0] = level_pop_mem_0[phase];
    assign cur_pop[1] = level_pop_mem_1[phase];
    assign cur_pop[2] = level_pop_mem_2[phase];
    assign cur_pop[3] = level_pop_mem_3[phase];
    assign cur_pop[4] = level_pop_mem_4[phase];
    assign cur_pop[5] = level_pop_mem_5[phase];
    assign cur_pop[6] = level_pop_mem_6[phase];

    // =========================================================================
    // Iterated diff cascade
    // =========================================================================
    wire [K:0] level_sample;
    assign level_sample[0] = sample;
    genvar gk;
    generate
        for (gk = 1; gk <= K; gk = gk + 1) begin : g_cascade
            assign level_sample[gk] = level_sample[gk-1] ^ cur_level_prev[gk-1];
        end
    endgenerate

    // =========================================================================
    // Combinational update logic
    // =========================================================================

    // RCT: same as prev (and not the first sample for this ring)
    wire        is_first       = (slow_cnt == 17'd0);
    wire        same_as_prev   = (sample == cur_rct_prev) && !is_first;
    wire [6:0]  new_rct_run    = is_first ? 7'd1
                               : (same_as_prev ? cur_rct_run + 7'd1 : 7'd1);
    wire        rct_too_long   = (new_rct_run > RCT_C[6:0]);
    wire        new_rct_fail   = cur_rct_fail | rct_too_long;

    // APT
    wire apt_match    = (sample == cur_apt_ref);
    wire apt_window_end = (cur_apt_pos == APT_W[9:0] - 10'd1);
    wire apt_new_win    = (cur_apt_pos == 10'd0);
    reg  [9:0]  new_apt_pos;
    reg  [10:0] new_apt_count;
    reg         new_apt_ref;
    reg         new_apt_fail;
    always @* begin
        new_apt_pos   = cur_apt_pos;
        new_apt_count = cur_apt_count;
        new_apt_ref   = cur_apt_ref;
        new_apt_fail  = cur_apt_fail;
        if (apt_new_win) begin
            new_apt_ref   = sample;
            new_apt_count = 11'd1;
            new_apt_pos   = 10'd1;
        end else if (apt_window_end) begin
            if (cur_apt_count + (apt_match ? 11'd1 : 11'd0) > APT_T[10:0])
                new_apt_fail = 1'b1;
            new_apt_pos = 10'd0;
        end else begin
            new_apt_pos   = cur_apt_pos + 10'd1;
            new_apt_count = cur_apt_count + (apt_match ? 11'd1 : 11'd0);
        end
    end

    // Iterated diff popcount accumulate (only after warmup)
    wire [16:0] new_pop_0 = cur_pop[0] + (warmup_done && level_sample[0] ? 17'd1 : 17'd0);
    wire [16:0] new_pop_1 = cur_pop[1] + (warmup_done && level_sample[1] ? 17'd1 : 17'd0);
    wire [16:0] new_pop_2 = cur_pop[2] + (warmup_done && level_sample[2] ? 17'd1 : 17'd0);
    wire [16:0] new_pop_3 = cur_pop[3] + (warmup_done && level_sample[3] ? 17'd1 : 17'd0);
    wire [16:0] new_pop_4 = cur_pop[4] + (warmup_done && level_sample[4] ? 17'd1 : 17'd0);
    wire [16:0] new_pop_5 = cur_pop[5] + (warmup_done && level_sample[5] ? 17'd1 : 17'd0);
    wire [16:0] new_pop_6 = cur_pop[6] + (warmup_done && level_sample[6] ? 17'd1 : 17'd0);

    // Verdict computation (combinational, used in ST_VERDICT)
    wire pop_in_range_0 = (cur_pop[0] >= LVL_LO[16:0]) && (cur_pop[0] <= LVL_HI[16:0]);
    wire pop_in_range_1 = (cur_pop[1] >= LVL_LO[16:0]) && (cur_pop[1] <= LVL_HI[16:0]);
    wire pop_in_range_2 = (cur_pop[2] >= LVL_LO[16:0]) && (cur_pop[2] <= LVL_HI[16:0]);
    wire pop_in_range_3 = (cur_pop[3] >= LVL_LO[16:0]) && (cur_pop[3] <= LVL_HI[16:0]);
    wire pop_in_range_4 = (cur_pop[4] >= LVL_LO[16:0]) && (cur_pop[4] <= LVL_HI[16:0]);
    wire pop_in_range_5 = (cur_pop[5] >= LVL_LO[16:0]) && (cur_pop[5] <= LVL_HI[16:0]);
    wire pop_in_range_6 = (cur_pop[6] >= LVL_LO[16:0]) && (cur_pop[6] <= LVL_HI[16:0]);
    wire all_levels_pass = pop_in_range_0 & pop_in_range_1 & pop_in_range_2
                         & pop_in_range_3 & pop_in_range_4 & pop_in_range_5
                         & pop_in_range_6;
    wire ring_healthy = !cur_rct_fail && !cur_apt_fail && all_levels_pass;

    // =========================================================================
    // Main always
    // =========================================================================
    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= ST_IDLE;
            phase         <= {PHASE_W{1'b0}};
            slow_cnt      <= 17'd0;
            warmup_cnt    <= 4'd0;
            done          <= 1'b0;
            healthy_mask  <= {N_RINGS{1'b0}};
            for (i = 0; i < N_RINGS; i = i + 1) begin
                rct_run_mem[i]    <= 7'd0;
                rct_prev_mem[i]   <= 1'b0;
                rct_fail_mem[i]   <= 1'b0;
                apt_pos_mem[i]    <= 10'd0;
                apt_count_mem[i]  <= 11'd0;
                apt_ref_mem[i]    <= 1'b0;
                apt_fail_mem[i]   <= 1'b0;
                level_prev_mem[i] <= {(K+1){1'b0}};
                level_pop_mem_0[i] <= 17'd0;
                level_pop_mem_1[i] <= 17'd0;
                level_pop_mem_2[i] <= 17'd0;
                level_pop_mem_3[i] <= 17'd0;
                level_pop_mem_4[i] <= 17'd0;
                level_pop_mem_5[i] <= 17'd0;
                level_pop_mem_6[i] <= 17'd0;
            end
        end else begin
            done <= 1'b0;
            case (state)

                ST_IDLE: begin
                    if (start) begin
                        state         <= ST_GATHER;
                        phase         <= {PHASE_W{1'b0}};
                        slow_cnt      <= 17'd0;
                        warmup_cnt    <= 4'd0;
                        healthy_mask  <= {N_RINGS{1'b0}};
                        for (i = 0; i < N_RINGS; i = i + 1) begin
                            rct_run_mem[i]    <= 7'd0;
                            rct_prev_mem[i]   <= 1'b0;
                            rct_fail_mem[i]   <= 1'b0;
                            apt_pos_mem[i]    <= 10'd0;
                            apt_count_mem[i]  <= 11'd0;
                            apt_ref_mem[i]    <= 1'b0;
                            apt_fail_mem[i]   <= 1'b0;
                            level_prev_mem[i] <= {(K+1){1'b0}};
                            level_pop_mem_0[i] <= 17'd0;
                            level_pop_mem_1[i] <= 17'd0;
                            level_pop_mem_2[i] <= 17'd0;
                            level_pop_mem_3[i] <= 17'd0;
                            level_pop_mem_4[i] <= 17'd0;
                            level_pop_mem_5[i] <= 17'd0;
                            level_pop_mem_6[i] <= 17'd0;
                        end
                    end
                end

                ST_GATHER: begin
                    // Update state for ring[phase]
                    rct_run_mem[phase]   <= new_rct_run;
                    rct_prev_mem[phase]  <= sample;
                    rct_fail_mem[phase]  <= new_rct_fail;
                    apt_pos_mem[phase]   <= new_apt_pos;
                    apt_count_mem[phase] <= new_apt_count;
                    apt_ref_mem[phase]   <= new_apt_ref;
                    apt_fail_mem[phase]  <= new_apt_fail;
                    level_prev_mem[phase] <= level_sample;
                    level_pop_mem_0[phase] <= new_pop_0;
                    level_pop_mem_1[phase] <= new_pop_1;
                    level_pop_mem_2[phase] <= new_pop_2;
                    level_pop_mem_3[phase] <= new_pop_3;
                    level_pop_mem_4[phase] <= new_pop_4;
                    level_pop_mem_5[phase] <= new_pop_5;
                    level_pop_mem_6[phase] <= new_pop_6;

                    // Advance phase
                    if (phase_last) begin
                        phase <= {PHASE_W{1'b0}};
                        // one slow tick complete
                        if (!warmup_done) warmup_cnt <= warmup_cnt + 4'd1;
                        if (slow_cnt == W[16:0] - 17'd1) begin
                            // Gather complete — walk verdicts
                            state    <= ST_VERDICT;
                            slow_cnt <= 17'd0;
                        end else begin
                            slow_cnt <= slow_cnt + 17'd1;
                        end
                    end else begin
                        phase <= phase + {{(PHASE_W-1){1'b0}}, 1'b1};
                    end
                end

                ST_VERDICT: begin
                    // For each ring, compute and latch verdict bit
                    healthy_mask[phase] <= ring_healthy;
                    if (phase_last) begin
                        phase <= {PHASE_W{1'b0}};
                        state <= ST_DONE;
                    end else begin
                        phase <= phase + {{(PHASE_W-1){1'b0}}, 1'b1};
                    end
                end

                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
