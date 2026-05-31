// =============================================================================
// l3_session_fsm.v — PROTOCOL.md Layer 3: session + Message-B exchange
// =============================================================================
//
// Implements the full PROTOCOL.md L3 protocol with health queries (Claim 9c).
// Replaces chal_resp_fsm.v with the patent-aligned protocol.
//
// PROTOCOL FLOW (per PROTOCOL.md):
//
//   FRESH SESSION (Message A):
//     host emits `1, 0, 0, ..., 0` (256 bits)
//     enclave:
//       session_secret = wairua  ← KOHI → BLAKE3-conditioner output
//       H_req  = BLAKE3(wairua)
//       H_resp = BLAKE3(~wairua)
//     enclave emits 256 bits of wairua on its data stream so host syncs
//
//   AUTHENTICATED EXCHANGE (Message B), 512 bits each direction:
//     host →   X1 = message_req XOR H_req
//              X2 = BLAKE3(message_req) XOR H_resp        (SESSION)
//                   ~BLAKE3(message_req) XOR H_resp       (PERMANENT)
//     enclave  recover message_req = X1 XOR H_req
//              try both X2 invariants → matched form determines mode
//              active_key = wairua (SESSION) | ira (PERMANENT)
//              [query check (Claim 9c):]
//                if message_req == BLAKE3("Kei te ora koe?") = c0a6cabf...
//                  → numbytes = 64, mblock high half = state vector
//                else → numbytes = 32, mblock high half = 0
//              message_resp = BLAKE3.keyed(active_key, mblock @ numbytes)
//     enclave → X1' = message_resp XOR H_req
//              X2' = BLAKE3(message_resp) XOR H_resp        (SESSION echo)
//                    ~BLAKE3(message_resp) XOR H_resp       (PERMANENT echo)
//     both    ratchet: H_req ← BLAKE3(message_req), H_resp ← BLAKE3(message_resp)
//
//   ON CORRUPTION (no X2 invariant matched): silently drop exchange.
//     Do NOT advance pads; host will desync on next exchange and issue
//     fresh-session → both sides re-sync.
//
// STATE COMPOSITION FOR Q/HEALTH (Claim 9c, "clever" embodiment):
//
//   When message_req == Q_HEALTH_IDENT, the chip composes the BLAKE3 input
//   as a single 64-byte block:
//
//     mblock[255:0]   = message_req                (32 bytes)
//     mblock[511:256] = state_block                (32 bytes, packed below)
//     numbytes        = 64
//
//   This is still one BLAKE3 compression — q/health responses are no slower
//   than content commitments. The host verifies by computing the same hash
//   over the same 64 bytes, in the same byte order.
//
//   state_block layout (LSB at bit 256, MSB at bit 511; reserved bits zero):
//     [258:256] chip_state           (3 bits)
//     [274:259] ring_health_mask     (16 bits)
//     [279:275] ring_health_cnt      (5 bits)
//     [287:280] slot_burned_mask     (8 bits)
//     [290:288] fsm_state            (3 bits)
//     [354:291] session_counter      (64 bits)   ← Message B exchanges this session
//     [418:355] boot_epoch           (64 bits)   ← enclave_clk count since POR
//     [482:419] drop_counter         (64 bits)   ← DROP events (lifetime)
//     [511:483] reserved zero        (29 bits)
//
//   All counters are 64-bit per user instruction (chain-state visibility +
//   integrity even during health-check responses). The state block still
//   has 29 bits of headroom for future additions.
//
// =============================================================================

