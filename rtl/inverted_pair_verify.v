// =============================================================================
// inverted_pair_verify.v — 4-pair XOR-to-all-ones classifier (low-and-slow)
// =============================================================================
//
// Combinational-ish classifier for the inverted-pair storage geometry
// described in IRA.md §"OTP geometry" / §"The five lifelong states". Takes
// 8 slot values (4 pairs × {A, B}) and produces:
//
//   - per-pair classification (virgin / valid / corrupt)
//   - aggregate 5-state machine code (VIRGIN / FUCKED / DEGRADED-{2,1} / HEALTHY)
//   - recovered ira value (lowest-indexed valid pair's A slot, or zero)
//   - byzantine_ok strobe (≥2 valid pairs AND all valid pairs agree on ira)
//   - state_valid strobe (high after first complete popcount sweep)
//
// Outputs are REGISTERED, sampled at the end of each 2049-cycle sweep.
// During the sweep the registered outputs hold their last-latched values;
// consumers (ira_fsm) read them whenever, with the understanding that
// any change in slot_flat is reflected at most 2 sweeps later.
//
// Shared between two consumers per Claim 4a:
//   - persistent: 8 OTP slots holding ira / ~ira → boot-time identity classifier
//   - ephemeral:  8 RAM slots holding wairua / ~wairua → session-time classifier
//
// Slot layout: slot[i] = slot_flat[256*i +: 256], i in 0..7.
//   slot[0..3] = pair 0..3 A (holds ira or wairua)
//   slot[4..7] = pair 0..3 B (holds ~ira or ~wairua)
//
// Per-pair classification:
//   virgin  → both slots are all-zero (the genuine unburned state)
//   valid   → A XOR B == all-ones  AND  each slot's popcount ∈ [32, 224]
//   corrupt → anything else
//
// The popcount sanity check defends against degenerate cases — most
// notably A=0/B=all-ones which XORs to all-ones but encodes a meaningless
// ira. BLAKE3-output popcount sits at ~128±8; the [32, 224] band is 12σ
// from the mean, ~10⁻³³ false-positive rate by chance, so any firing is
// a deterministic fault signal.
//
// Implementation: one 11-bit sweep address (3-bit slot_idx + 8-bit
// bit_idx), one 9-bit active tally, one 2048-to-1 mux to read
// slot_flat[address]. At each cycle:
//   - tally += slot_flat[address]
// At end of each 256-cycle slot pass:
//   - popcount[slot_idx] <= tally + last_bit; tally <= 0
// At end of full 2048-cycle sweep:
//   - all popcounts are fresh (computed against the same slot_flat held
//     during the sweep — see note below)
//   - classifier outputs latched from combinational logic on (slot_flat,
//     popcount); state_valid asserts
//
// **slot_flat stability requirement**: the caller (ira_fsm) is responsible
// for not changing slot_flat during a sweep, OR for waiting one full
// sweep after any change before trusting the outputs. mid-sweep changes
// produce garbage popcounts and undefined classifier outputs until the
// next complete clean sweep. This trades a little FSM complexity for
// ~2 KB FFs of saved snapshot storage.
// =============================================================================

