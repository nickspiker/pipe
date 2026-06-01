// =============================================================================
// l3_session_fsm_tb.v — self-contained iverilog testbench for L3 session FSM
// =============================================================================
//
// Validates PROTOCOL.md Layer 3 (Message A fresh-session, Message B
// authenticated exchange, q/health Claim 9c, single-bit fault detection).
//
// Architecture:
//   - DUT: l3_session_fsm + real blake3 core wired to its b3_* ports
//   - Host model: second blake3 core used by the testbench to compute
//     reference hashes (no precomputed vectors needed)
//   - Stubbed wairua-gen pipeline (trng_gather_done + wairua_gen_valid pulse)
//   - Manual slot driver: send_host_bit() pulses rx_valid; recv_enclave_bit()
//     pulses tx_slot and samples tx_data
//
// Tests (all run sequentially in one initial block, each prints PASS or FAIL):
//   1. Reset state
//   2. Fresh-session happy path (KOHI → COND → HREQ → HRESP → EMIT, pads OK)
//   3. First MOTUHAKE PERMANENT exchange
//   4. Second MOTUHAKE PERMANENT exchange (determinism, different pads)
//   5. First MOTUHAKE SESSION exchange
//   6. Q_HEALTH PERMANENT (Claim 9c state vector)
//   7. Single-bit fault in X1 → DROP
//   8. Single-bit fault in X2 → DROP
//   9. Wrong-mode/inverse X2 (SESSION form after PERMANENT) — both branches
//
// =============================================================================