`timescale 1ns / 1ps

module l3_session_fsm (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         chip_alive,        // chip_state >= DEGRADED-2; gates operation

    // -------------------------------------------------------------------------
    // L2 codec interface (slot-clocked bit stream)
    // -------------------------------------------------------------------------
    input  wire         rx_valid,          // host slot pulse, rx_data is decoded host bit
    input  wire         rx_data,
    input  wire         tx_slot,           // 1-cycle pulse: enclave's slot is now
    output reg          tx_data,           // bit to emit this enclave slot
    output reg          tx_active,         // 1 while emitting message bits; else idle

    // -------------------------------------------------------------------------
    // Shared BLAKE3 compression core
    // -------------------------------------------------------------------------
    output reg  [255:0] b3_chain,
    output reg  [511:0] b3_mblock,
    output reg  [31:0]  b3_numbytes,
    output reg  [31:0]  b3_dflags,
    output reg          b3_valid,
    input  wire [511:0] b3_hash,
    input  wire         b3_done,

    // -------------------------------------------------------------------------
    // IRA (recovered from OTP by inverted_pair_verify)
    // -------------------------------------------------------------------------
    input  wire [255:0] ira_value,

    // -------------------------------------------------------------------------
    // Wairua-generation pipeline (shared with ira_fsm via top-level mux)
    // -------------------------------------------------------------------------
    output reg          trng_start,
    input  wire         trng_gather_done,
    input  wire         trng_health_fail,
    output reg          wairua_gen_start,
    input  wire [255:0] wairua_gen_result,
    input  wire         wairua_gen_valid,

    // -------------------------------------------------------------------------
    // Internal-state vector inputs for q/health composition
    // -------------------------------------------------------------------------
    input  wire [2:0]   chip_state_in,
    input  wire [15:0]  ring_health_mask_in,
    input  wire [4:0]   ring_health_cnt_in,
    input  wire [7:0]   slot_burned_mask_in,
    input  wire [2:0]   fsm_state_in,

    // -------------------------------------------------------------------------
    // OLED + debug observability (NOT exposed on the wire)
    //   wairua_disp     — current wairua hex (mode 4)
    //   session_counter — Message B exchanges this session (64 bits; OLED shows low 32)
    //   boot_epoch      — enclave_clk cycles since POR (64 bits; OLED shows low 32)
    //   drop_counter    — DROP events lifetime (64 bits; OLED shows low 32)
    //   h_req_finger    — first 32 bits of current H_req (chain-state fingerprint)
    //   h_resp_finger   — first 32 bits of current H_resp
    //   last_mode_perm  — 1 if last successful exchange was PERMANENT, 0 if SESSION
    //   last_was_query  — 1 if last successful exchange matched Q_HEALTH_IDENT
    //   session_valid_o — 1 if pads are derived and ready for Message B
    //   fsm_state_debug — current FSM state (one of ST_*)
    // -------------------------------------------------------------------------
    output reg  [255:0] wairua_disp,
    output reg  [63:0]  session_counter,
    output reg  [63:0]  boot_epoch,
    output reg  [63:0]  drop_counter,
    output wire [31:0]  h_req_finger,
    output wire [31:0]  h_resp_finger,
    output reg          last_mode_perm,
    output reg          last_was_query,
    output wire         session_valid_o,
    output reg  [4:0]   fsm_state_debug
);

    assign h_req_finger    = h_req[255:224];   // top 32 bits as fingerprint
    assign h_resp_finger   = h_resp[255:224];
    assign session_valid_o = session_valid;

    // =========================================================================
    // BLAKE3 constants
    // =========================================================================
    localparam [255:0] BLAKE3_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };
    localparam [31:0] FLG_PLAIN_LEAF  = 32'h0B;   // CHUNK_START|END|ROOT
    localparam [31:0] FLG_KEYED_LEAF  = 32'h1B;   // | KEYED_HASH

    // BLAKE3("Kei te ora koe?") — verified across blake3-py, b3sum CLI, and
    // BLAKE3 official test vectors. See patent/claims.md Claim 9c.
    localparam [255:0] Q_HEALTH_IDENT = {
        32'hc0a6cabf, 32'h9f69f2af, 32'hf78b5115, 32'h1e9300cd,
        32'h5bd32dfb, 32'hbecf5506, 32'h00625478, 32'hffee8e80
    };

    // Fresh-session detection pattern (1 followed by 255 zeros, MSB first).
    localparam [255:0] MSG_A_PATTERN = {1'b1, 255'b0};

    // =========================================================================
    // Session state (PROTOCOL.md L3)
    // =========================================================================
    reg [255:0] wairua_reg;
    reg [255:0] h_req;
    reg [255:0] h_resp;
    reg         session_valid;            // 1 = wairua + pads derived

    // =========================================================================
    // Per-exchange working registers
    // =========================================================================
    reg [255:0] rx_buf1;                  // Message A or X1 of Message B
    reg [255:0] rx_buf2;                  // X2 of Message B
    reg [255:0] message_req_reg;
    reg [255:0] message_resp_reg;
    reg [255:0] tx_buf1;                  // X1' = message_resp XOR H_req
    reg [255:0] tx_buf2;                  // X2' = BLAKE3(message_resp) XOR H_resp (mode-mirrored)
    reg [255:0] resp_hash_reg;            // BLAKE3(message_resp), saved for X2' compose + ratchet
    reg [255:0] req_hash_reg;             // BLAKE3(message_req), saved for ratchet
    reg         mode_permanent;           // 0 = SESSION, 1 = PERMANENT
    reg         is_query;
    reg [8:0]   rx_bit_cnt;
    reg [9:0]   tx_bit_cnt;
    reg [8:0]   fs_tx_cnt;                // counter for fresh-session emit of wairua

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [4:0]
        ST_IDLE         = 5'd0,
        ST_RX_BUF1      = 5'd1,
        ST_DECIDE       = 5'd2,
        ST_FS_KOHI      = 5'd3,
        ST_FS_COND      = 5'd4,
        ST_FS_HREQ_REQ  = 5'd5,    // issue BLAKE3(wairua)
        ST_FS_HREQ_WAIT = 5'd6,    // wait for done, capture into h_req
        ST_FS_HRESP_REQ = 5'd7,
        ST_FS_HRESP_WAIT= 5'd8,
        ST_FS_EMIT      = 5'd9,
        ST_RX_BUF2      = 5'd10,
        ST_MODE_REQ     = 5'd11,   // issue BLAKE3(message_req) for mode detect
        ST_MODE_WAIT    = 5'd12,   // wait + capture; check both invariants
        ST_RESP_REQ     = 5'd13,   // issue BLAKE3.keyed(active_key, mblock)
        ST_RESP_WAIT    = 5'd14,
        ST_RESPH_REQ    = 5'd15,   // issue BLAKE3(message_resp) for X2'
        ST_RESPH_WAIT   = 5'd16,
        ST_TX_EMIT      = 5'd17,   // emit 512 enclave bits
        ST_RATCHET_QREQ = 5'd18,   // issue BLAKE3(message_req) for new H_req
        ST_RATCHET_QWAIT= 5'd19,
        ST_RATCHET_PREQ = 5'd20,   // issue BLAKE3(message_resp) for new H_resp
        ST_RATCHET_PWAIT= 5'd21,
        ST_DROP         = 5'd22;

    reg [4:0] state;
    always @* fsm_state_debug = state;

    // =========================================================================
    // Derived combinationals
    // =========================================================================
    wire is_msg_a    = (rx_buf1 == MSG_A_PATTERN);

    // State block for q/health (Claim 9c clever embodiment).
    // 32 bytes packed into the high half of the BLAKE3 mblock, low-to-high
    // bit ordering as documented at top of file. All counters 64-bit for
    // chain-state visibility and integrity even during health-check
    // responses — host verifier can reconstruct exactly.
    wire [255:0] state_block = {
        29'b0,                  // [255:227] reserved zero
        drop_counter,           // [226:163] DROP events lifetime
        boot_epoch,             // [162:99]  enclave_clk cycles since POR
        session_counter,        // [98:35]   Message B exchanges this session
        fsm_state_in,           // [34:32]   fsm_state (3 bits)
        slot_burned_mask_in,    // [31:24]   slot_burned_mask (8 bits)
        ring_health_cnt_in,     // [23:19]   ring_health_cnt (5 bits)
        ring_health_mask_in,    // [18:3]    ring_health_mask (16 bits)
        chip_state_in           // [2:0]     chip_state (3 bits)
    };

    // Active-key selector based on detected mode.
    wire [255:0] active_key = mode_permanent ? ira_value : wairua_reg;

    // Test-and-capture wires for the two X2 invariants.
    wire [255:0] expected_x2_session    = b3_hash[255:0] ^ h_resp;
    wire [255:0] expected_x2_permanent  = (~b3_hash[255:0]) ^ h_resp;
    wire         x2_match_session       = (expected_x2_session   == rx_buf2);
    wire         x2_match_permanent     = (expected_x2_permanent == rx_buf2);

    // =========================================================================
    // Main always block
    // =========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state             <= ST_IDLE;
            wairua_reg        <= 256'b0;
            h_req             <= 256'b0;
            h_resp            <= 256'b0;
            session_valid     <= 1'b0;
            rx_buf1           <= 256'b0;
            rx_buf2           <= 256'b0;
            message_req_reg   <= 256'b0;
            message_resp_reg  <= 256'b0;
            tx_buf1           <= 256'b0;
            tx_buf2           <= 256'b0;
            resp_hash_reg     <= 256'b0;
            req_hash_reg      <= 256'b0;
            mode_permanent    <= 1'b0;
            is_query          <= 1'b0;
            rx_bit_cnt        <= 9'b0;
            tx_bit_cnt        <= 10'b0;
            fs_tx_cnt         <= 9'b0;
            tx_data           <= 1'b0;
            tx_active         <= 1'b0;
            b3_valid          <= 1'b0;
            b3_chain          <= 256'b0;
            b3_mblock         <= 512'b0;
            b3_numbytes       <= 32'b0;
            b3_dflags         <= 32'b0;
            trng_start        <= 1'b0;
            wairua_gen_start  <= 1'b0;
            wairua_disp       <= 256'b0;
            session_counter   <= 64'b0;
            boot_epoch        <= 64'b0;
            drop_counter      <= 64'b0;
            last_mode_perm    <= 1'b0;
            last_was_query    <= 1'b0;
        end else begin
            // Default one-cycle strobes
            b3_valid           <= 1'b0;
            trng_start         <= 1'b0;
            wairua_gen_start   <= 1'b0;

            // Free-running enclave_clk counter for time-since-POR.
            // 64 bits at 25 MHz = ~23,000 years; will never wrap in practice.
            boot_epoch <= boot_epoch + 64'd1;

            case (state)

                // -----------------------------------------------------------
                // IDLE — wait for chip_alive, then watch host stream for first 1 bit.
                // -----------------------------------------------------------
                ST_IDLE: begin
                    tx_data   <= 1'b0;
                    tx_active <= 1'b0;
                    if (chip_alive && rx_valid && rx_data) begin
                        // Got the first 1 — start buffering 256 bits.
                        rx_buf1     <= {255'b0, 1'b1};   // MSB shift convention: this is bit 255 of message
                        rx_bit_cnt  <= 9'd1;
                        state       <= ST_RX_BUF1;
                    end
                end

                // -----------------------------------------------------------
                // RX_BUF1 — shift in 256 host bits MSB-first.
                // -----------------------------------------------------------
                ST_RX_BUF1: begin
                    if (rx_valid) begin
                        rx_buf1    <= {rx_buf1[254:0], rx_data};
                        rx_bit_cnt <= rx_bit_cnt + 9'd1;
                        if (rx_bit_cnt == 9'd255) begin
                            state <= ST_DECIDE;
                        end
                    end
                end

                // -----------------------------------------------------------
                // DECIDE — Message A or start of Message B.
                // -----------------------------------------------------------
                ST_DECIDE: begin
                    if (is_msg_a) begin
                        // Fresh-session. Begin KOHI for wairua.
                        trng_start <= 1'b1;
                        state      <= ST_FS_KOHI;
                    end else begin
                        // rx_buf1 holds X1 of Message B. Buffer 256 more for X2.
                        rx_bit_cnt <= 9'b0;
                        state      <= ST_RX_BUF2;
                    end
                end

                // -----------------------------------------------------------
                // FS_KOHI — wait TRNG gather done; fire conditioner.
                // -----------------------------------------------------------
                ST_FS_KOHI: begin
                    if (trng_health_fail) begin
                        // Entropy source dead → silent-wire per Claim 9a.
                        // Don't actually drive silence here (that's top-level),
                        // just drop and stop trying.
                        state <= ST_DROP;
                    end else if (trng_gather_done) begin
                        wairua_gen_start <= 1'b1;
                        state            <= ST_FS_COND;
                    end
                end

                // -----------------------------------------------------------
                // FS_COND — wait conditioner; capture wairua.
                // -----------------------------------------------------------
                ST_FS_COND: begin
                    if (wairua_gen_valid) begin
                        wairua_reg  <= wairua_gen_result;
                        wairua_disp <= wairua_gen_result;
                        state       <= ST_FS_HREQ_REQ;
                    end
                end

                // -----------------------------------------------------------
                // FS_HREQ_REQ — issue BLAKE3(wairua).
                // -----------------------------------------------------------
                ST_FS_HREQ_REQ: begin
                    b3_chain    <= BLAKE3_IV;
                    b3_mblock   <= {256'b0, wairua_reg};
                    b3_numbytes <= 32'd32;
                    b3_dflags   <= FLG_PLAIN_LEAF;
                    b3_valid    <= 1'b1;
                    state       <= ST_FS_HREQ_WAIT;
                end

                ST_FS_HREQ_WAIT: begin
                    if (b3_done) begin
                        h_req <= b3_hash[255:0];
                        state <= ST_FS_HRESP_REQ;
                    end
                end

                ST_FS_HRESP_REQ: begin
                    b3_chain    <= BLAKE3_IV;
                    b3_mblock   <= {256'b0, ~wairua_reg};
                    b3_numbytes <= 32'd32;
                    b3_dflags   <= FLG_PLAIN_LEAF;
                    b3_valid    <= 1'b1;
                    state       <= ST_FS_HRESP_WAIT;
                end

                ST_FS_HRESP_WAIT: begin
                    if (b3_done) begin
                        h_resp        <= b3_hash[255:0];
                        session_valid <= 1'b1;
                        fs_tx_cnt     <= 9'b0;
                        state         <= ST_FS_EMIT;
                    end
                end

                // -----------------------------------------------------------
                // FS_EMIT — push wairua onto enclave data stream, MSB first.
                // -----------------------------------------------------------
                ST_FS_EMIT: begin
                    tx_active <= 1'b1;
                    if (tx_slot) begin
                        // emit MSB of wairua_reg shifted left by fs_tx_cnt
                        tx_data   <= wairua_reg[255 - fs_tx_cnt];
                        fs_tx_cnt <= fs_tx_cnt + 9'd1;
                        if (fs_tx_cnt == 9'd255) begin
                            // Last bit emitted; back to IDLE.
                            tx_active <= 1'b0;
                            state     <= ST_IDLE;
                        end
                    end
                end

                // -----------------------------------------------------------
                // RX_BUF2 — buffer 256 more host bits → X2.
                // -----------------------------------------------------------
                ST_RX_BUF2: begin
                    if (rx_valid) begin
                        rx_buf2    <= {rx_buf2[254:0], rx_data};
                        rx_bit_cnt <= rx_bit_cnt + 9'd1;
                        if (rx_bit_cnt == 9'd255) begin
                            if (!session_valid) begin
                                // Got Message B before fresh-session; protocol
                                // violation, drop.
                                state <= ST_DROP;
                            end else begin
                                // Decode message_req combinationally; issue
                                // BLAKE3(message_req) for mode detect.
                                message_req_reg <= rx_buf1 ^ h_req;
                                state           <= ST_MODE_REQ;
                            end
                        end
                    end
                end

                // -----------------------------------------------------------
                // MODE_REQ — issue BLAKE3(message_req).
                // -----------------------------------------------------------
                ST_MODE_REQ: begin
                    b3_chain    <= BLAKE3_IV;
                    b3_mblock   <= {256'b0, message_req_reg};
                    b3_numbytes <= 32'd32;
                    b3_dflags   <= FLG_PLAIN_LEAF;
                    b3_valid    <= 1'b1;
                    state       <= ST_MODE_WAIT;
                end

                // -----------------------------------------------------------
                // MODE_WAIT — detect mode; save BLAKE3(message_req) for ratchet later.
                // -----------------------------------------------------------
                ST_MODE_WAIT: begin
                    if (b3_done) begin
                        req_hash_reg <= b3_hash[255:0]; // save for ratchet
                        if (x2_match_session) begin
                            mode_permanent <= 1'b0;
                            is_query       <= (message_req_reg == Q_HEALTH_IDENT);
                            state          <= ST_RESP_REQ;
                        end else if (x2_match_permanent) begin
                            mode_permanent <= 1'b1;
                            is_query       <= (message_req_reg == Q_HEALTH_IDENT);
                            state          <= ST_RESP_REQ;
                        end else begin
                            state <= ST_DROP;
                        end
                    end
                end

                // -----------------------------------------------------------
                // RESP_REQ — issue BLAKE3.keyed(active_key, mblock) for response.
                //   For content commitment: numbytes=32, mblock high half = 0.
                //   For q/health query:     numbytes=64, mblock high half = state_block.
                // -----------------------------------------------------------
                ST_RESP_REQ: begin
                    b3_chain  <= active_key;
                    if (is_query) begin
                        b3_mblock   <= {state_block, message_req_reg};
                        b3_numbytes <= 32'd64;
                    end else begin
                        b3_mblock   <= {256'b0, message_req_reg};
                        b3_numbytes <= 32'd32;
                    end
                    b3_dflags <= FLG_KEYED_LEAF;
                    b3_valid  <= 1'b1;
                    state     <= ST_RESP_WAIT;
                end

                ST_RESP_WAIT: begin
                    if (b3_done) begin
                        message_resp_reg <= b3_hash[255:0];
                        // Pre-compute tx_buf1 now; tx_buf2 fills after next hash.
                        tx_buf1 <= b3_hash[255:0] ^ h_req;
                        state   <= ST_RESPH_REQ;
                    end
                end

                // -----------------------------------------------------------
                // RESPH_REQ — issue BLAKE3(message_resp) for X2' construction.
                // -----------------------------------------------------------
                ST_RESPH_REQ: begin
                    b3_chain    <= BLAKE3_IV;
                    b3_mblock   <= {256'b0, message_resp_reg};
                    b3_numbytes <= 32'd32;
                    b3_dflags   <= FLG_PLAIN_LEAF;
                    b3_valid    <= 1'b1;
                    state       <= ST_RESPH_WAIT;
                end

                ST_RESPH_WAIT: begin
                    if (b3_done) begin
                        resp_hash_reg <= b3_hash[255:0]; // save for ratchet
                        tx_buf2 <= mode_permanent ? ((~b3_hash[255:0]) ^ h_resp)
                                                  : (  b3_hash[255:0]  ^ h_resp);
                        tx_bit_cnt <= 10'b0;
                        state      <= ST_TX_EMIT;
                    end
                end

                // -----------------------------------------------------------
                // TX_EMIT — emit 512 enclave bits: tx_buf1 (MSB first) then tx_buf2.
                // -----------------------------------------------------------
                ST_TX_EMIT: begin
                    tx_active <= 1'b1;
                    if (tx_slot) begin
                        if (tx_bit_cnt < 10'd256) begin
                            tx_data <= tx_buf1[255 - tx_bit_cnt[7:0]];
                        end else begin
                            tx_data <= tx_buf2[255 - (tx_bit_cnt[7:0])];
                        end
                        tx_bit_cnt <= tx_bit_cnt + 10'd1;
                        if (tx_bit_cnt == 10'd511) begin
                            tx_active <= 1'b0;
                            state     <= ST_RATCHET_QREQ;
                        end
                    end
                end

                // -----------------------------------------------------------
                // Ratchet: H_req ← BLAKE3(message_req) [already saved in req_hash_reg]
                //          H_resp ← BLAKE3(message_resp) [already saved in resp_hash_reg]
                // We can just commit these immediately, no new BLAKE3 needed.
                // -----------------------------------------------------------
                ST_RATCHET_QREQ: begin
                    h_req <= req_hash_reg;
                    state <= ST_RATCHET_PREQ;
                end

                ST_RATCHET_QWAIT: begin
                    // unused — kept reserved for symmetry / future use
                    state <= ST_RATCHET_PREQ;
                end

                ST_RATCHET_PREQ: begin
                    h_resp          <= resp_hash_reg;
                    session_counter <= session_counter + 64'd1;
                    last_mode_perm  <= mode_permanent;
                    last_was_query  <= is_query;
                    state           <= ST_IDLE;
                end

                ST_RATCHET_PWAIT: begin
                    // unused — kept reserved for symmetry / future use
                    state <= ST_IDLE;
                end

                // -----------------------------------------------------------
                // DROP — corruption detected: clear working regs, do NOT
                // ratchet, return to IDLE. Host will desync next exchange and
                // issue fresh-session.
                // -----------------------------------------------------------
                ST_DROP: begin
                    rx_buf1            <= 256'b0;
                    rx_buf2            <= 256'b0;
                    message_req_reg    <= 256'b0;
                    message_resp_reg   <= 256'b0;
                    tx_buf1            <= 256'b0;
                    tx_buf2            <= 256'b0;
                    rx_bit_cnt         <= 9'b0;
                    tx_bit_cnt         <= 10'b0;
                    drop_counter       <= drop_counter + 64'd1;
                    state              <= ST_IDLE;
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
