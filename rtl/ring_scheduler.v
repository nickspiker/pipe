// =============================================================================
// ring_scheduler.v — round-robin per-ring health gather (Claim 3c, Variant A)
// =============================================================================
//
// Wraps a single instance of ring_health.v and schedules it across all 16 rings sequentially. For each ring i in 0..15:
//
//   1. ring_enable = one-hot(i)            — enable only ring i
//   2. wait ENABLE_DELAY cycles            — let oscillator settle
//   3. pulse start, wait for done          — full W=65536 sample gather
//   4. latch ring_health_mask[i] = healthy
//   5. advance to ring (i+1) mod 16
//
// After ring 15 completes, ring_health_cnt is the sum of the 16 verdicts. all_done pulses one cycle when the full 16-ring schedule completes.
//
// Total time per gather: 16 * (W + ENABLE_DELAY + ~3 FSM cycles) ~= 16*W. At enclave_clk = 600 kHz that is ~1.75 s per full KOHI ceremony.
//
// Silicon cost is one ring_health.v instance + a small FSM + a 16-bit mask register: roughly an order of magnitude smaller than 16 parallel instances.
//
// Sample-stream output: sample_bit / sample_valid feed downstream (BLAKE3 conditioner) one bit per cycle whenever a per-ring gather is in progress. The downstream consumer sees 16*W bits total per KOHI, streamed sequentially per ring.
//
// =============================================================================

