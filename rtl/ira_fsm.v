// =============================================================================
// ira_fsm.v — KOHI → BLAKE3 → TAHU provisioning orchestrator
// =============================================================================
//
// Top-level state machine that ties together the entropy + conditioner +
// OTP storage modules into a complete `ira` provisioning ceremony, per
// IRA.md §"KOHI — gather", §"TAHU — burn".
//
// This module owns the *sequencing* of provisioning; it does NOT own:
//   - the rings (live in top.v, fed into trng.ring_in)
//   - the trng buffer (lives in trng.v)
//   - the blake3 core (lives in blake3_tree.v)
//   - the OTP slot storage (lives in otp.v)
//   - the pair classification (lives in inverted_pair_verify.v, combinational)
//
// It observes `chip_state` from inverted_pair_verify (which sees the OTP
// slots live) and reacts:
//
//   state=0 VIRGIN  + provision_request → run ceremony
//   state=1 FUCKED                       → assert chip_fucked, idle
//   state≥2 DEGRADED/HEALTHY              → chip is provisioned; nothing to do
//
// First-cut scope (this commit):
//   - KOHI: pulse trng_start, wait for gather_done or health_fail
//   - BLAKE3: pulse blake3_start, capture 256-bit ira_seed
//   - TAHU: burn slots 0..3 (A=ira_seed), then 4..7 (B=~ira_seed)
//   - No TATARI delay (TODO: add the BLAKE3-derived 256–1280 ms random pause)
//   - No per-burn read-back verify (the next power cycle's classifier read
//     naturally validates each pair; partial burns surface as FUCKED next boot)
//   - No wairua orchestration (separate FSM later, but sharing this module's
//     trng/blake3 instances via the same arbiter pattern)
//
// chip_fucked is asserted when:
//   - boot-time state == FUCKED (e.g., previous TAHU was interrupted), OR
//   - trng.health_fail latches during this boot's KOHI, OR
//   - an OTP burn is rejected (write to already-burned slot — shouldn't
//     happen on a fresh VIRGIN device; latches FUCKED defensively)
//
// =============================================================================

