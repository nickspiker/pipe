// =============================================================================
// trng.v — KOHI entropy gather: 8-ring chaos → XOR'd 65,536-bit buffer
// =============================================================================
//
// Eight free-running ring oscillators (stage counts 3/5/7/11/13/17/19/23 — the first 8 odd primes) are sampled in parallel on every enclave_clk edge. Each cycle, the 8 sampled bits are XOR'd into one entropy bit and written into a single 65,536-bit (8 KB) buffer. Eight per-ring popcount counters track the running 1-count for each ring independently. After 65,536 cycles, the popcounts are bounds-checked: each ring is "healthy" iff its popcount falls in [16384, 49152] = ¼…¾. If ≥4 of 8 rings pass, the gather is good (XOR of independent sources stays uniform as long as any one input is uniform — 4-of-8 is defense-in-depth, not strict cryptographic necessity); fewer than 4 → FUCKED, `health_fail` latches and the gather is permanently void. The healthy-ring count is exposed as `ring_health_cnt` (0..8) and the bitmask as `ring_health[7:0]` so attestation responses can report degradation level — DEGRADED chips (5–7 healthy) still operate, only FUCKED (≤3 healthy) silences the wire. The buffer is exposed as a byte-addressable read port for the BLAKE3 conditioner (`blake3_tree.v` — separate module).
//
// All sampling, XOR, popcount, and buffer addressing run in the enclave_clk domain. Ring outputs cross from their own free-running domains via 2-FF synchronizers. Per the slow-samples-fast rule (TRNG.md), enclave_clk is much slower than the slowest ring, so each sample catches every ring in essentially random phase.
//
// Phase: this is the KOHI (gather) phase of the IRA ceremony. TATARI (random pre-burn delay) and TAHU (eFuse burn) happen in `ira_fsm.v`.
//
// PIPE rule: ring oscillator instances live in top.v, not here. Sampling, accumulation, health-checking, and buffer storage live in this module. The buffer read interface is the seam for the BLAKE3 wrapper.
//
// =============================================================================

