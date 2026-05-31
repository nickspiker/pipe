// =============================================================================
// chal_resp_fsm.v — operational-mode challenge/response over the PIPE wire
// =============================================================================
//
// Once ira_fsm has driven the chip to HEALTHY, this FSM owns the wire. It
// listens for a host-driven sync + 256-bit challenge, drives the shared
// BLAKE3 core to compute response = BLAKE3_keyed_hash(IRA, challenge), and
// transmits the response back with Claim 12a framing (leading-zero
// suppression + trailing-1 marker).
//
// All wire timing matches the top_pipe_counter convention: 2 wire_clks per
// bit, sub-phase 0 driven HIGH (host slot placeholder), sub-phase 1 carries
// the bit value. wire_tick fires once per "wire_clk equivalent" by counting
// enclave_clk cycles, keeping the whole FSM single-clock so BLAKE3 access
// doesn't need CDC.
//
// Wire bit ordering:
//   Challenge (host → FPGA): byte 0 first; within each byte, bit 0 (LSB)
//     first. challenge_reg[i] = i-th bit received → byte (i>>3),
//     bit-in-byte (i & 7). Matches the counter convention.
//   Response (FPGA → host): 256-bit number sent MSB-first (bit 255 first,
//     bit 0 last) with leading-zero suppression. The MSB-first ordering
//     is what makes leading-zero suppression natural for Claim 12a.
//
// BLAKE3 invocation (matches `blake3::keyed_hash(&ira, &challenge)`):
//   i_chain     = ira_value (256 bits, word-LE per BLAKE3 spec)
//   i_mblock    = {32 bytes of zeros, 32-byte challenge} — challenge in low
//                 256 bits, padding in high 256 bits
//   i_counter   = 0  (first and only chunk)
//   i_numbytes  = 32 (message size)
//   i_dflags    = CHUNK_START | CHUNK_END | ROOT | KEYED_HASH = 0x1B
//   Response is taken from o_hash[255:0] (low 256 bits of the 512-bit output).
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module chal_resp_fsm (
    input  wire        clk,                // enclave_clk
    input  wire        reset_n,

    // Gate from ira_fsm: only operate when chip is HEALTHY.
    input  wire        chip_healthy,

    // Wire I/O (already-synchronized wire_in from wire_io's 2-FF sync)
    input  wire        wire_in_sync,
    output reg         wire_out,
    output reg         drive_en,

    // IRA — 256-bit secret from the key_register (operational view)
    input  wire [255:0] ira_value,

    // BLAKE3 control (this FSM drives these during operational mode; top mux
    // them with ira_fsm's BLAKE3 driver when ceremony is busy)
    output reg          blake3_start,
    output reg  [255:0] blake3_chain,
    output reg  [511:0] blake3_mblock,
    output reg  [63:0]  blake3_counter,
    output reg  [31:0]  blake3_numbytes,
    output reg  [31:0]  blake3_dflags,
    input  wire         blake3_valid,
    input  wire [511:0] blake3_hash,

    // Debug
    output reg  [3:0]   fsm_state_debug
);

    // -------------------------------------------------------------------------
    // wire_tick generator: enclave_clk divided by 2^WIRE_DIV_LOG2 = 256.
    // wire_tick pulses for exactly one enclave_clk cycle each "wire-clock"
    // period. This keeps the FSM single-domain (no CDC to BLAKE3) while
    // preserving the existing counter wire-period (~89 µs).
    // -------------------------------------------------------------------------
    parameter integer WIRE_DIV_LOG2 = 8;
    reg [WIRE_DIV_LOG2-1:0] wdiv;
    wire wire_tick = (wdiv == {WIRE_DIV_LOG2{1'b0}});
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) wdiv <= {WIRE_DIV_LOG2{1'b0}};
        else          wdiv <= wdiv + {{(WIRE_DIV_LOG2-1){1'b0}}, 1'b1};
    end

    // -------------------------------------------------------------------------
    // BLAKE3 flag constants
    // -------------------------------------------------------------------------
    localparam [31:0] DFLAG_CHUNK_START = 32'h01;
    localparam [31:0] DFLAG_CHUNK_END   = 32'h02;
    localparam [31:0] DFLAG_ROOT        = 32'h08;
    localparam [31:0] DFLAG_KEYED_HASH  = 32'h10;
    localparam [31:0] DFLAGS_KEYED_LEAF =
        DFLAG_CHUNK_START | DFLAG_CHUNK_END | DFLAG_ROOT | DFLAG_KEYED_HASH;

    // -------------------------------------------------------------------------
    // Wire-protocol timing constants (matched to top_pipe_counter)
    // -------------------------------------------------------------------------
    parameter integer RX_SYNC_THRESHOLD_TICKS = 3;   // ≥3 wire_ticks LOW = sync
    parameter integer TX_SYNC_LENGTH_TICKS    = 4;   // FPGA sync = 4 wire_ticks LOW

    // -------------------------------------------------------------------------
    // FSM state encoding.
    //
    // Half-duplex contention-free design: FPGA tristates by default after
    // ceremony, so the bridge can drive sync + challenge freely. FPGA only
    // takes the wire after BLAKE3 finishes, to drive the response. Then it
    // returns to LISTEN. No idle heartbeat — the wire's pulldown holds it
    // LOW while both sides are tristate.
    // -------------------------------------------------------------------------
    localparam [3:0]
        ST_PRE_HEALTHY = 4'd0,   // wait for chip_healthy assertion
        ST_LISTEN_HI   = 4'd1,   // tristate; wait for bridge to drive HIGH (any activity)
        ST_LISTEN_LOW  = 4'd2,   // saw HIGH; now count LOW ticks for sync detect
        ST_RX_SUB0     = 4'd3,   // sub-phase 0 of a bit (bridge drives HIGH)
        ST_RX_SUB1     = 4'd4,   // sub-phase 1 — sample bit value
        ST_COMPUTE     = 4'd5,   // pulse BLAKE3, wait for o_valid
        ST_CAPTURE     = 4'd6,   // latch response, prepare TX
        ST_TX_SYNC     = 4'd7,   // drive LOW for TX_SYNC_LENGTH_TICKS wire_ticks
        ST_TX_LZ_HUNT  = 4'd8,   // Claim 12a: keep LOW until first 1 in response
        ST_TX_SUB0     = 4'd9,   // drive HIGH (sub-phase 0)
        ST_TX_SUB1     = 4'd10,  // drive response[bit_idx] (sub-phase 1)
        ST_TX_TRAIL    = 4'd11,  // Claim 12a trailing 1
        ST_RECOVER     = 4'd12;  // brief tristate before returning to LISTEN

    reg [3:0]   state;
    reg [3:0]   sync_low_cnt;           // how many wire_ticks the wire has been LOW
    reg [7:0]   bit_idx;                // 0..255, used for RX and TX
    reg [255:0] challenge_reg;
    reg [255:0] response_reg;
    reg [3:0]   tx_sync_cnt;            // counts down the TX sync LOW

    always @(*) fsm_state_debug = state;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state            <= ST_PRE_HEALTHY;
            wire_out         <= 1'b0;
            drive_en         <= 1'b0;          // tristate by default
            sync_low_cnt     <= 4'd0;
            bit_idx          <= 8'd0;
            challenge_reg    <= 256'b0;
            response_reg     <= 256'b0;
            tx_sync_cnt      <= 4'd0;
            blake3_start     <= 1'b0;
            blake3_chain     <= 256'b0;
            blake3_mblock    <= 512'b0;
            blake3_counter   <= 64'b0;
            blake3_numbytes  <= 32'd0;
            blake3_dflags    <= 32'd0;
        end else begin
            // Defaults
            blake3_start <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // ST_PRE_HEALTHY: wait for chip_healthy. ira_fsm meanwhile
                // runs ceremony (if needed). We stay tristate so we don't
                // fight whatever ira_fsm wants to do with diagnostic wire
                // signaling (currently it doesn't, but future ceremony FSMs
                // might use the wire for the wairua handshake).
                // -----------------------------------------------------------
                ST_PRE_HEALTHY: begin
                    drive_en <= 1'b0;
                    if (chip_healthy) begin
                        state        <= ST_LISTEN_HI;
                        sync_low_cnt <= 4'd0;
                    end
                end

                // -----------------------------------------------------------
                // ST_LISTEN_HI: wire is in idle (pulldown LOW or bridge
                // hasn't started yet). Wait for the bridge to drive HIGH —
                // the rising edge marks the beginning of activity. Until
                // then, the LOW pulldown reading should be ignored.
                // -----------------------------------------------------------
                ST_LISTEN_HI: begin
                    drive_en <= 1'b0;
                    if (wire_tick && wire_in_sync == 1'b1) begin
                        state        <= ST_LISTEN_LOW;
                        sync_low_cnt <= 4'd0;
                    end
                end

                // -----------------------------------------------------------
                // ST_LISTEN_LOW: bridge drove HIGH at least once. Now look
                // for a sustained LOW that means sync. The bridge's protocol
                // is: drive HIGH briefly (visibility), then sync (≥ N LOW),
                // then first sub-phase 0 (HIGH) of bit 0.
                // -----------------------------------------------------------
                ST_LISTEN_LOW: begin
                    drive_en <= 1'b0;
                    if (wire_tick) begin
                        if (wire_in_sync == 1'b0) begin
                            sync_low_cnt <= sync_low_cnt + 4'd1;
                        end else begin
                            // Just saw HIGH after some LOW ticks.
                            if (sync_low_cnt >= RX_SYNC_THRESHOLD_TICKS) begin
                                // Confirmed sync. This HIGH is bit 0's
                                // sub-phase 0; the next wire_tick is sub-phase 1.
                                bit_idx <= 8'd0;
                                state   <= ST_RX_SUB1;
                            end else begin
                                // Brief LOW, not sync. Reset and keep
                                // watching.
                                sync_low_cnt <= 4'd0;
                            end
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_RX_SUB0: sub-phase 0 of a bit (host drives HIGH). Just
                // wait one wire_tick.
                // -----------------------------------------------------------
                ST_RX_SUB0: begin
                    drive_en <= 1'b0;
                    if (wire_tick) state <= ST_RX_SUB1;
                end

                // -----------------------------------------------------------
                // ST_RX_SUB1: sample the wire for the bit value.
                // -----------------------------------------------------------
                ST_RX_SUB1: begin
                    drive_en <= 1'b0;
                    if (wire_tick) begin
                        challenge_reg[bit_idx] <= wire_in_sync;
                        if (bit_idx == 8'd255) begin
                            state <= ST_COMPUTE;
                        end else begin
                            bit_idx <= bit_idx + 8'd1;
                            state   <= ST_RX_SUB0;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_COMPUTE: pulse BLAKE3 with keyed-hash inputs.
                // BLAKE3 takes 30 enclave_clk cycles ≈ 10 µs — finishes way
                // before any wire timing matters.
                // -----------------------------------------------------------
                ST_COMPUTE: begin
                    drive_en        <= 1'b0;
                    blake3_chain    <= ira_value;
                    blake3_mblock   <= {256'b0, challenge_reg};
                    blake3_counter  <= 64'd0;
                    blake3_numbytes <= 32'd32;
                    blake3_dflags   <= DFLAGS_KEYED_LEAF;
                    blake3_start    <= 1'b1;
                    state           <= ST_CAPTURE;
                end

                // -----------------------------------------------------------
                // ST_CAPTURE: wait for blake3_valid, latch response.
                // -----------------------------------------------------------
                ST_CAPTURE: begin
                    drive_en <= 1'b0;
                    if (blake3_valid) begin
                        response_reg  <= blake3_hash[255:0];
                        // Prepare to transmit sync + response
                        drive_en      <= 1'b1;
                        wire_out      <= 1'b0;
                        tx_sync_cnt   <= TX_SYNC_LENGTH_TICKS[3:0];
                        bit_idx       <= 8'd255;        // MSB-first transmit
                        state         <= ST_TX_SYNC;
                    end
                end

                // -----------------------------------------------------------
                // ST_TX_SYNC: drive LOW for TX_SYNC_LENGTH_TICKS wire_ticks.
                // After sync, enter Claim 12a leading-zero hunt: keep LOW
                // until we encounter response[bit_idx] == 1.
                // -----------------------------------------------------------
                ST_TX_SYNC: begin
                    drive_en <= 1'b1;
                    wire_out <= 1'b0;
                    if (wire_tick) begin
                        if (tx_sync_cnt == 4'd1) begin
                            state <= ST_TX_LZ_HUNT;
                        end else begin
                            tx_sync_cnt <= tx_sync_cnt - 4'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_TX_LZ_HUNT (Claim 12a leading-zero suppression):
                // While response[bit_idx] == 0, keep driving LOW (the sync
                // extends naturally). On the first 1 bit, enter ST_TX_SUB0.
                // -----------------------------------------------------------
                ST_TX_LZ_HUNT: begin
                    drive_en <= 1'b1;
                    wire_out <= 1'b0;
                    if (wire_tick) begin
                        if (response_reg[bit_idx] == 1'b1) begin
                            // Found the first 1 — start data transmission
                            // with the standard sub-phase pattern.
                            state         <= ST_TX_SUB0;
                        end else if (bit_idx == 8'd0) begin
                            // All-zero response (negligible probability for a
                            // cryptographic hash but handled defensively).
                            // Skip data, go straight to trailing 1.
                            state <= ST_TX_TRAIL;
                        end else begin
                            bit_idx <= bit_idx - 8'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_TX_SUB0: drive HIGH (sub-phase 0 placeholder).
                // -----------------------------------------------------------
                ST_TX_SUB0: begin
                    drive_en <= 1'b1;
                    wire_out <= 1'b1;
                    if (wire_tick) state <= ST_TX_SUB1;
                end

                // -----------------------------------------------------------
                // ST_TX_SUB1: drive the bit value. Advance bit_idx; on
                // bit_idx == 0 we've sent the last (LSB) bit, move to trail.
                // -----------------------------------------------------------
                ST_TX_SUB1: begin
                    drive_en <= 1'b1;
                    wire_out <= response_reg[bit_idx];
                    if (wire_tick) begin
                        if (bit_idx == 8'd0) begin
                            state <= ST_TX_TRAIL;
                        end else begin
                            bit_idx <= bit_idx - 8'd1;
                            state   <= ST_TX_SUB0;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_TX_TRAIL: drive 1 wire_tick of HIGH (Claim 12a trailing
                // marker). Then return to idle.
                // -----------------------------------------------------------
                ST_TX_TRAIL: begin
                    drive_en <= 1'b1;
                    wire_out <= 1'b1;
                    if (wire_tick) state <= ST_RECOVER;
                end

                // -----------------------------------------------------------
                // ST_RECOVER: brief tristate pause before re-arming RX.
                // -----------------------------------------------------------
                ST_RECOVER: begin
                    drive_en <= 1'b0;
                    if (wire_tick) begin
                        sync_low_cnt <= 4'd0;
                        state        <= ST_LISTEN_HI;
                    end
                end

                default: state <= ST_LISTEN_HI;
            endcase
        end
    end

endmodule

`default_nettype wire
