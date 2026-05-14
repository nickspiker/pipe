// =============================================================================
// inverted_pair_verify.v — 4-pair XOR-to-all-ones classifier (sequential popcount)
// =============================================================================
//
// Combinational classifier for the inverted-pair storage geometry described
// in IRA.md §"OTP geometry" / §"The five lifelong states". Takes 8 slot
// values (4 pairs × {A, B}) and produces:
//
//   - per-pair classification (virgin / valid / corrupt)
//   - aggregate 5-state machine code (VIRGIN / FUCKED / DEGRADED-{2,1} / HEALTHY)
//   - recovered ira value (lowest-indexed valid pair's A slot, or zero)
//   - byzantine_ok strobe (≥2 valid pairs AND all valid pairs agree on ira)
//   - state_valid strobe (high after first complete popcount sweep)
//
// This module is shared between two consumers per Claim 4a:
//   - persistent: 8 OTP slots holding ira / ~ira → boot-time identity classifier
//   - ephemeral:  8 RAM slots holding wairua / ~wairua → session-time classifier
//
// Slot layout (caller's responsibility — this module sees raw 256-bit values):
//   slot[0..3] = pair 0..3 A (holds ira or wairua)
//   slot[4..7] = pair 0..3 B (holds ~ira or ~wairua)
//
// Per-pair classification:
//   virgin  → both slots are all-zero (the genuine unburned state)
//   valid   → A XOR B == all-ones  AND  each slot's popcount ∈ [32, 224]
//   corrupt → anything else
//
// The popcount sanity check (each slot must have popcount in [32, 224])
// defends against degenerate cases — most notably A=0/B=all-ones which
// would XOR to all-ones but encode a meaningless ira. Realistic BLAKE3
// output has popcount tightly bunched at ~128 (mean 128, σ≈8), so the
// [32, 224] band sits 12σ from the mean — for a fleet of 10^11 devices
// issuing 10 keys/day, the expected once-by-chance firing rate is once
// per ~10^18 years. Any firing of this check is a deterministic fault
// signal, not statistical variance.
//
// Popcount implementation: a single per-slot rotate-and-tally counter
// running free over 257-cycle sweeps. 8 shift registers (one per slot,
// loaded from slot_flat) + 8 nine-bit counters; each cycle the slot
// register rotates right by one bit and the popcount counter adds the
// new LSB. After 256 cycles the counter holds the full popcount; one
// more cycle latches it, resets, reloads from slot_flat (re-picking up
// any changes), and the sweep continues. The classifier outputs are
// combinational on slot_flat + the latched popcounts; they are not
// stable until state_valid asserts (i.e., after the first complete
// sweep ~257 cycles after reset).
//
// =============================================================================

