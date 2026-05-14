// =============================================================================
// inverted_pair_verify.v — 4-pair XOR-to-all-ones classifier
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
//
// This module is shared between two consumers per Claim 4a:
//   - persistent: 8 OTP slots holding ira / ~ira → boot-time identity classifier
//   - ephemeral:  8 RAM slots holding wairua / ~wairua → session-time classifier
//
// Slot layout (caller's responsibility — this module sees raw 256-bit values):
//   slot[0..3] = pair 0..3 A (holds ira or wairua)
//   slot[4..7] = pair 0..3 B (holds ~ira or ~wairua)
//
// Per-pair classification, where xor_pair = slot[i] XOR slot[i+4]:
//   xor_pair == 0           → virgin   (both slots unburned / unset)
//   xor_pair == all-ones    → valid    (properly inverted)
//   xor_pair == else        → corrupt  (partial burn, aging, attack, cosmic ray)
//
// Aggregate state (5 values, matching IRA.md table):
//   0 VIRGIN     → all 4 pairs virgin
//   1 FUCKED     → fewer than 2 valid pairs, OR valid pairs disagree on ira
//   2 DEGRADED-2 → exactly 2 valid pairs, all agreeing on ira
//   3 DEGRADED-1 → exactly 3 valid pairs, all agreeing on ira
//   4 HEALTHY    → all 4 pairs valid, all agreeing on ira
//
// =============================================================================

`timescale 1ns / 1ps

module inverted_pair_verify #(
    parameter integer SLOT_BITS = 256
) (
    // 8 slot values packed: slot 0 at bits [SLOT_BITS-1:0], slot 7 at top.
    input  wire [8*SLOT_BITS-1:0] slot_flat,

    // Per-pair classification (one bit per pair, 4 pairs).
    output wire [3:0]             pair_virgin,
    output wire [3:0]             pair_valid,
    output wire [3:0]             pair_corrupt,

    // Aggregate
    output wire [2:0]             valid_count,    // 0..4
    output wire                   all_virgin,     // pair_virgin == 4'b1111
    output wire                   agreement_ok,   // all valid pairs hold same A
    output wire                   byzantine_ok,   // valid_count >= 2 AND agreement_ok
    output wire [2:0]             state,          // 0=VIRGIN 1=FUCKED 2..4=operating

    // Recovered ira = lowest-indexed valid pair's A slot. Caller must gate
    // its use on byzantine_ok — when byzantine_ok=0, ira is whatever the
    // first valid pair (if any) holds, or all-zeros (in VIRGIN/all-corrupt
    // cases). It is NOT cryptographically meaningful in those cases.
    output wire [SLOT_BITS-1:0]   ira
);

    // -------------------------------------------------------------------------
    // Unpack the 8 slots
    // -------------------------------------------------------------------------
    wire [SLOT_BITS-1:0] slot [0:7];
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : unpack
            assign slot[k] = slot_flat[SLOT_BITS*k +: SLOT_BITS];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Per-pair classification.
    //   xor_pair[i] = slot[i] XOR slot[i+4]   (A XOR B)
    //   virgin = all zeros, valid = all ones, corrupt = anything else
    // -------------------------------------------------------------------------
    wire [SLOT_BITS-1:0] xor_pair [0:3];
    generate
        for (k = 0; k < 4; k = k + 1) begin : classify
            assign xor_pair[k]    = slot[k] ^ slot[k+4];
            assign pair_virgin[k] = (xor_pair[k] == {SLOT_BITS{1'b0}});
            assign pair_valid[k]  = (xor_pair[k] == {SLOT_BITS{1'b1}});
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
    // Corrupt and virgin pairs are skipped (pair_valid[i] gate). The
    // canonical's own pair satisfies the equality trivially. This is the
    // 4-comparison form of the 6-pair round-robin — same correctness, ~33%
    // less LUT cost than the all-pairs-pairwise version.
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
