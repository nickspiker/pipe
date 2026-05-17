// =============================================================================
// trng.v — KOHI entropy gather: round-robin per-ring sampling + layered health
// =============================================================================
//
// Drives a `ring_scheduler` instance that walks the 16 rings sequentially, gathering W=4096 samples per ring (16 × 4096 = 65,536 bits = 8 KB buffer fill). The scheduler runs the layered RCT + APT + iterated GF(2) differencing health check (Claim 3c) on each ring's stream as it goes. After all 16 rings complete, the per-ring verdicts are latched as `ring_health[15:0]` and the Byzantine threshold check decides HEALTHY/FUCKED.
//
// The 16 ring oscillators free-run continuously; `ring_enable` is advisory (top.v decides whether to gate). Each ring's bit-stream feeds the entropy buffer one bit per cycle when `sample_valid` is high.
//
// Architecture trade vs original parallel-XOR design:
//   - 13x fewer LUTs (one shared ring_health instance instead of 16 parallel)
//   - Same KOHI wall-clock (~110 ms at 600 kHz enclave_clk)
//   - Per-ring health checked over W=4096 samples instead of 65,536 — looser tolerance but still catches stuck, biased, near-resonance, and periodic-pattern failure modes
//   - Entropy per cycle is one ring's bit, not the XOR of all 16; BLAKE3 conditioning over the full 8 KB buffer recovers cryptographic uniformity
//
// Phase: this is the KOHI (gather) phase of the IRA ceremony. TATARI (random pre-burn delay) and TAHU (eFuse burn) happen in `ira_fsm.v`.
//
// PIPE rule: ring oscillator instances live in top.v, not here. Sampling, accumulation, health-checking, and buffer storage live in this module. The buffer read interface is the seam for the BLAKE3 wrapper.
//
// =============================================================================

