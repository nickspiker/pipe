// =============================================================================
// inverted_pair_verify.v — 4-pair classifier (serial-per-bit-position sweep)
// =============================================================================
//
// Combinational-equivalent classifier for the inverted-pair storage geometry described in IRA.md §"OTP geometry" / §"The five lifelong states". Takes 8 slot values (4 pairs × {A, B}) and produces:
//
//   - per-pair classification (kore / valid / corrupt)
//   - aggregate 5-state machine code (KORE / NGARO / WHARA / HARA / ORA)
//   - recovered ira value (lowest-indexed valid pair's A slot, or zero)
//   - byzantine_ok strobe (≥2 valid pairs AND all valid pairs agree on ira)
//   - state_valid strobe (high after first complete sweep)
//
// Outputs are REGISTERED, sampled at the end of each 257-cycle sweep. During the sweep the registered outputs hold their last-latched values; consumers (ira_fsm) read them whenever, with the understanding that any change in slot_flat is reflected at most 2 sweeps later. ira_fsm is responsible for waiting two full sweeps after OTP burns before reading chip_state.
//
// Implementation — serial accumulators, one bit position per cycle:
//
//   sweep_addr counts 0..256. At cycle j ∈ [0, 255] we read 8 bits at slot
//   position j (one bit per slot, via slot[s][sweep_addr]). For each pair k:
//     all_ones[k]   &= (bit_A_k ^ bit_B_k)      // 1 if XOR was all-ones
//     has_one_A[k]  |= bit_A_k                   // 0 if slot A all-zero
//     has_one_B[k]  |= bit_B_k                   // 0 if slot B all-zero
//   For each ordered pair (i, j) of A-slots with i<j (6 total):
//     pair_disagree[i,j] |= (bit_A_i ^ bit_A_j) // 1 if A_i ever differed from A_j
//   For each slot s ∈ 0..7:
//     popcount[s]   += bit_s                     // running 1-count
//     toggles[s]    += (bit_s != prev_bit[s])    // running edge count
//
// At cycle 256 (end_of_sweep), the running accumulators ARE the complete classifier inputs. Combinational logic on those (no 256-bit-wide ops anywhere) computes pair_kore/pair_valid/pair_corrupt/valid_count/ agreement_ok/state/ira and latches them into the output registers. The sweep then restarts.
//
// Cost vs. prior parallel-combinational design: replaces twenty 256-bit- wide operations with single-bit accumulators (~5K LUT savings). Replaces 2K-FF slot_latched + load-mux with zero copy (~2K LUT + 2K FF savings).
// Total module cost: ~1.5K LUTs / ~600 FFs.
//
// Slot layout (caller's responsibility — this module sees raw 256-bit values):
//   slot[0..3] = pair 0..3 A (holds ira or wairua)
//   slot[4..7] = pair 0..3 B (holds ~ira or ~wairua)
//
// Per-pair classification:
//   kore  → both slots are all-zero (the genuine unburned state)
//   valid   → A XOR B == all-ones AND each slot's popcount ∈ [POP_LO, POP_HI]
//             AND each slot's toggle count ≥ TOG_MIN
//   corrupt → anything else
//
// =============================================================================