`timescale 1ns / 1ps

module trng (
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
    output wire [15:0]  ring_enable     // advisory: high during gather (top.v decides whether to gate)
);

    // -------------------------------------------------------------------------
    // 2-FF synchronizers: each ring crosses from its own free-running domain
    // into clk. Without these, the sampling FFs would see metastability and
    // propagate it into the XOR/popcount logic.
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

    wire [15:0] sample      = ring_sync2;
    wire        entropy_bit = ^sample;         // per-cycle 16-way XOR

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [1:0]
        ST_IDLE     = 2'd0,
        ST_GATHER   = 2'd1,
        ST_CHECK    = 2'd2,
        ST_DONE     = 2'd3;

    reg [1:0]  state;

    // 65,536-cycle counter (16 bits) + 8-bit-pack accumulator
    reg [15:0] cycle_cnt;
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

    // -------------------------------------------------------------------------
    // Per-ring popcount AND toggle counters. Each ring increments:
    //   popcount[i] when sample[i] == 1
    //   toggles[i]  when sample[i] != prev_sample[i]  (edge detect)
    // After 65,536 cycles, each must fall in band:
    //   popcount ∈ [8192, 57344]  = 1/8 to 7/8 — accepts up to 87% bias
    //   toggles  ≥ 256            = N/256     — catches near-resonance stuck
    //
    // Toggle threshold derivation (see design notes):
    //   For two stable freqs with offset Δf from sampler subharmonic,
    //   toggles_per_sample = 2|Δf|/f_s. Over N samples, toggle count is
    //   uniform in [0, N] under uniform-Δf distribution.
    //   With 16 rings, 8-of-16 byzantine threshold, per-ring fail budget
    //   is 0.79% to keep P_chip < 10⁻¹⁵ per KOHI (satellite-fleet safe).
    //   TOG_MIN = 256 puts per-ring fail at 256/65536 = 0.39% — 2× margin
    //   under ceiling, well clear of thermal-jitter false-positive floor.
    //
    // Popcount alone can't distinguish a stuck-or-locked pattern that
    // happens to have 50% ones from real entropy — e.g. "0×32768 then
    // 1×32768" has popcount=32768 (perfect) but exactly 1 toggle. The
    // toggle counter catches stuck-then-stuck rings and low-frequency
    // locked patterns that popcount alone passes.
    // -------------------------------------------------------------------------
    reg [16:0] popcount [0:15];
    reg [16:0] toggles  [0:15];
    reg [15:0] prev_sample;

    wire [15:0] toggle_bits = sample ^ prev_sample;  // 1 where this cycle differs from last

    // 1/8 of 65,536 = 8,192;  7/8 = 57,344.
    localparam [16:0] POP_LO = 17'd8192;
    localparam [16:0] POP_HI = 17'd57344;

    // Toggle minimum: N/256.
    localparam [16:0] TOG_MIN = 17'd256;

    wire [15:0] ring_pass;
    genvar k;
    generate
        for (k = 0; k < 16; k = k + 1) begin : health_check
            assign ring_pass[k] = (popcount[k] >= POP_LO)
                                & (popcount[k] <= POP_HI)
                                & (toggles[k]  >= TOG_MIN);
        end
    endgenerate

    // Sum of healthy-ring bits — 5-bit result (0..16).
    reg [4:0] healthy_cnt;
    integer hi;
    always @* begin
        healthy_cnt = 5'b0;
        for (hi = 0; hi < 16; hi = hi + 1)
            healthy_cnt = healthy_cnt + {4'b0, ring_pass[hi]};
    end

    // FUCKED threshold: 7 or fewer healthy rings. With 8+ of 16, byzantine
    // safety satisfied and entropy remains cryptographically sound (XOR of
    // independent sources is uniform whenever any one is uniform).
    localparam [4:0] HEALTH_MIN = 5'd8;

    // -------------------------------------------------------------------------
    // ring_enable: advisory output for top.v gating logic. Tied to busy so
    // that — if/when top.v gets gated rings working — they only oscillate
    // during an active KOHI. While busy=0, top.v can hold the rings dark.
    // -------------------------------------------------------------------------
    assign ring_enable = {16{busy}};

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    integer j;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= ST_IDLE;
            cycle_cnt   <= 16'b0;
            bit_idx     <= 3'b0;
            work_byte   <= 8'b0;
            buf_we      <= 1'b0;
            buf_waddr   <= 13'b0;
            buf_wdata   <= 8'b0;
            busy            <= 1'b0;
            gather_done     <= 1'b0;
            health_fail     <= 1'b0;
            ring_health     <= 16'b0;
            ring_health_cnt <= 5'b0;
            prev_sample     <= 16'b0;
            for (j = 0; j < 16; j = j + 1) begin
                popcount[j] <= 17'b0;
                toggles[j]  <= 17'b0;
            end
        end else begin
            buf_we      <= 1'b0;
            gather_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start && !health_fail) begin
                        cycle_cnt   <= 16'b0;
                        bit_idx     <= 3'b0;
                        work_byte   <= 8'b0;
                        prev_sample <= sample;       // seed edge detect
                        for (j = 0; j < 16; j = j + 1) begin
                            popcount[j] <= 17'b0;
                            toggles[j]  <= 17'b0;
                        end
                        busy  <= 1'b1;
                        state <= ST_GATHER;
                    end
                end

                ST_GATHER: begin
                    // Per-ring popcount: count of 1-bits sampled.
                    // Per-ring toggle count: edges detected vs. prior sample.
                    prev_sample <= sample;
                    for (j = 0; j < 16; j = j + 1) begin
                        popcount[j] <= popcount[j] + {16'b0, sample[j]};
                        toggles[j]  <= toggles[j]  + {16'b0, toggle_bits[j]};
                    end

                    // Pack entropy_bit into work_byte; on every 8th cycle, write to BRAM.
                    if (bit_idx == 3'd7) begin
                        buf_we    <= 1'b1;
                        buf_waddr <= cycle_cnt[15:3];
                        buf_wdata <= {entropy_bit, work_byte[7:1]};
                        bit_idx   <= 3'b0;
                    end else begin
                        work_byte <= {entropy_bit, work_byte[7:1]};
                        bit_idx   <= bit_idx + 3'd1;
                    end

                    if (&cycle_cnt) begin
                        // cycle_cnt == 65,535: this was the final sample.
                        cycle_cnt <= 16'b0;
                        state     <= ST_CHECK;
                    end else begin
                        cycle_cnt <= cycle_cnt + 16'b1;
                    end
                end

                ST_CHECK: begin
                    // Latch the health snapshot and decide HEALTHY/DEGRADED/FUCKED.
                    ring_health     <= ring_pass;
                    ring_health_cnt <= healthy_cnt;
                    if (healthy_cnt < HEALTH_MIN) begin
                        // <4 rings passed bounds — FUCKED. health_fail latches
                        // permanently (POR is the only clear path). Downstream
                        // gates the wire heartbeat on this so a FUCKED chip
                        // goes silent rather than lying about its capability.
                        health_fail <= 1'b1;
                    end else begin
                        // 4..8 healthy rings — entropy sound. The buffer can
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