`timescale 1ns / 1ps

module l3_session_fsm_tb;

    // -------------------------------------------------------------------------
    // Constants matching DUT
    // -------------------------------------------------------------------------
    localparam [255:0] BLAKE3_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };
    localparam [31:0] FLG_PLAIN_LEAF = 32'h0B;
    localparam [31:0] FLG_KEYED_LEAF = 32'h1B;

    localparam [255:0] Q_HEALTH_IDENT = {
        32'hc0a6cabf, 32'h9f69f2af, 32'hf78b5115, 32'h1e9300cd,
        32'h5bd32dfb, 32'hbecf5506, 32'h00625478, 32'hffee8e80
    };

    // Stub fixed values
    localparam [255:0] WAIRUA_FIXED = {
        32'hA5A5A5A5, 32'hDEADBEEF, 32'hCAFEBABE, 32'h12345678,
        32'h9ABCDEF0, 32'h0FEDCBA9, 32'h87654321, 32'hFEEDFACE
    };
    localparam [255:0] IRA_FIXED = {
        32'h11111111, 32'h22222222, 32'h33333333, 32'h44444444,
        32'h55555555, 32'h66666666, 32'h77777777, 32'h88888888
    };

    // FSM state encodings (must match l3_session_fsm.v)
    localparam ST_IDLE          = 5'd0;
    localparam ST_DROP          = 5'd22;

    // -------------------------------------------------------------------------
    // Clock & reset
    // -------------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;  // 10 ns period (100 MHz)

    reg reset_n = 0;
    reg chip_alive = 0;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg         rx_valid_r = 0;
    reg         rx_data_r  = 0;
    reg         tx_slot_r  = 0;
    wire        tx_data_w;
    wire        tx_active_w;

    // DUT BLAKE3 port wires
    wire [255:0] dut_b3_chain;
    wire [511:0] dut_b3_mblock;
    wire [31:0]  dut_b3_numbytes;
    wire [31:0]  dut_b3_dflags;
    wire         dut_b3_valid;
    wire [511:0] dut_b3_hash;
    wire         dut_b3_done;

    // Stubbed wairua-gen
    wire        trng_start_w;
    reg         trng_gather_done_r = 0;
    reg         trng_health_fail_r = 0;
    wire        wairua_gen_start_w;
    reg  [255:0] wairua_gen_result_r = WAIRUA_FIXED;
    reg         wairua_gen_valid_r = 0;

    // Q/health state vector inputs
    reg [2:0]   chip_state_in_r       = 3'd0;
    reg [15:0]  ring_health_mask_in_r = 16'h0;
    reg [4:0]   ring_health_cnt_in_r  = 5'd0;
    reg [7:0]   slot_burned_mask_in_r = 8'h0;
    reg [2:0]   fsm_state_in_r        = 3'd0;

    // Outputs
    wire [255:0] wairua_disp_w;
    wire [63:0]  session_counter_w;
    wire [63:0]  boot_epoch_w;
    wire [63:0]  drop_counter_w;
    wire [31:0]  h_req_finger_w;
    wire [31:0]  h_resp_finger_w;
    wire         last_mode_perm_w;
    wire         last_was_query_w;
    wire         session_valid_o_w;
    wire [4:0]   fsm_state_debug_w;

    // -------------------------------------------------------------------------
    // DUT instance
    // -------------------------------------------------------------------------
    l3_session_fsm u_dut (
        .clk                 (clk),
        .reset_n             (reset_n),
        .chip_alive          (chip_alive),
        .rx_valid            (rx_valid_r),
        .rx_data             (rx_data_r),
        .tx_slot             (tx_slot_r),
        .tx_data             (tx_data_w),
        .tx_active           (tx_active_w),
        .b3_chain            (dut_b3_chain),
        .b3_mblock           (dut_b3_mblock),
        .b3_numbytes         (dut_b3_numbytes),
        .b3_dflags           (dut_b3_dflags),
        .b3_valid            (dut_b3_valid),
        .b3_hash             (dut_b3_hash),
        .b3_done             (dut_b3_done),
        .ira_value           (IRA_FIXED),
        .trng_start          (trng_start_w),
        .trng_gather_done    (trng_gather_done_r),
        .trng_health_fail    (trng_health_fail_r),
        .wairua_gen_start    (wairua_gen_start_w),
        .wairua_gen_result   (wairua_gen_result_r),
        .wairua_gen_valid    (wairua_gen_valid_r),
        .chip_state_in       (chip_state_in_r),
        .ring_health_mask_in (ring_health_mask_in_r),
        .ring_health_cnt_in  (ring_health_cnt_in_r),
        .slot_burned_mask_in (slot_burned_mask_in_r),
        .fsm_state_in        (fsm_state_in_r),
        .wairua_disp         (wairua_disp_w),
        .session_counter     (session_counter_w),
        .boot_epoch          (boot_epoch_w),
        .drop_counter        (drop_counter_w),
        .h_req_finger        (h_req_finger_w),
        .h_resp_finger       (h_resp_finger_w),
        .last_mode_perm      (last_mode_perm_w),
        .last_was_query      (last_was_query_w),
        .session_valid_o     (session_valid_o_w),
        .fsm_state_debug     (fsm_state_debug_w)
    );

    // -------------------------------------------------------------------------
    // DUT's BLAKE3 core
    // -------------------------------------------------------------------------
    blake3 u_b3_dut (
        .i_clk     (clk),
        .i_reset   (reset_n),
        .i_ce      (1'b1),
        .i_chain   (dut_b3_chain),
        .i_mblock  (dut_b3_mblock),
        .i_counter (64'd0),
        .i_numbytes(dut_b3_numbytes),
        .i_dflags  (dut_b3_dflags),
        .i_valid   (dut_b3_valid),
        .o_hash    (dut_b3_hash),
        .o_valid   (dut_b3_done)
    );

    // -------------------------------------------------------------------------
    // Host-model BLAKE3 core (used by testbench tasks for reference hashes)
    // -------------------------------------------------------------------------
    reg  [255:0] hm_chain    = 256'b0;
    reg  [511:0] hm_mblock   = 512'b0;
    reg  [31:0]  hm_numbytes = 32'b0;
    reg  [31:0]  hm_dflags   = 32'b0;
    reg          hm_valid    = 1'b0;
    wire [511:0] hm_hash;
    wire         hm_done;

    blake3 u_b3_host (
        .i_clk     (clk),
        .i_reset   (reset_n),
        .i_ce      (1'b1),
        .i_chain   (hm_chain),
        .i_mblock  (hm_mblock),
        .i_counter (64'd0),
        .i_numbytes(hm_numbytes),
        .i_dflags  (hm_dflags),
        .i_valid   (hm_valid),
        .o_hash    (hm_hash),
        .o_valid   (hm_done)
    );

    // -------------------------------------------------------------------------
    // Stub: wairua-gen pipeline
    //   On trng_start pulse → after N cycles assert trng_gather_done for 1 cyc.
    //   On wairua_gen_start pulse → after N cycles assert wairua_gen_valid.
    // -------------------------------------------------------------------------
    integer trng_ctr  = 0;
    integer wgen_ctr  = 0;
    reg     trng_pending = 0;
    reg     wgen_pending = 0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            trng_ctr <= 0;
            wgen_ctr <= 0;
            trng_pending <= 0;
            wgen_pending <= 0;
            trng_gather_done_r <= 0;
            wairua_gen_valid_r <= 0;
        end else begin
            trng_gather_done_r <= 0;
            wairua_gen_valid_r <= 0;

            if (trng_start_w) begin
                trng_pending <= 1;
                trng_ctr     <= 0;
            end else if (trng_pending) begin
                if (trng_ctr == 7) begin
                    trng_gather_done_r <= 1;
                    trng_pending <= 0;
                end else begin
                    trng_ctr <= trng_ctr + 1;
                end
            end

            if (wairua_gen_start_w) begin
                wgen_pending <= 1;
                wgen_ctr     <= 0;
            end else if (wgen_pending) begin
                if (wgen_ctr == 7) begin
                    wairua_gen_valid_r <= 1;
                    wgen_pending <= 0;
                end else begin
                    wgen_ctr <= wgen_ctr + 1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Test bookkeeping
    // -------------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    task report;
        input        ok;
        input [1023:0] name;
        begin
            total_tests = total_tests + 1;
            if (ok) begin
                pass_count = pass_count + 1;
                $display("[PASS] %0s", name);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", name);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Host-model blake3 task: compute BLAKE3(data) where data is 32 bytes,
    // returns 256-bit hash (low half of compression output).
    // -------------------------------------------------------------------------
    task hm_b3_plain32;
        input  [255:0] data;
        output [255:0] result;
        begin
            @(posedge clk);
            hm_chain    <= BLAKE3_IV;
            hm_mblock   <= {256'b0, data};
            hm_numbytes <= 32'd32;
            hm_dflags   <= FLG_PLAIN_LEAF;
            hm_valid    <= 1'b1;
            @(posedge clk);
            hm_valid <= 1'b0;
            // Wait for done (clear → set transition)
            // o_valid is 1 between transactions; goes 0 then back to 1.
            wait (hm_done == 1'b0);
            wait (hm_done == 1'b1);
            @(posedge clk);
            result = hm_hash[255:0];
        end
    endtask

    // BLAKE3 of arbitrary ASCII bytes packed into low [bytes*8-1:0], MSB-zero,
    // as a plain leaf with the given numbytes. Caller supplies the 512-bit
    // mblock already packed (little-endian byte order per BLAKE3 spec).
    task hm_b3_block;
        input  [255:0] chain;
        input  [511:0] mblock;
        input  [31:0]  numbytes;
        input  [31:0]  dflags;
        output [511:0] result512;
        begin
            @(posedge clk);
            hm_chain    <= chain;
            hm_mblock   <= mblock;
            hm_numbytes <= numbytes;
            hm_dflags   <= dflags;
            hm_valid    <= 1'b1;
            @(posedge clk);
            hm_valid <= 1'b0;
            wait (hm_done == 1'b0);
            wait (hm_done == 1'b1);
            @(posedge clk);
            result512 = hm_hash;
        end
    endtask

    // -------------------------------------------------------------------------
    // Slot drivers
    //
    // The L3 FSM consumes one host bit per rx_valid pulse and emits one
    // enclave bit per tx_slot pulse. We separate them — tasks pulse one or
    // the other for a single cycle each, with gap cycles for FSM internal
    // transitions (e.g., RX_BUF1→DECIDE→RX_BUF2 between X1 and X2).
    // -------------------------------------------------------------------------

    task send_host_bit;
        input bit_val;
        begin
            @(posedge clk);
            rx_valid_r <= 1'b1;
            rx_data_r  <= bit_val;
            @(posedge clk);
            rx_valid_r <= 1'b0;
            rx_data_r  <= 1'b0;
        end
    endtask

    // Pulse tx_slot for one cycle and sample tx_data.
    //
    // Timing: at posedge T (tx_slot=1 sampled), FSM schedules
    //   tx_data <= wairua_reg[255 - fs_tx_cnt]
    // So tx_data updates on the clock edge AT THE END of the slot we're
    // sampling. We need to wait one more posedge before reading tx_data
    // to capture the value driven for THIS slot.
    task recv_enclave_bit;
        output bit_val;
        begin
            @(posedge clk);
            tx_slot_r <= 1'b1;
            @(posedge clk);
            tx_slot_r <= 1'b0;
            // One more edge — now tx_data reflects the bit driven for the
            // slot whose tx_slot pulse was high.
            @(posedge clk);
            bit_val = tx_data_w;
        end
    endtask

    // Send a 256-bit value MSB-first as host bits.
    task send_256;
        input [255:0] v;
        integer i;
        begin
            for (i = 255; i >= 0; i = i - 1) begin
                send_host_bit(v[i]);
            end
        end
    endtask

    // Receive 256 enclave bits MSB-first.
    task recv_256;
        output [255:0] v;
        integer i;
        reg b;
        begin
            v = 256'b0;
            for (i = 255; i >= 0; i = i - 1) begin
                recv_enclave_bit(b);
                v[i] = b;
            end
        end
    endtask

    // Wait until FSM is in ST_IDLE.
    task wait_idle;
        integer timeout;
        begin
            timeout = 10000;
            while (fsm_state_debug_w !== ST_IDLE && timeout > 0) begin
                @(posedge clk);
                timeout = timeout - 1;
            end
            if (timeout == 0) begin
                $display("  ERROR: wait_idle timeout, state=%0d", fsm_state_debug_w);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Helpers for the host model
    // -------------------------------------------------------------------------

    // BLAKE3 of "motuhake" (8 ASCII bytes 6D 6F 74 75 68 61 6B 65 in little
    // endian byte order into mblock low 64 bits — BLAKE3 uses LE word loads
    // so byte 0 of the message lands at bit [7:0] of mblock).
    // Compute and return the 256-bit result.
    task compute_motuhake;
        output [255:0] result;
        reg [511:0] mblk;
        reg [511:0] h;
        begin
            mblk = 512'b0;
            // ASCII "motuhake" = 6D 6F 74 75 68 61 6B 65
            // Pack as little-endian: byte 0 ('m'=6D) at bits [7:0]
            mblk[ 7: 0] = 8'h6D; // 'm'
            mblk[15: 8] = 8'h6F; // 'o'
            mblk[23:16] = 8'h74; // 't'
            mblk[31:24] = 8'h75; // 'u'
            mblk[39:32] = 8'h68; // 'h'
            mblk[47:40] = 8'h61; // 'a'
            mblk[55:48] = 8'h6B; // 'k'
            mblk[63:56] = 8'h65; // 'e'
            hm_b3_block(BLAKE3_IV, mblk, 32'd8, FLG_PLAIN_LEAF, h);
            result = h[255:0];
        end
    endtask

    // BLAKE3.keyed(key, msg) where msg is 32 bytes packed in low half.
    task hm_b3_keyed32;
        input  [255:0] key;
        input  [255:0] msg;
        output [255:0] result;
        reg [511:0] h;
        begin
            hm_b3_block(key, {256'b0, msg}, 32'd32, FLG_KEYED_LEAF, h);
            result = h[255:0];
        end
    endtask

    // BLAKE3.keyed(key, mblock_64bytes) at numbytes=64 (full block).
    task hm_b3_keyed64;
        input  [255:0] key;
        input  [511:0] mblk;
        output [255:0] result;
        reg [511:0] h;
        begin
            hm_b3_block(key, mblk, 32'd64, FLG_KEYED_LEAF, h);
            result = h[255:0];
        end
    endtask

    // -------------------------------------------------------------------------
    // High-level helpers: emulate a host issuing fresh-session or Message-B.
    // -------------------------------------------------------------------------

    // Issue fresh-session: drive 1, then 255 zeros, then receive 256-bit
    // wairua echo. Returns the received wairua.
    task do_fresh_session;
        output [255:0] wairua_recv;
        integer i;
        integer to;
        reg b;
        begin
            // Wire format: leading frame-1, then 256 zero data bits.
            send_host_bit(1'b1);
            for (i = 0; i < 256; i = i + 1) send_host_bit(1'b0);
            // Bounded wait for FS_EMIT (tx_active high).
            to = 5000;
            while (tx_active_w !== 1'b1 && to > 0) begin
                @(posedge clk);
                to = to - 1;
            end
            if (tx_active_w !== 1'b1) begin
                $display("  ERROR: do_fresh_session: tx_active never asserted (state=%0d)",
                         fsm_state_debug_w);
                wairua_recv = 256'b0;
            end else begin
                // Consume the enclave's leading frame-1 marker.
                recv_enclave_bit(b);
                if (b !== 1'b1)
                    $display("  WARN: do_fresh_session: enclave frame bit = %b (expected 1)", b);
                wairua_recv = 256'b0;
                for (i = 255; i >= 0; i = i - 1) begin
                    recv_enclave_bit(b);
                    wairua_recv[i] = b;
                end
                wait_idle();
            end
        end
    endtask

    // Issue Message B: send 512 host bits (X1||X2), then receive 512 enclave bits.
    // Caller supplies X1 and X2; we return X1' and X2' captured from the wire.
    task do_message_b;
        input  [255:0] x1;
        input  [255:0] x2;
        output [255:0] x1_prime;
        output [255:0] x2_prime;
        integer i;
        integer to;
        reg b;
        begin
            // Wire format: leading frame-1, then 256 X1 + 256 X2 = 513 bits.
            send_host_bit(1'b1);
            send_256(x1);
            send_256(x2);
            // Bounded wait for tx_active.
            to = 5000;
            while (tx_active_w !== 1'b1 && to > 0) begin
                @(posedge clk);
                to = to - 1;
            end
            if (tx_active_w !== 1'b1) begin
                $display("  ERROR: do_message_b: tx_active never asserted (state=%0d, likely DROP)",
                         fsm_state_debug_w);
                x1_prime = 256'b0;
                x2_prime = 256'b0;
                wait_idle();
            end else begin
                // Consume enclave frame-1 marker.
                recv_enclave_bit(b);
                if (b !== 1'b1)
                    $display("  WARN: do_message_b: enclave frame bit = %b (expected 1)", b);
                x1_prime = 256'b0;
                for (i = 255; i >= 0; i = i - 1) begin
                    recv_enclave_bit(b);
                    x1_prime[i] = b;
                end
                x2_prime = 256'b0;
                for (i = 255; i >= 0; i = i - 1) begin
                    recv_enclave_bit(b);
                    x2_prime[i] = b;
                end
                wait_idle();
            end
        end
    endtask

    // Issue Message B and expect a DROP (no TX). Drive 512 host bits, then
    // give the FSM plenty of cycles to process — assert tx_active stays low
    // and FSM returns to IDLE via the DROP path.
    task do_message_b_expect_drop;
        input  [255:0] x1;
        input  [255:0] x2;
        output         saw_tx;     // 1 if tx_active ever went high (BAD)
        output         saw_drop;   // 1 if we observed ST_DROP transition
        integer timeout;
        begin
            saw_tx   = 0;
            saw_drop = 0;
            // Same 513-bit wire format as do_message_b: frame-1 + 256 + 256.
            send_host_bit(1'b1);
            send_256(x1);
            send_256(x2);
            // FSM will go MODE_REQ → MODE_WAIT (~30 cyc) → either RESP_REQ
            // (bad) or DROP (good). Watch for ~500 cycles.
            timeout = 500;
            while (timeout > 0) begin
                @(posedge clk);
                if (tx_active_w === 1'b1) saw_tx = 1;
                if (fsm_state_debug_w === ST_DROP) saw_drop = 1;
                if (fsm_state_debug_w === ST_IDLE && saw_drop) timeout = 0;
                else timeout = timeout - 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Test state captured between tests
    // -------------------------------------------------------------------------
    reg [255:0] wairua_recv;
    reg [255:0] h_req_initial, h_resp_initial;
    reg [255:0] h_req_after_msg1, h_resp_after_msg1;
    reg [255:0] h_req_after_msg2, h_resp_after_msg2;
    reg [255:0] motuhake_hash;
    reg [255:0] motuhake_msg;
    reg [255:0] expected_msg_resp_perm_1;
    reg [255:0] msg_resp_perm_1, msg_resp_perm_2, msg_resp_session;
    reg [255:0] x1_in, x2_in, x1_prime, x2_prime;
    reg [255:0] x2_inv_session, x2_inv_permanent;
    reg [255:0] recovered_resp, expected_x2_prime;
    reg         ok;
    reg         saw_tx, saw_drop;
    reg [63:0]  drop_count_before, drop_count_after;
    reg [63:0]  session_count_snap;

    // Track DROPs by sampling drop_counter.
    initial begin
        $display("");
        $display("============================================================");
        $display("  l3_session_fsm_tb — Layer 3 protocol validation");
        $display("============================================================");
        $display("");

        // Power-up + reset
        reset_n = 0;
        chip_alive = 0;
        repeat (10) @(posedge clk);
        reset_n = 1;
        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------------
        // Test 1: Reset state
        // ---------------------------------------------------------------------
        ok = (fsm_state_debug_w === ST_IDLE)
          && (session_valid_o_w === 1'b0)
          && (drop_counter_w === 64'd0)
          && (tx_active_w === 1'b0);
        report(ok, "Test 1: Reset state (ST_IDLE, !session_valid, drop=0, !tx_active)");
        if (!ok) begin
            $display("        state=%0d sv=%b drop=%0d tx_active=%b",
                     fsm_state_debug_w, session_valid_o_w, drop_counter_w, tx_active_w);
        end

        chip_alive = 1'b1;
        repeat (3) @(posedge clk);

        // ---------------------------------------------------------------------
        // Test 2: Fresh-session happy path
        // ---------------------------------------------------------------------
        do_fresh_session(wairua_recv);

        // Reference: H_req = BLAKE3(wairua), H_resp = BLAKE3(~wairua)
        hm_b3_plain32(WAIRUA_FIXED, h_req_initial);
        hm_b3_plain32(~WAIRUA_FIXED, h_resp_initial);

        ok = (wairua_recv === WAIRUA_FIXED)
          && (session_valid_o_w === 1'b1)
          && (fsm_state_debug_w === ST_IDLE)
          && (wairua_disp_w === WAIRUA_FIXED)
          && (h_req_finger_w === h_req_initial[255:224])
          && (h_resp_finger_w === h_resp_initial[255:224]);
        report(ok, "Test 2: Fresh-session happy path (wairua echoed, pads derived)");
        if (!ok) begin
            $display("        wairua_recv=%h", wairua_recv);
            $display("        WAIRUA_FIXED=%h", WAIRUA_FIXED);
            $display("        h_req_finger=%h expect=%h", h_req_finger_w, h_req_initial[255:224]);
            $display("        h_resp_finger=%h expect=%h", h_resp_finger_w, h_resp_initial[255:224]);
            $display("        session_valid=%b state=%0d", session_valid_o_w, fsm_state_debug_w);
        end

        // ---------------------------------------------------------------------
        // Compute MOTUHAKE identifier
        // ---------------------------------------------------------------------
        compute_motuhake(motuhake_hash);
        motuhake_msg = motuhake_hash;
        $display("        MOTUHAKE = %h", motuhake_hash);

        // ---------------------------------------------------------------------
        // Test 3: First MOTUHAKE PERMANENT exchange
        // ---------------------------------------------------------------------
        // Compute expected message_resp = BLAKE3.keyed(IRA, MOTUHAKE)
        hm_b3_keyed32(IRA_FIXED, motuhake_msg, expected_msg_resp_perm_1);

        // X1 = motuhake XOR H_req
        // X2 = ~BLAKE3(motuhake) XOR H_resp   (PERMANENT)
        x1_in = motuhake_msg ^ h_req_initial;
        // BLAKE3(motuhake_msg) — motuhake_msg is the 32-byte hash; we need
        // BLAKE3 of those 32 bytes (i.e. BLAKE3(BLAKE3("motuhake"))).
        // Actually per protocol: X2 = ~BLAKE3(message_req) XOR H_resp where
        // message_req IS motuhake_msg. So we hash motuhake_msg (32 bytes).
        begin : t3_x2
            reg [255:0] hmsg;
            hm_b3_plain32(motuhake_msg, hmsg);
            x2_in = (~hmsg) ^ h_resp_initial;
        end

        drop_count_before = drop_counter_w;
        do_message_b(x1_in, x2_in, x1_prime, x2_prime);

        // Recover message_resp = X1' XOR H_req (using OLD pads)
        recovered_resp = x1_prime ^ h_req_initial;

        // Compute expected X2': PERMANENT echo: ~BLAKE3(message_resp) XOR H_resp
        begin : t3_x2p
            reg [255:0] hresp;
            hm_b3_plain32(recovered_resp, hresp);
            expected_x2_prime = (~hresp) ^ h_resp_initial;
        end

        msg_resp_perm_1 = recovered_resp;

        ok = (recovered_resp === expected_msg_resp_perm_1)
          && (x2_prime === expected_x2_prime)
          && (last_mode_perm_w === 1'b1)
          && (last_was_query_w === 1'b0)
          && (session_counter_w === 64'd1)
          && (drop_counter_w === drop_count_before);
        report(ok, "Test 3: First MOTUHAKE PERMANENT exchange");
        if (!ok) begin
            $display("        recovered_resp = %h", recovered_resp);
            $display("        expected_resp  = %h", expected_msg_resp_perm_1);
            $display("        x2_prime       = %h", x2_prime);
            $display("        expected_x2p   = %h", expected_x2_prime);
            $display("        last_mode_perm = %b (expect 1)", last_mode_perm_w);
            $display("        last_was_query = %b (expect 0)", last_was_query_w);
            $display("        session_counter= %0d (expect 1)", session_counter_w);
            $display("        drop_counter   = %0d (expect %0d)", drop_counter_w, drop_count_before);
        end

        // Pads after Test 3: H_req = BLAKE3(motuhake), H_resp = BLAKE3(message_resp)
        begin : t3_pads
            reg [255:0] hreq_new, hresp_new;
            hm_b3_plain32(motuhake_msg, hreq_new);
            hm_b3_plain32(msg_resp_perm_1, hresp_new);
            h_req_after_msg1  = hreq_new;
            h_resp_after_msg1 = hresp_new;
        end

        // ---------------------------------------------------------------------
        // Test 4: Second MOTUHAKE PERMANENT (same session, different pads)
        // ---------------------------------------------------------------------
        x1_in = motuhake_msg ^ h_req_after_msg1;
        begin : t4_x2
            reg [255:0] hmsg;
            hm_b3_plain32(motuhake_msg, hmsg);
            x2_in = (~hmsg) ^ h_resp_after_msg1;
        end

        drop_count_before = drop_counter_w;
        do_message_b(x1_in, x2_in, x1_prime, x2_prime);

        recovered_resp = x1_prime ^ h_req_after_msg1;
        msg_resp_perm_2 = recovered_resp;

        ok = (recovered_resp === expected_msg_resp_perm_1)    // determinism
          && (recovered_resp === msg_resp_perm_2)
          && (last_mode_perm_w === 1'b1)
          && (session_counter_w === 64'd2)
          && (drop_counter_w === drop_count_before);
        report(ok, "Test 4: Second MOTUHAKE PERMANENT (determinism, session_counter=2)");
        if (!ok) begin
            $display("        recovered_resp = %h", recovered_resp);
            $display("        expected (test3)=%h", expected_msg_resp_perm_1);
            $display("        last_mode_perm = %b", last_mode_perm_w);
            $display("        session_counter= %0d", session_counter_w);
            $display("        drop_counter   = %0d", drop_counter_w);
        end

        // Pads after Test 4
        begin : t4_pads
            reg [255:0] hreq_new, hresp_new;
            hm_b3_plain32(motuhake_msg, hreq_new);
            hm_b3_plain32(msg_resp_perm_2, hresp_new);
            h_req_after_msg2  = hreq_new;
            h_resp_after_msg2 = hresp_new;
        end

        // ---------------------------------------------------------------------
        // Test 5: First MOTUHAKE SESSION (same session, SESSION form X2)
        // ---------------------------------------------------------------------
        x1_in = motuhake_msg ^ h_req_after_msg2;
        begin : t5_x2
            reg [255:0] hmsg;
            hm_b3_plain32(motuhake_msg, hmsg);
            x2_in = hmsg ^ h_resp_after_msg2;  // SESSION form: BLAKE3(msg) XOR H_resp
        end

        drop_count_before = drop_counter_w;
        do_message_b(x1_in, x2_in, x1_prime, x2_prime);

        recovered_resp = x1_prime ^ h_req_after_msg2;
        msg_resp_session = recovered_resp;

        // Expected: BLAKE3.keyed(WAIRUA, motuhake)
        begin : t5_exp
            reg [255:0] exp_session;
            hm_b3_keyed32(WAIRUA_FIXED, motuhake_msg, exp_session);

            ok = (recovered_resp === exp_session)
              && (recovered_resp !== msg_resp_perm_1)       // SESSION ≠ PERMANENT
              && (last_mode_perm_w === 1'b0)
              && (last_was_query_w === 1'b0)
              && (session_counter_w === 64'd3)
              && (drop_counter_w === drop_count_before);
            report(ok, "Test 5: First MOTUHAKE SESSION (active_key=WAIRUA, differs from PERMANENT)");
            if (!ok) begin
                $display("        recovered_resp = %h", recovered_resp);
                $display("        expected_session=%h", exp_session);
                $display("        msg_resp_perm_1= %h", msg_resp_perm_1);
                $display("        last_mode_perm = %b (expect 0)", last_mode_perm_w);
                $display("        session_counter= %0d (expect 3)", session_counter_w);
            end
        end

        // Update pads after Test 5
        begin : t5_pads
            reg [255:0] hreq_new, hresp_new;
            hm_b3_plain32(motuhake_msg, hreq_new);
            hm_b3_plain32(msg_resp_session, hresp_new);
            h_req_after_msg2  = hreq_new;       // re-use vars
            h_resp_after_msg2 = hresp_new;
        end

        // ---------------------------------------------------------------------
        // Test 6: Q_HEALTH PERMANENT (Claim 9c)
        // ---------------------------------------------------------------------
        // Set state-vector inputs
        chip_state_in_r       = 3'd4;       // HEALTHY
        ring_health_mask_in_r = 16'hFFFC;
        ring_health_cnt_in_r  = 5'd14;
        slot_burned_mask_in_r = 8'hFF;
        fsm_state_in_r        = 3'd0;
        @(posedge clk);

        // Snapshot the state-block as DUT will see it. session_counter is 3,
        // drop_counter is whatever, boot_epoch is some value.
        session_count_snap = session_counter_w;

        x1_in = Q_HEALTH_IDENT ^ h_req_after_msg2;
        begin : t6_x2
            reg [255:0] hqh;
            hm_b3_plain32(Q_HEALTH_IDENT, hqh);
            x2_in = (~hqh) ^ h_resp_after_msg2;  // PERMANENT
        end

        // We need to capture session_counter, boot_epoch, drop_counter at the
        // moment the DUT hashes the state block (during ST_RESP_REQ). This is
        // tricky because boot_epoch advances every cycle. We'll snapshot
        // active values DURING the exchange via a separate task.
        //
        // Easier approach: drive the exchange, but at the moment we observe
        // fsm_state_debug == ST_RESP_REQ (5'd13), snapshot state_block.
        //
        // We need to do this in parallel with do_message_b. Use a fork.

        drop_count_before = drop_counter_w;

        // Custom inline exchange so we can snapshot at the right moment.
        begin : t6_exch
            reg [255:0] hreq_old, hresp_old;
            reg [255:0] hqh_msg;
            reg [255:0] expected_resp;
            reg [511:0] mblk;
            reg [63:0]  sess_snap, boot_snap, drop_snap;
            reg [255:0] state_block_snap;
            integer i;
            reg b;

            hreq_old  = h_req_after_msg2;
            hresp_old = h_resp_after_msg2;

            // Wire format: leading frame-1, then 256 X1 + 256 X2 = 513 bits.
            send_host_bit(1'b1);
            send_256(x1_in);
            send_256(x2_in);

            // Bounded wait for ST_RESP_REQ (5'd13) — that's the cycle the
            // state block is wired in. Snapshot the inputs at that cycle.
            begin : t6_wait_rr
                integer to;
                to = 5000;
                while (fsm_state_debug_w !== 5'd13 && to > 0) begin
                    @(posedge clk);
                    to = to - 1;
                end
            end
            sess_snap = session_counter_w;
            boot_snap = boot_epoch_w;
            drop_snap = drop_counter_w;

            // Bounded wait for tx_active.
            begin : t6_wait_tx
                integer to;
                to = 5000;
                while (tx_active_w !== 1'b1 && to > 0) begin
                    @(posedge clk);
                    to = to - 1;
                end
            end
            // Consume the enclave's leading frame-1 marker.
            recv_enclave_bit(b);
            if (b !== 1'b1)
                $display("  WARN: t6: enclave frame bit = %b (expected 1)", b);
            x1_prime = 256'b0;
            for (i = 255; i >= 0; i = i - 1) begin
                recv_enclave_bit(b);
                x1_prime[i] = b;
            end
            x2_prime = 256'b0;
            for (i = 255; i >= 0; i = i - 1) begin
                recv_enclave_bit(b);
                x2_prime[i] = b;
            end
            wait_idle();

            recovered_resp = x1_prime ^ hreq_old;

            // Build expected state_block (matches DUT bit packing)
            state_block_snap = {
                29'b0,
                drop_snap,
                boot_snap,
                sess_snap,
                fsm_state_in_r,
                slot_burned_mask_in_r,
                ring_health_cnt_in_r,
                ring_health_mask_in_r,
                chip_state_in_r
            };

            mblk = {state_block_snap, Q_HEALTH_IDENT};
            hm_b3_keyed64(IRA_FIXED, mblk, expected_resp);

            ok = (recovered_resp === expected_resp)
              && (last_mode_perm_w === 1'b1)
              && (last_was_query_w === 1'b1)
              && (session_counter_w === session_count_snap + 64'd1)
              && (drop_counter_w === drop_count_before);
            report(ok, "Test 6: Q_HEALTH PERMANENT (Claim 9c state-vector commitment)");
            if (!ok) begin
                $display("        recovered_resp = %h", recovered_resp);
                $display("        expected_resp  = %h", expected_resp);
                $display("        last_mode_perm = %b (expect 1)", last_mode_perm_w);
                $display("        last_was_query = %b (expect 1)", last_was_query_w);
                $display("        session_counter= %0d (expect %0d)",
                         session_counter_w, session_count_snap + 1);
                $display("        state_block    = %h", state_block_snap);
                $display("        mblk           = %h", mblk);
            end
        end

        // Update pads after Test 6
        begin : t6_pads
            reg [255:0] hreq_new, hresp_new;
            reg [255:0] resp_snap;
            resp_snap = recovered_resp;
            hm_b3_plain32(Q_HEALTH_IDENT, hreq_new);
            hm_b3_plain32(resp_snap, hresp_new);
            h_req_after_msg2  = hreq_new;
            h_resp_after_msg2 = hresp_new;
        end

        // ---------------------------------------------------------------------
        // Test 7: Single-bit fault in X1 → DROP
        // ---------------------------------------------------------------------
        x1_in = motuhake_msg ^ h_req_after_msg2;
        x1_in[127] = ~x1_in[127];  // flip one bit in X1
        begin : t7_x2
            reg [255:0] hmsg;
            hm_b3_plain32(motuhake_msg, hmsg);
            x2_in = (~hmsg) ^ h_resp_after_msg2;
        end

        drop_count_before  = drop_counter_w;
        session_count_snap = session_counter_w;
        do_message_b_expect_drop(x1_in, x2_in, saw_tx, saw_drop);

        ok = (saw_tx === 1'b0)
          && (drop_counter_w === drop_count_before + 64'd1)
          && (session_counter_w === session_count_snap)
          && (fsm_state_debug_w === ST_IDLE);
        report(ok, "Test 7: Single-bit fault in X1 → DROP");
        if (!ok) begin
            $display("        saw_tx=%b saw_drop=%b drop=%0d (expect %0d) session_cnt=%0d (expect %0d) state=%0d",
                     saw_tx, saw_drop, drop_counter_w, drop_count_before + 1,
                     session_counter_w, session_count_snap, fsm_state_debug_w);
        end

        // ---------------------------------------------------------------------
        // Test 8: Single-bit fault in X2 → DROP
        // ---------------------------------------------------------------------
        x1_in = motuhake_msg ^ h_req_after_msg2;
        begin : t8_x2
            reg [255:0] hmsg;
            hm_b3_plain32(motuhake_msg, hmsg);
            x2_in = (~hmsg) ^ h_resp_after_msg2;
            x2_in[42] = ~x2_in[42];  // flip a bit in X2
        end

        drop_count_before  = drop_counter_w;
        session_count_snap = session_counter_w;
        do_message_b_expect_drop(x1_in, x2_in, saw_tx, saw_drop);

        ok = (saw_tx === 1'b0)
          && (drop_counter_w === drop_count_before + 64'd1)
          && (session_counter_w === session_count_snap)
          && (fsm_state_debug_w === ST_IDLE);
        report(ok, "Test 8: Single-bit fault in X2 → DROP");
        if (!ok) begin
            $display("        saw_tx=%b saw_drop=%b drop=%0d (expect %0d) session_cnt=%0d (expect %0d) state=%0d",
                     saw_tx, saw_drop, drop_counter_w, drop_count_before + 1,
                     session_counter_w, session_count_snap, fsm_state_debug_w);
        end

        // ---------------------------------------------------------------------
        // Test 9: SESSION X2 invariant works after PERMANENT history
        //   Confirms both X2 branches are independently tried.
        // ---------------------------------------------------------------------
        x1_in = motuhake_msg ^ h_req_after_msg2;
        begin : t9_x2
            reg [255:0] hmsg;
            hm_b3_plain32(motuhake_msg, hmsg);
            x2_in = hmsg ^ h_resp_after_msg2;  // SESSION form
        end

        drop_count_before  = drop_counter_w;
        session_count_snap = session_counter_w;
        do_message_b(x1_in, x2_in, x1_prime, x2_prime);

        recovered_resp = x1_prime ^ h_req_after_msg2;

        begin : t9_check
            reg [255:0] exp;
            hm_b3_keyed32(WAIRUA_FIXED, motuhake_msg, exp);
            ok = (recovered_resp === exp)
              && (last_mode_perm_w === 1'b0)
              && (drop_counter_w === drop_count_before)
              && (session_counter_w === session_count_snap + 64'd1);
            report(ok, "Test 9: SESSION X2 invariant accepted (mode-detection branch coverage)");
            if (!ok) begin
                $display("        recovered_resp = %h", recovered_resp);
                $display("        expected       = %h", exp);
                $display("        last_mode_perm = %b (expect 0)", last_mode_perm_w);
                $display("        drop_counter   = %0d (expect %0d)", drop_counter_w, drop_count_before);
                $display("        session_counter= %0d (expect %0d)",
                         session_counter_w, session_count_snap + 1);
            end
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("");
        $display("============================================================");
        if (fail_count > 0) begin
            $display(" Diagnostic check (see below if Test 2 failed):");
            $display("   DUT h_req_finger  = %h", h_req_finger_w);
            $display("   DUT h_resp_finger = %h", h_resp_finger_w);
            $display("   Expected H_req    starts %h (BLAKE3 of wairua)", h_req_initial[255:224]);
            $display("   Expected H_resp   starts %h (BLAKE3 of ~wairua)", h_resp_initial[255:224]);
            $display("");
            $display(" If h_req_finger == 00000000 and h_resp_finger == BLAKE3(wairua)[255:224],");
            $display(" the DUT exhibits a known FSM-vs-BLAKE3 handshake bug:");
            $display("   In ST_FS_HREQ_WAIT (and other *_WAIT states), the FSM checks b3_done");
            $display("   on the same cycle b3_valid is asserted to the BLAKE3 core. Because");
            $display("   blake3.v initialises o_valid=1 on reset and stays 1 until i_valid is");
            $display("   sampled, the FSM captures b3_hash[255:0]=0 (stale) on its first WAIT");
            $display("   cycle, then advances to FS_HRESP_REQ. blake3.v has by now started the");
            $display("   first compression and proceeds to complete it, so h_resp ends up =");
            $display("   BLAKE3(wairua) (the H_req computation). The fix is to require b3_done");
            $display("   to go LOW first in every *_WAIT state (e.g., add a one-cycle delay or");
            $display("   gate on a 'request issued' flag).");
            $display("");
        end
        $display("RESULT: %0d/%0d PASS", pass_count, total_tests);
        $display("============================================================");
        $display("");
        $finish;
    end

    // Safety timeout
    initial begin
        #10_000_000;
        $display("");
        $display("  *** TIMEOUT *** simulation did not complete in 10 ms sim time");
        $display("  Last state = %0d, session_valid=%b, session_counter=%0d, drop_counter=%0d",
                 fsm_state_debug_w, session_valid_o_w, session_counter_w, drop_counter_w);
        $display("RESULT: %0d/%0d PASS (TIMEOUT)", pass_count, total_tests);
        $finish;
    end

endmodule