`timescale 1ns / 1ps

module inverted_pair_verify #(
    parameter integer SLOT_BITS = 256
) (
    input  wire                   clk,
    input  wire                   reset_n,

    input  wire [8*SLOT_BITS-1:0] slot_flat,

    output reg                    state_valid,
    output reg  [3:0]             pair_kore,
    output reg  [3:0]             pair_valid,
    output reg  [3:0]             pair_corrupt,
    output reg  [2:0]             valid_count,
    output reg                    all_kore,
    output reg                    agreement_ok,
    output reg                    byzantine_ok,
    // chip_ngaro is true when the chip is in the silent failure state -- valid_count < 2 and not all_kore. The chip's FSM uses this to gate wire output; the host infers NGARO from the absence of any wire response.
    output reg                    chip_ngaro,
    // 2-bit wire-reportable state. NGARO is not encoded here since the chip in NGARO does not transmit; the host infers NGARO from no response. The numeric value rises with chip vitality (= number of valid pairs, modulo the KORE/NGARO gap).
    //   KORE  = 2'd0  (0 valid pairs, storage all zero)
    //   WHARA = 2'd1  (2 valid pairs, at byzantine minimum)
    //   HARA  = 2'd2  (3 valid pairs, single fault tolerated)
    //   ORA   = 2'd3  (4 valid pairs, fully healthy)
    output reg  [1:0]             state,
    output reg  [SLOT_BITS-1:0]   ira
);

    // State code constants (matching the localparam style used in callers).
    localparam [1:0] ST_KORE  = 2'd0;
    localparam [1:0] ST_WHARA = 2'd1;
    localparam [1:0] ST_HARA  = 2'd2;
    localparam [1:0] ST_ORA   = 2'd3;

    // -------------------------------------------------------------------------
    // Unpack the 8 slots — combinational views of slot_flat.
    // -------------------------------------------------------------------------
    wire [SLOT_BITS-1:0] slot [0:7];
    genvar gs;
    generate
        for (gs = 0; gs < 8; gs = gs + 1) begin : unpack
            assign slot[gs] = slot_flat[SLOT_BITS*gs +: SLOT_BITS];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Sweep counter — 0..SLOT_BITS (0..256). One bit position per cycle for 0..SLOT_BITS-1; cycle SLOT_BITS = "end of sweep", finalize and restart.
    // -------------------------------------------------------------------------
    reg [8:0] sweep_addr;
    wire end_of_sweep = (sweep_addr == SLOT_BITS[8:0]);

    // 8 bits at the current sweep position (one per slot).
    wire [7:0] bit_now;
    generate
        for (gs = 0; gs < 8; gs = gs + 1) begin : extract
            assign bit_now[gs] = slot[gs][sweep_addr[7:0]];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Running per-pair accumulators (reset on each sweep restart).
    //   all_ones[k]   starts 1; ANDed with (A_bit ^ B_bit) each cycle → 1 iff
    //                 every bit position had A_bit != B_bit (XOR all-ones)
    //   has_one_A[k]  starts 0; ORed with A_bit each cycle → 0 iff A all-zero
    //   has_one_B[k]  starts 0; ORed with B_bit each cycle → 0 iff B all-zero
    //   pair_disagree[i] starts 0; ORed with (A_p ^ A_q) for the i-th (p, q)
    //                 pair → 1 iff A_p ever differed from A_q
    // -------------------------------------------------------------------------
    reg [3:0] all_ones;
    reg [3:0] has_one_A;
    reg [3:0] has_one_B;
    reg [5:0] pair_disagree;   // 6 pairs: (0,1), (0,2), (0,3), (1,2), (1,3), (2,3)

    // Per-slot popcount + toggle + prev_bit (for edge detect within the slot).
    reg [8:0] popcount [0:7];
    reg [8:0] toggles  [0:7];
    reg [7:0] prev_bit;

    // -------------------------------------------------------------------------
    // Per-slot sanity bands.
    //   POP_LO/HI: 1/8..7/8 of 256 — accepts up to ±75% bias
    //   TOG_MIN:   N/64 — catches all-zero / all-one / single-transition degeneracies
    // -------------------------------------------------------------------------
    localparam [8:0] POP_LO  = 9'd32;
    localparam [8:0] POP_HI  = 9'd224;
    localparam [8:0] TOG_MIN = 9'd4;

    wire [3:0] slot_sane_A;
    wire [3:0] slot_sane_B;
    genvar gk;
    generate
        for (gk = 0; gk < 4; gk = gk + 1) begin : sanity
            assign slot_sane_A[gk] = (popcount[gk]   >= POP_LO)
                                   & (popcount[gk]   <= POP_HI)
                                   & (toggles[gk]    >= TOG_MIN);
            assign slot_sane_B[gk] = (popcount[gk+4] >= POP_LO)
                                   & (popcount[gk+4] <= POP_HI)
                                   & (toggles[gk+4]  >= TOG_MIN);
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Final classification (combinational on the small accumulators + slot_flat for the ira recovery mux). Latched at end_of_sweep into the output regs.
    // -------------------------------------------------------------------------
    wire [3:0] c_pair_kore;
    wire [3:0] c_pair_valid;
    wire [3:0] c_pair_corrupt;
    generate
        for (gk = 0; gk < 4; gk = gk + 1) begin : classify
            assign c_pair_kore[gk] = ~has_one_A[gk] & ~has_one_B[gk];
            assign c_pair_valid[gk]  = all_ones[gk] & slot_sane_A[gk] & slot_sane_B[gk];
            assign c_pair_corrupt[gk]= ~c_pair_kore[gk] & ~c_pair_valid[gk];
        end
    endgenerate

    wire [2:0] c_valid_count = {2'b0, c_pair_valid[0]} + {2'b0, c_pair_valid[1]}
                              + {2'b0, c_pair_valid[2]} + {2'b0, c_pair_valid[3]};
    wire c_all_kore = (c_pair_kore == 4'b1111);

    // Agreement check: any (i, j) pair of valid pairs where A_i differs from A_j.
    wire c_disagree_01 = pair_disagree[0] & c_pair_valid[0] & c_pair_valid[1];
    wire c_disagree_02 = pair_disagree[1] & c_pair_valid[0] & c_pair_valid[2];
    wire c_disagree_03 = pair_disagree[2] & c_pair_valid[0] & c_pair_valid[3];
    wire c_disagree_12 = pair_disagree[3] & c_pair_valid[1] & c_pair_valid[2];
    wire c_disagree_13 = pair_disagree[4] & c_pair_valid[1] & c_pair_valid[3];
    wire c_disagree_23 = pair_disagree[5] & c_pair_valid[2] & c_pair_valid[3];
    wire c_agreement_ok = ~(c_disagree_01 | c_disagree_02 | c_disagree_03
                          | c_disagree_12 | c_disagree_13 | c_disagree_23);
    wire c_byzantine_ok = (c_valid_count >= 3'd2) & c_agreement_ok;

    // ira recovery: lowest-indexed valid pair's A. 4-way 256-bit mux — the one place we still touch full slot widths (combinational at sweep end).
    wire [SLOT_BITS-1:0] c_ira = c_pair_valid[0] ? slot[0]
                                : c_pair_valid[1] ? slot[1]
                                : c_pair_valid[2] ? slot[2]
                                : c_pair_valid[3] ? slot[3]
                                : {SLOT_BITS{1'b0}};

    // 2-bit wire-reportable state. NGARO is not encoded -- it is a separate signal that gates wire output (chip is silent in NGARO).
    wire [1:0] c_state = (c_valid_count == 3'd4) ? ST_ORA
                       : (c_valid_count == 3'd3) ? ST_HARA
                       : (c_valid_count == 3'd2) ? ST_WHARA
                       :                            ST_KORE;   // valid_count 0 or 1 (1 collapses to KORE since chip is silent anyway)

    // chip_ngaro: byzantine fail and not in the pristine all-kore state.
    wire c_chip_ngaro = ~c_byzantine_ok & ~c_all_kore;

    // -------------------------------------------------------------------------
    // Sweep FSM — single always block driving all state and outputs.
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sweep_addr    <= 9'b0;
            state_valid   <= 1'b0;
            all_ones      <= 4'b1111;
            has_one_A     <= 4'b0;
            has_one_B     <= 4'b0;
            pair_disagree <= 6'b0;
            prev_bit      <= 8'b0;
            pair_kore   <= 4'b0;
            pair_valid    <= 4'b0;
            pair_corrupt  <= 4'b0;
            valid_count   <= 3'b0;
            all_kore    <= 1'b0;
            agreement_ok  <= 1'b0;
            byzantine_ok  <= 1'b0;
            chip_ngaro    <= 1'b0;
            state         <= ST_KORE;
            ira           <= {SLOT_BITS{1'b0}};
            for (i = 0; i < 8; i = i + 1) begin
                popcount[i] <= 9'b0;
                toggles[i]  <= 9'b0;
            end
        end else if (end_of_sweep) begin
            // Latch the classifier outputs from the matched accumulators.
            pair_kore  <= c_pair_kore;
            pair_valid   <= c_pair_valid;
            pair_corrupt <= c_pair_corrupt;
            valid_count  <= c_valid_count;
            all_kore   <= c_all_kore;
            agreement_ok <= c_agreement_ok;
            byzantine_ok <= c_byzantine_ok;
            chip_ngaro   <= c_chip_ngaro;
            state        <= c_state;
            ira          <= c_ira;
            state_valid  <= 1'b1;

            // Restart the sweep: clear all accumulators.
            sweep_addr    <= 9'b0;
            all_ones      <= 4'b1111;
            has_one_A     <= 4'b0;
            has_one_B     <= 4'b0;
            pair_disagree <= 6'b0;
            prev_bit      <= 8'b0;
            for (i = 0; i < 8; i = i + 1) begin
                popcount[i] <= 9'b0;
                toggles[i]  <= 9'b0;
            end
        end else begin
            // Per-cycle accumulation.
            prev_bit <= bit_now;

            // Per-pair pair_xor & kore accumulators (only k=0..3).
            for (i = 0; i < 4; i = i + 1) begin
                all_ones[i]  <= all_ones[i]  & (bit_now[i] ^ bit_now[i+4]);
                has_one_A[i] <= has_one_A[i] | bit_now[i];
                has_one_B[i] <= has_one_B[i] | bit_now[i+4];
            end

            // 6 pairwise A-vs-A disagreements (for agreement check).
            pair_disagree[0] <= pair_disagree[0] | (bit_now[0] ^ bit_now[1]);
            pair_disagree[1] <= pair_disagree[1] | (bit_now[0] ^ bit_now[2]);
            pair_disagree[2] <= pair_disagree[2] | (bit_now[0] ^ bit_now[3]);
            pair_disagree[3] <= pair_disagree[3] | (bit_now[1] ^ bit_now[2]);
            pair_disagree[4] <= pair_disagree[4] | (bit_now[1] ^ bit_now[3]);
            pair_disagree[5] <= pair_disagree[5] | (bit_now[2] ^ bit_now[3]);

            // Per-slot popcount + toggle (toggle is gated on sweep_addr != 0 since prev_bit isn't meaningful at position 0).
            for (i = 0; i < 8; i = i + 1) begin
                popcount[i] <= popcount[i] + {8'b0, bit_now[i]};
                if (sweep_addr != 9'b0) begin
                    toggles[i] <= toggles[i] + {8'b0, bit_now[i] ^ prev_bit[i]};
                end
            end

            sweep_addr <= sweep_addr + 9'b1;
        end
    end

endmodule