`timescale 1ns / 1ps

module inverted_pair_verify #(
    parameter integer SLOT_BITS = 256
) (
    input  wire                   clk,
    input  wire                   reset_n,

    input  wire [8*SLOT_BITS-1:0] slot_flat,

    output reg                    state_valid,
    output reg  [3:0]             pair_virgin,
    output reg  [3:0]             pair_valid,
    output reg  [3:0]             pair_corrupt,
    output reg  [2:0]             valid_count,
    output reg                    all_virgin,
    output reg                    agreement_ok,
    output reg                    byzantine_ok,
    output reg  [2:0]             state,
    output reg  [SLOT_BITS-1:0]   ira
);

    // -------------------------------------------------------------------------
    // Slot views — combinational into slot_flat.
    // -------------------------------------------------------------------------
    wire [SLOT_BITS-1:0] slot [0:7];
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : unpack
            assign slot[k] = slot_flat[SLOT_BITS*k +: SLOT_BITS];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Sweep — 2048 cycles, one bit per cycle, sequential through slots.
    //   sweep_addr [10:8] = slot_idx (0..7)
    //   sweep_addr [7:0]  = bit_idx   (0..255)
    // -------------------------------------------------------------------------
    reg [10:0] sweep_addr;
    reg [8:0]  tally;          // running popcount this slot
    reg [8:0]  toggle_tally;   // running toggle count this slot
    reg        prev_bit;       // for edge detect within current slot
    reg [8:0]  popcount [0:7];
    reg [8:0]  toggles  [0:7];

    wire [2:0] slot_idx_now  = sweep_addr[10:8];
    wire       end_of_slot   = &sweep_addr[7:0];                 // bit_idx == 0xFF
    wire       end_of_sweep  = &sweep_addr;                       // slot 7 bit 255
    wire       current_bit   = slot_flat[sweep_addr];             // 2048-to-1 mux

    // -------------------------------------------------------------------------
    // Combinational classifier on slot_flat + popcount — computed always,
    // latched into the output registers at end_of_sweep.
    // -------------------------------------------------------------------------
    localparam [8:0] POP_LO = 9'd32;     // 1/8 of 256 = 32 ones minimum
    localparam [8:0] POP_HI = 9'd224;    // 7/8 of 256 = max 224 ones (= 32 zeros minimum)
    localparam [8:0] TOG_MIN = 9'd16;    // 1/8 of expected N/2 toggles = 16 edges minimum

    wire [3:0] slot_sane_A;
    wire [3:0] slot_sane_B;
    wire [3:0] c_pair_virgin;
    wire [3:0] c_pair_valid;
    wire [3:0] c_pair_corrupt;
    wire [SLOT_BITS-1:0] xor_pair [0:3];
    generate
        for (k = 0; k < 4; k = k + 1) begin : classify_comb
            assign slot_sane_A[k]   = (popcount[k]   >= POP_LO)
                                    & (popcount[k]   <= POP_HI)
                                    & (toggles[k]    >= TOG_MIN);
            assign slot_sane_B[k]   = (popcount[k+4] >= POP_LO)
                                    & (popcount[k+4] <= POP_HI)
                                    & (toggles[k+4]  >= TOG_MIN);
            assign xor_pair[k]      = slot[k] ^ slot[k+4];
            assign c_pair_virgin[k] = ~(|slot[k]) & ~(|slot[k+4]);
            assign c_pair_valid[k]  = (&xor_pair[k]) & slot_sane_A[k] & slot_sane_B[k];
            assign c_pair_corrupt[k]= ~c_pair_virgin[k] & ~c_pair_valid[k];
        end
    endgenerate

    wire [2:0] c_valid_count = {2'b0, c_pair_valid[0]} + {2'b0, c_pair_valid[1]}
                              + {2'b0, c_pair_valid[2]} + {2'b0, c_pair_valid[3]};
    wire       c_all_virgin  = (c_pair_virgin == 4'b1111);
    wire [SLOT_BITS-1:0] c_ira = c_pair_valid[0] ? slot[0]
                                : c_pair_valid[1] ? slot[1]
                                : c_pair_valid[2] ? slot[2]
                                : c_pair_valid[3] ? slot[3]
                                : {SLOT_BITS{1'b0}};
    wire [3:0] c_disagree;
    generate
        for (k = 0; k < 4; k = k + 1) begin : agree_check
            assign c_disagree[k] = c_pair_valid[k] & (slot[k] != c_ira);
        end
    endgenerate
    wire c_agreement_ok = ~(|c_disagree);
    wire c_byzantine_ok = (c_valid_count >= 3'd2) & c_agreement_ok;
    wire [2:0] c_state  = c_all_virgin   ? 3'd0
                        : ~c_byzantine_ok ? 3'd1
                        : (c_valid_count == 3'd2) ? 3'd2
                        : (c_valid_count == 3'd3) ? 3'd3
                        :                            3'd4;

    // -------------------------------------------------------------------------
    // Sweep FSM + output latching — single always block, no two-driver split.
    // latch_outputs pulses high one cycle after end_of_sweep so popcount[7]
    // has settled before c_state etc. sample it.
    // -------------------------------------------------------------------------
    reg latch_outputs;
    integer i;
    wire bit_idx_zero  = (sweep_addr[7:0] == 8'b0);      // first bit of a slot
    wire edge_this_cyc = ~bit_idx_zero & (current_bit ^ prev_bit);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sweep_addr    <= 11'b0;
            tally         <= 9'b0;
            toggle_tally  <= 9'b0;
            prev_bit      <= 1'b0;
            state_valid   <= 1'b0;
            latch_outputs <= 1'b0;
            pair_virgin   <= 4'b0;
            pair_valid    <= 4'b0;
            pair_corrupt  <= 4'b0;
            valid_count   <= 3'b0;
            all_virgin    <= 1'b0;
            agreement_ok  <= 1'b0;
            byzantine_ok  <= 1'b0;
            state         <= 3'b0;
            ira           <= {SLOT_BITS{1'b0}};
            for (i = 0; i < 8; i = i + 1) begin
                popcount[i] <= 9'b0;
                toggles[i]  <= 9'b0;
            end
        end else begin
            // One-cycle delay so the latch fires after popcount/toggles[7] update.
            latch_outputs <= end_of_sweep;

            // Latch the classifier outputs from the combinational view of
            // (slot_flat, popcount, toggles) when those are freshly complete.
            if (latch_outputs) begin
                pair_virgin  <= c_pair_virgin;
                pair_valid   <= c_pair_valid;
                pair_corrupt <= c_pair_corrupt;
                valid_count  <= c_valid_count;
                all_virgin   <= c_all_virgin;
                agreement_ok <= c_agreement_ok;
                byzantine_ok <= c_byzantine_ok;
                state        <= c_state;
                ira          <= c_ira;
            end

            // Track current bit for next cycle's edge detect.
            prev_bit <= current_bit;

            // Sweep stepping. Slot boundaries: latch popcount + toggles,
            // reset tallies, reset prev_bit so we don't count a cross-slot edge.
            if (end_of_sweep) begin
                popcount[7] <= tally + {8'b0, current_bit};
                toggles[7]  <= toggle_tally + {8'b0, edge_this_cyc};
                tally       <= 9'b0;
                toggle_tally<= 9'b0;
                sweep_addr  <= 11'b0;
                state_valid <= 1'b1;
            end else if (end_of_slot) begin
                popcount[slot_idx_now] <= tally + {8'b0, current_bit};
                toggles[slot_idx_now]  <= toggle_tally + {8'b0, edge_this_cyc};
                tally        <= 9'b0;
                toggle_tally <= 9'b0;
                sweep_addr   <= sweep_addr + 11'd1;
            end else begin
                tally        <= tally + {8'b0, current_bit};
                toggle_tally <= toggle_tally + {8'b0, edge_this_cyc};
                sweep_addr   <= sweep_addr + 11'd1;
            end
        end
    end

endmodule