`timescale 1ns / 1ps

module inverted_pair_verify #(
    parameter integer SLOT_BITS = 256
) (
    input  wire                   clk,
    input  wire                   reset_n,

    // 8 slot values packed: slot 0 at bits [SLOT_BITS-1:0], slot 7 at top.
    input  wire [8*SLOT_BITS-1:0] slot_flat,

    // High after the first complete popcount sweep; from there it stays high
    // and outputs are continuously refreshed every 257 cycles. Consumer waits
    // for this before trusting the classification.
    output reg                    state_valid,

    // Per-pair classification (one bit per pair, 4 pairs).
    output wire [3:0]             pair_virgin,
    output wire [3:0]             pair_valid,
    output wire [3:0]             pair_corrupt,

    // Aggregate
    output wire [2:0]             valid_count,
    output wire                   all_virgin,
    output wire                   agreement_ok,
    output wire                   byzantine_ok,
    output wire [2:0]             state,

    output wire [SLOT_BITS-1:0]   ira
);

    // -------------------------------------------------------------------------
    // slot_latched: the slot data whose popcount sits in popcount[]. Updated
    // in lockstep with popcount at each sweep boundary so the classifier
    // never sees a fresh-slot/stale-popcount mismatch (which would cause a
    // transient FUCKED reading immediately after the OTP changes).
    // -------------------------------------------------------------------------
    reg [SLOT_BITS-1:0] slot_latched [0:7];

    wire [SLOT_BITS-1:0] slot [0:7];
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : unpack
            assign slot[k] = slot_latched[k];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Sequential popcount.
    //
    // 8 shift registers (one per slot), each 256 bits. Each cycle:
    //   tally  += shift[i][0]                  (sample current LSB)
    //   shift  <= {shift[i][0], shift[i][N-1:1]}   (rotate right by 1)
    //
    // After SLOT_BITS=256 cycles each shift register has cycled fully and
    // the tally equals the slot's popcount. On cycle SLOT_BITS we latch
    // tally → popcount_latched, reset tally to 0, and reload shift from
    // slot_flat to pick up any changes. The sweep restarts immediately.
    // -------------------------------------------------------------------------
    reg [SLOT_BITS-1:0] shift_reg [0:7];
    reg [8:0]           tally     [0:7];
    reg [8:0]           popcount  [0:7];
    reg [8:0]           cycle_cnt;
    integer             i;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cycle_cnt   <= 9'b0;
            state_valid <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                shift_reg[i]    <= {SLOT_BITS{1'b0}};
                slot_latched[i] <= {SLOT_BITS{1'b0}};
                tally[i]        <= 9'b0;
                popcount[i]     <= 9'b0;
            end
        end else begin
            if (cycle_cnt == SLOT_BITS) begin
                // End of sweep. After 256 rotations the shifter holds the
                // value it was loaded with at sweep start — copy that into
                // slot_latched together with the matching popcount. Then
                // reload the shifter from current slot_flat for next sweep.
                for (i = 0; i < 8; i = i + 1) begin
                    popcount[i]     <= tally[i];
                    slot_latched[i] <= shift_reg[i];
                    tally[i]        <= 9'b0;
                    shift_reg[i]    <= slot_flat[SLOT_BITS*i +: SLOT_BITS];
                end
                cycle_cnt   <= 9'b0;
                state_valid <= 1'b1;        // latched on, stays on forever
            end else begin
                // In-sweep cycle — tally + rotate each slot.
                for (i = 0; i < 8; i = i + 1) begin
                    tally[i]     <= tally[i] + {8'b0, shift_reg[i][0]};
                    shift_reg[i] <= {shift_reg[i][0], shift_reg[i][SLOT_BITS-1:1]};
                end
                cycle_cnt <= cycle_cnt + 9'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Per-slot sanity from the latched popcount.
    //   POP_LO = 32  → each slot must have at least 32 ones
    //   POP_HI = 224 → and at least 32 zeros
    //
    // 12σ from the BLAKE3-output mean of 128 ⇒ firing rate ~10⁻³³ by chance
    // ⇒ any firing is a deterministic fault signal.
    // -------------------------------------------------------------------------
    localparam [8:0] POP_LO = 9'd32;
    localparam [8:0] POP_HI = 9'd224;

    wire [3:0] slot_sane_A;
    wire [3:0] slot_sane_B;
    generate
        for (k = 0; k < 4; k = k + 1) begin : sanity
            assign slot_sane_A[k] = (popcount[k]   >= POP_LO) & (popcount[k]   <= POP_HI);
            assign slot_sane_B[k] = (popcount[k+4] >= POP_LO) & (popcount[k+4] <= POP_HI);
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Per-pair classification (combinational on slot_flat + latched popcounts).
    //   virgin  → both slots all-zero
    //   valid   → XOR=all-ones AND both slots have popcount in [32, 224]
    //   corrupt → anything else
    // -------------------------------------------------------------------------
    wire [SLOT_BITS-1:0] xor_pair [0:3];
    generate
        for (k = 0; k < 4; k = k + 1) begin : classify
            assign xor_pair[k]    = slot[k] ^ slot[k+4];
            assign pair_virgin[k] = ~(|slot[k]) & ~(|slot[k+4]);
            assign pair_valid[k]  = (&xor_pair[k]) & slot_sane_A[k] & slot_sane_B[k];
            assign pair_corrupt[k]= ~pair_virgin[k] & ~pair_valid[k];
        end
    endgenerate

    assign valid_count = {2'b0, pair_valid[0]} + {2'b0, pair_valid[1]}
                       + {2'b0, pair_valid[2]} + {2'b0, pair_valid[3]};
    assign all_virgin  = (pair_virgin == 4'b1111);

    // -------------------------------------------------------------------------
    // Recovered ira: lowest-indexed valid pair's A. When no pair is valid,
    // this resolves to all-zeros — meaningless, gated by byzantine_ok.
    // -------------------------------------------------------------------------
    assign ira = pair_valid[0] ? slot[0]
               : pair_valid[1] ? slot[1]
               : pair_valid[2] ? slot[2]
               : pair_valid[3] ? slot[3]
               : {SLOT_BITS{1'b0}};

    // -------------------------------------------------------------------------
    // Agreement check: each valid pair's A must equal the canonical (`ira`).
    // -------------------------------------------------------------------------
    wire [3:0] disagree;
    generate
        for (k = 0; k < 4; k = k + 1) begin : agree_check
            assign disagree[k] = pair_valid[k] & (slot[k] != ira);
        end
    endgenerate

    assign agreement_ok = ~(|disagree);
    assign byzantine_ok = (valid_count >= 3'd2) & agreement_ok;

    // -------------------------------------------------------------------------
    // 5-state classification
    // -------------------------------------------------------------------------
    assign state = all_virgin                            ? 3'd0    // VIRGIN
                 : ~byzantine_ok                         ? 3'd1    // FUCKED
                 : (valid_count == 3'd2)                 ? 3'd2    // DEGRADED-2
                 : (valid_count == 3'd3)                 ? 3'd3    // DEGRADED-1
                 :                                         3'd4;   // HEALTHY

endmodule