`timescale 1ns / 1ps

module ring_scheduler #(
    parameter integer N_RINGS      = 16,
    parameter integer W            = 65536,   // samples per ring
    parameter integer ENABLE_DELAY = 8,       // cycles between ring_enable and start
    parameter integer RCT_C        = 32,
    parameter integer APT_W        = 1024,
    parameter integer APT_T        = 614,
    parameter integer LVL_LO       = 32000,
    parameter integer LVL_HI       = 33536
) (
    input  wire                clk,
    input  wire                reset_n,
    input  wire                start,         // 1-cycle pulse to begin a full KOHI

    input  wire [N_RINGS-1:0]  ring_in,       // 16 ring oscillator outputs
    output reg  [N_RINGS-1:0]  ring_enable,   // one-hot mask of currently-active ring

    output wire                sample_bit,    // currently-active ring's sample
    output wire                sample_valid,  // high while gathering

    output reg                 busy,
    output reg                 all_done,      // 1-cycle pulse: full schedule done
    output reg  [N_RINGS-1:0]  ring_health_mask, // bit i = ring i healthy
    output reg  [4:0]          ring_health_cnt,  // popcount of mask (0..16)
    // Diagnostic surface — per-ring failure reasons, valid after all_done
    output reg  [N_RINGS-1:0]  ring_rct_fail,    // bit i = ring i tripped RCT
    output reg  [N_RINGS-1:0]  ring_apt_fail,    // bit i = ring i tripped APT
    output reg  [N_RINGS*7-1:0] ring_level_fail  // 7 bits per ring, K+1=7 levels
);

    localparam integer IDX_W = (N_RINGS <= 1) ? 1 : $clog2(N_RINGS);

    // -------------------------------------------------------------------------
    // Shared ring_health instance. Caller (e.g., trng.v) is responsible for
    // 2-FF synchronizing each ring input upstream of `ring_in`.
    // -------------------------------------------------------------------------
    reg  [IDX_W-1:0] ring_idx;
    wire             current_sample = ring_in[ring_idx];
    reg              rh_start;
    wire             rh_done;
    wire             rh_healthy;
    wire             rh_rct_fail;
    wire             rh_apt_fail;
    wire [6:0]       rh_level_fail_mask;

    ring_health #(
        .W      (W),
        .RCT_C  (RCT_C),
        .APT_W  (APT_W),
        .APT_T  (APT_T),
        .LVL_LO (LVL_LO),
        .LVL_HI (LVL_HI)
    ) rh (
        .clk             (clk),
        .reset_n         (reset_n),
        .start           (rh_start),
        .sample          (current_sample),
        .done            (rh_done),
        .healthy         (rh_healthy),
        .rct_fail_out    (rh_rct_fail),
        .apt_fail_out    (rh_apt_fail),
        .level_fail_mask (rh_level_fail_mask)
    );

    // -------------------------------------------------------------------------
    // Scheduler FSM
    // -------------------------------------------------------------------------
    localparam [2:0] ST_IDLE   = 3'd0,
                     ST_SETTLE = 3'd1,
                     ST_LAUNCH = 3'd2,
                     ST_GATHER = 3'd3,
                     ST_LATCH  = 3'd4,
                     ST_FINISH = 3'd5;
    reg [2:0]  state;
    reg [3:0]  settle_cnt;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state            <= ST_IDLE;
            ring_idx         <= {IDX_W{1'b0}};
            settle_cnt       <= 4'd0;
            rh_start         <= 1'b0;
            ring_enable      <= {N_RINGS{1'b0}};
            ring_health_mask <= {N_RINGS{1'b0}};
            ring_health_cnt  <= 5'd0;
            busy             <= 1'b0;
            all_done         <= 1'b0;
            ring_rct_fail    <= {N_RINGS{1'b0}};
            ring_apt_fail    <= {N_RINGS{1'b0}};
            ring_level_fail  <= {(N_RINGS*7){1'b0}};
        end else begin
            rh_start <= 1'b0;
            all_done <= 1'b0;
            case (state)

                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy             <= 1'b1;
                        ring_idx         <= {IDX_W{1'b0}};
                        ring_enable      <= {{(N_RINGS-1){1'b0}}, 1'b1};  // one-hot ring 0
                        ring_health_mask <= {N_RINGS{1'b0}};
                        ring_health_cnt  <= 5'd0;
                        ring_rct_fail    <= {N_RINGS{1'b0}};
                        ring_apt_fail    <= {N_RINGS{1'b0}};
                        ring_level_fail  <= {(N_RINGS*7){1'b0}};
                        settle_cnt       <= ENABLE_DELAY[3:0];
                        state            <= ST_SETTLE;
                    end
                end

                ST_SETTLE: begin
                    if (settle_cnt == 4'd0) begin
                        state <= ST_LAUNCH;
                    end else begin
                        settle_cnt <= settle_cnt - 4'd1;
                    end
                end

                ST_LAUNCH: begin
                    rh_start <= 1'b1;       // pulse start to ring_health
                    state    <= ST_GATHER;
                end

                ST_GATHER: begin
                    if (rh_done) begin
                        ring_health_mask[ring_idx] <= rh_healthy;
                        ring_rct_fail[ring_idx]    <= rh_rct_fail;
                        ring_apt_fail[ring_idx]    <= rh_apt_fail;
                        ring_level_fail[ring_idx*7 +: 7] <= rh_level_fail_mask;
                        state <= ST_LATCH;
                    end
                end

                ST_LATCH: begin
                    if (ring_idx == N_RINGS[IDX_W-1:0] - {{(IDX_W-1){1'b0}}, 1'b1}) begin
                        // we just finished ring (N_RINGS-1) — move to FINISH
                        ring_enable <= {N_RINGS{1'b0}};
                        state       <= ST_FINISH;
                    end else begin
                        ring_idx    <= ring_idx + {{(IDX_W-1){1'b0}}, 1'b1};
                        ring_enable <= {{(N_RINGS-1){1'b0}}, 1'b1} << (ring_idx + {{(IDX_W-1){1'b0}}, 1'b1});
                        settle_cnt  <= ENABLE_DELAY[3:0];
                        state       <= ST_SETTLE;
                    end
                end

                ST_FINISH: begin
                    ring_health_cnt <= popcount_n(ring_health_mask);
                    all_done        <= 1'b1;
                    state           <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // popcount of an N_RINGS-bit vector, returns 5 bits (sufficient for N<=31)
    function [4:0] popcount_n;
        input [N_RINGS-1:0] v;
        integer pi;
        begin
            popcount_n = 5'd0;
            for (pi = 0; pi < N_RINGS; pi = pi + 1)
                popcount_n = popcount_n + {4'd0, v[pi]};
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sample-stream output
    // -------------------------------------------------------------------------
    assign sample_bit   = current_sample;
    assign sample_valid = (state == ST_GATHER);

endmodule