`timescale 1ns / 1ps

module trng #(
    // SCHED_W is the per-ring gather window. Total bits gathered = 16 * SCHED_W
    // which should equal 65,536 (= 8 KB buffer). For sim, override to a small
    // power-of-two so tests finish fast.
    parameter integer SCHED_W      = 4096,
    parameter integer SCHED_RCT_C  = 32,
    parameter integer SCHED_APT_W  = 256,
    parameter integer SCHED_APT_T  = 156,
    parameter integer SCHED_LVL_LO = 1856,
    parameter integer SCHED_LVL_HI = 2240
) (
    input  wire         clk,            // enclave_clk (slow sampler, ~600 kHz)
    input  wire         reset_n,        // active-low POR
    input  wire         start,          // 1-cycle pulse to begin a fresh KOHI

    input  wire [15:0]  ring_in,        // 16 free-running ring oscillator outputs

    // Buffer read port for downstream BLAKE3 conditioner.
    // Address [12:0] selects one of 8192 bytes; data appears next cycle.
    input  wire [12:0]  buf_raddr,
    output reg   [7:0]  buf_rdata,

    output reg          busy,           // high during gather + health check
    output reg          gather_done,    // 1-cycle strobe when buffer ready (>= 8 rings healthy)
    output reg          health_fail,    // latched when <8 of 16 rings pass — FUCKED state
    output reg  [15:0]  ring_health,    // bitmask of last-gather healthy rings (1=pass)
    output reg   [4:0]  ring_health_cnt,// count of healthy rings 0..16 (for attestation responses)
    output wire [15:0]  ring_enable     // advisory: one-hot mask of currently-active ring
);

    // -------------------------------------------------------------------------
    // 2-FF synchronizers: each ring crosses from its own free-running domain
    // into clk. Without these, the sampling FFs would see metastability and
    // propagate it into the ring_scheduler's health logic.
    // -------------------------------------------------------------------------
    reg [15:0] ring_sync1;
    reg [15:0] ring_sync2;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ring_sync1 <= 16'b0;
            ring_sync2 <= 16'b0;
        end else begin
            ring_sync1 <= ring_in;
            ring_sync2 <= ring_sync1;
        end
    end

    // -------------------------------------------------------------------------
    // ring_scheduler: round-robin per-ring health gather (Claim 3c Variant A)
    // -------------------------------------------------------------------------
    reg          sched_start;
    wire         sched_busy;
    wire         sched_all_done;
    wire [15:0]  sched_ring_health_mask;
    wire [4:0]   sched_ring_health_cnt;
    wire         sched_sample_bit;
    wire         sched_sample_valid;

    ring_scheduler #(
        .N_RINGS      (16),
        .W            (SCHED_W),
        .ENABLE_DELAY (8),
        .RCT_C        (SCHED_RCT_C),
        .APT_W        (SCHED_APT_W),
        .APT_T        (SCHED_APT_T),
        .LVL_LO       (SCHED_LVL_LO),
        .LVL_HI       (SCHED_LVL_HI)
    ) sched (
        .clk              (clk),
        .reset_n          (reset_n),
        .start            (sched_start),
        .ring_in          (ring_sync2),
        .ring_enable      (ring_enable),
        .sample_bit       (sched_sample_bit),
        .sample_valid     (sched_sample_valid),
        .busy             (sched_busy),
        .all_done         (sched_all_done),
        .ring_health_mask (sched_ring_health_mask),
        .ring_health_cnt  (sched_ring_health_cnt)
    );

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [1:0]
        ST_IDLE   = 2'd0,
        ST_GATHER = 2'd1,
        ST_CHECK  = 2'd2,
        ST_DONE   = 2'd3;

    reg [1:0] state;

    // 65,536-bit (= 8 KB) buffer fills bit-by-bit when sample_valid is high.
    // 16 rings × W=4096 bits each = exactly 65,536 bits when scheduler completes.
    reg [15:0] bit_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  work_byte;

    // -------------------------------------------------------------------------
    // BRAM buffer: 8192 × 8 bits = 65,536 bits. Inferred to 4 × DP16KD on ECP5.
    // Read-after-write semantics: the read port lags by one cycle.
    // -------------------------------------------------------------------------
    reg  [7:0]  buffer [0:8191];
    reg         buf_we;
    reg  [12:0] buf_waddr;
    reg  [7:0]  buf_wdata;

    always @(posedge clk) begin
        if (buf_we) buffer[buf_waddr] <= buf_wdata;
        buf_rdata <= buffer[buf_raddr];
    end

    // FUCKED threshold: 7 or fewer healthy rings. With 8+ of 16, byzantine
    // safety satisfied and entropy remains cryptographically sound (XOR of
    // independent sources via BLAKE3 is uniform whenever any one is uniform).
    localparam [4:0] HEALTH_MIN = 5'd8;

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state           <= ST_IDLE;
            bit_cnt         <= 16'b0;
            bit_idx         <= 3'b0;
            work_byte       <= 8'b0;
            buf_we          <= 1'b0;
            buf_waddr       <= 13'b0;
            buf_wdata       <= 8'b0;
            sched_start     <= 1'b0;
            busy            <= 1'b0;
            gather_done     <= 1'b0;
            health_fail     <= 1'b0;
            ring_health     <= 16'b0;
            ring_health_cnt <= 5'b0;
        end else begin
            buf_we      <= 1'b0;
            gather_done <= 1'b0;
            sched_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start && !health_fail) begin
                        bit_cnt   <= 16'b0;
                        bit_idx   <= 3'b0;
                        work_byte <= 8'b0;
                        sched_start <= 1'b1;
                        busy  <= 1'b1;
                        state <= ST_GATHER;
                    end
                end

                ST_GATHER: begin
                    // Pack sched_sample_bit into work_byte; on every 8th bit,
                    // write to BRAM. Advance only when sample_valid.
                    if (sched_sample_valid) begin
                        if (bit_idx == 3'd7) begin
                            buf_we    <= 1'b1;
                            buf_waddr <= bit_cnt[15:3];
                            buf_wdata <= {sched_sample_bit, work_byte[7:1]};
                            bit_idx   <= 3'b0;
                        end else begin
                            work_byte <= {sched_sample_bit, work_byte[7:1]};
                            bit_idx   <= bit_idx + 3'd1;
                        end
                        bit_cnt <= bit_cnt + 16'b1;
                    end

                    if (sched_all_done) begin
                        state <= ST_CHECK;
                    end
                end

                ST_CHECK: begin
                    // Latch the health snapshot and decide HEALTHY/DEGRADED/FUCKED.
                    ring_health     <= sched_ring_health_mask;
                    ring_health_cnt <= sched_ring_health_cnt;
                    if (sched_ring_health_cnt < HEALTH_MIN) begin
                        // <8 rings passed — FUCKED. health_fail latches
                        // permanently (POR is the only clear path). Downstream
                        // gates the wire heartbeat on this so a FUCKED chip
                        // goes silent rather than lying about its capability.
                        health_fail <= 1'b1;
                    end else begin
                        // 8..16 healthy rings — entropy sound. The buffer can
                        // be conditioned; ring_health_cnt feeds attestation so
                        // the host learns the degradation level.
                        gather_done <= 1'b1;
                    end
                    state <= ST_DONE;
                end

                ST_DONE: begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