`timescale 1ns / 1ps

module ira_fsm (
    input  wire         clk,                 // enclave_clk
    input  wire         reset_n,

    // External trigger — pulse to start provisioning. Honored only when
    // chip_state == VIRGIN. Ignored otherwise (no-op).
    input  wire         provision_request,

    // Live classifier output (combinational from inverted_pair_verify)
    input  wire [2:0]   chip_state,          // 0=VIRGIN, 1=FUCKED, 2..4=operating
    input  wire         byzantine_ok,

    // trng.v handshake
    output reg          trng_start,
    input  wire         trng_busy,
    input  wire         trng_gather_done,
    input  wire         trng_health_fail,

    // blake3_tree.v handshake
    output reg          blake3_start,
    input  wire         blake3_busy,
    input  wire         blake3_ira_valid,
    input  wire [255:0] blake3_ira,

    // otp.v burn interface
    output reg  [2:0]   otp_write_addr,
    output reg  [255:0] otp_write_data,
    output reg          otp_write_enable,
    input  wire         otp_write_done,
    input  wire         otp_write_rejected,

    // Outputs to the rest of the chip
    output reg          chip_fucked,         // gate for codec's tx_drive_enable
    output reg          ceremony_busy,       // high during KOHI/BLAKE3/TAHU
    output reg          ceremony_done,       // 1-cycle pulse when TAHU completes
    output reg  [2:0]   fsm_state            // debug observability
);

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [2:0]
        ST_OBSERVE  = 3'd0,   // idle; gate chip_fucked from chip_state
        ST_KOHI     = 3'd1,   // trng running
        ST_BLAKE3   = 3'd2,   // blake3_tree conditioning
        ST_TAHU_A   = 3'd3,   // burn slots 0..3 (A = ira_seed)
        ST_TAHU_B   = 3'd4,   // burn slots 4..7 (B = ~ira_seed)
        ST_DONE     = 3'd5,   // pulse ceremony_done, return to OBSERVE
        ST_FUCKED   = 3'd6;   // latched failure; never leaves until POR

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    reg [255:0] ira_seed;      // captured from blake3_tree
    reg [1:0]   burn_idx;      // 0..3 within ST_TAHU_A or ST_TAHU_B
    reg         awaiting_burn; // high between write_enable pulse and write_done

    // Boot-time FUCKED detection: if we power up with chip_state == FUCKED
    // (a previous burn was interrupted), latch chip_fucked permanently.
    // This is observed combinationally from chip_state.
    wire boot_fucked = (chip_state == 3'd1);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fsm_state        <= ST_OBSERVE;
            trng_start       <= 1'b0;
            blake3_start     <= 1'b0;
            otp_write_addr   <= 3'b0;
            otp_write_data   <= 256'b0;
            otp_write_enable <= 1'b0;
            chip_fucked      <= 1'b0;
            ceremony_busy    <= 1'b0;
            ceremony_done    <= 1'b0;
            ira_seed         <= 256'b0;
            burn_idx         <= 2'b0;
            awaiting_burn    <= 1'b0;
        end else begin
            // Default deassertions (one-cycle strobes)
            trng_start       <= 1'b0;
            blake3_start     <= 1'b0;
            otp_write_enable <= 1'b0;
            ceremony_done    <= 1'b0;

            case (fsm_state)
                // ----------------------------------------------------------
                // ST_OBSERVE: idle. Pass FUCKED through to chip_fucked. If
                // VIRGIN + provision_request, kick off the ceremony.
                // ----------------------------------------------------------
                ST_OBSERVE: begin
                    ceremony_busy <= 1'b0;
                    chip_fucked   <= boot_fucked;
                    if (boot_fucked) begin
                        fsm_state <= ST_FUCKED;
                    end else if ((chip_state == 3'd0) && provision_request) begin
                        // VIRGIN + request → kick off KOHI
                        trng_start    <= 1'b1;
                        ceremony_busy <= 1'b1;
                        fsm_state     <= ST_KOHI;
                    end
                end

                // ----------------------------------------------------------
                // ST_KOHI: wait for trng.gather_done (success) or
                // trng.health_fail (broken silicon → FUCKED).
                // ----------------------------------------------------------
                ST_KOHI: begin
                    if (trng_health_fail) begin
                        chip_fucked <= 1'b1;
                        fsm_state   <= ST_FUCKED;
                    end else if (trng_gather_done) begin
                        blake3_start <= 1'b1;
                        fsm_state    <= ST_BLAKE3;
                    end
                end

                // ----------------------------------------------------------
                // ST_BLAKE3: wait for the conditioner to produce ira_seed.
                // ----------------------------------------------------------
                ST_BLAKE3: begin
                    if (blake3_ira_valid) begin
                        ira_seed <= blake3_ira;
                        burn_idx <= 2'b0;
                        fsm_state <= ST_TAHU_A;
                    end
                end

                // ----------------------------------------------------------
                // ST_TAHU_A: burn slots 0, 1, 2, 3 with ira_seed.
                // For each slot: pulse write_enable, wait write_done.
                // ----------------------------------------------------------
                ST_TAHU_A: begin
                    if (!awaiting_burn) begin
                        otp_write_addr   <= {1'b0, burn_idx};
                        otp_write_data   <= ira_seed;
                        otp_write_enable <= 1'b1;
                        awaiting_burn    <= 1'b1;
                    end else if (otp_write_done) begin
                        awaiting_burn <= 1'b0;
                        if (burn_idx == 2'd3) begin
                            burn_idx  <= 2'b0;
                            fsm_state <= ST_TAHU_B;
                        end else begin
                            burn_idx <= burn_idx + 2'd1;
                        end
                    end else if (otp_write_rejected) begin
                        // Slot was already burned — should be impossible on
                        // a fresh VIRGIN chip. Defensive: latch FUCKED.
                        chip_fucked <= 1'b1;
                        fsm_state   <= ST_FUCKED;
                    end
                end

                // ----------------------------------------------------------
                // ST_TAHU_B: burn slots 4, 5, 6, 7 with ~ira_seed.
                // ----------------------------------------------------------
                ST_TAHU_B: begin
                    if (!awaiting_burn) begin
                        otp_write_addr   <= {1'b1, burn_idx};
                        otp_write_data   <= ~ira_seed;
                        otp_write_enable <= 1'b1;
                        awaiting_burn    <= 1'b1;
                    end else if (otp_write_done) begin
                        awaiting_burn <= 1'b0;
                        if (burn_idx == 2'd3) begin
                            fsm_state <= ST_DONE;
                        end else begin
                            burn_idx <= burn_idx + 2'd1;
                        end
                    end else if (otp_write_rejected) begin
                        chip_fucked <= 1'b1;
                        fsm_state   <= ST_FUCKED;
                    end
                end

                // ----------------------------------------------------------
                // ST_DONE: ceremony complete. inverted_pair_verify now sees
                // all 4 pairs valid → chip_state becomes HEALTHY (or
                // DEGRADED-N if some slots disagree, which would itself
                // indicate hardware fault).
                // ----------------------------------------------------------
                ST_DONE: begin
                    ceremony_done <= 1'b1;
                    fsm_state     <= ST_OBSERVE;
                end

                // ----------------------------------------------------------
                // ST_FUCKED: terminal. Never exits except via POR.
                // ----------------------------------------------------------
                ST_FUCKED: begin
                    chip_fucked   <= 1'b1;
                    ceremony_busy <= 1'b0;
                end

                default: fsm_state <= ST_OBSERVE;
            endcase
        end
    end

endmodule
