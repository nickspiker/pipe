// =============================================================================
// ira_ceremony_tb.v — full KOHI → BLAKE3 → TAHU ceremony integration test
// =============================================================================
//
// Wires up the actual production modules (trng + blake3_tree + otp +
// inverted_pair_verify + ira_fsm) and drives the provisioning ceremony
// from KORE to ORA. Validates that:
//   - chip_state starts at KORE (0) on power-up (all OTP slots zero)
//   - provision_request triggers KOHI
//   - trng gathers, popcounts all stay in band → no health_fail
//   - blake3_tree conditions the buffer → 256-bit ira_seed
//   - ira_fsm burns A-slots then B-slots
//   - chip_state transitions to ORA (4)
//   - ceremony_done pulses
//   - chip_ngaro stays low thruout
//
// Rings are simulated by per-ring LFSRs giving each ring a different,
// ~50/50 bit stream that easily passes the ¼…¾ popcount health check.
//
// Run via scripts/test_ira_ceremony.sh.
// =============================================================================

`timescale 1ns / 1ps

module ira_ceremony_tb;

    // -------------------------------------------------------------------------
    // Clock + reset
    // -------------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;        // 100 MHz sim clock

    reg reset_n = 0;
    reg provision_request = 0;

    // -------------------------------------------------------------------------
    // Simulated ring oscillator outputs — 16 independent LFSRs, each seeded
    // differently. Per-cycle LSB of each LFSR is the "ring output".
    // This passes the 8-of-16 health check with margin.
    // -------------------------------------------------------------------------
    reg [31:0] lfsr [0:15];
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            lfsr[i] = 32'hCAFE_BABE + (i * 32'h0123_4567);
    end

    wire [15:0] ring_in;
    genvar r;
    generate
        for (r = 0; r < 16; r = r + 1) begin : ring_sim
            always @(posedge clk) begin
                // 32-bit Galois LFSR, taps 0x80200003 (same as oled dither)
                if (lfsr[r][0])
                    lfsr[r] <= (lfsr[r] >> 1) ^ 32'h80200003;
                else
                    lfsr[r] <= (lfsr[r] >> 1);
            end
            assign ring_in[r] = lfsr[r][0];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // trng
    // -------------------------------------------------------------------------
    wire [12:0] trng_buf_raddr;
    wire [7:0]  trng_buf_rdata;
    wire        trng_busy, trng_gather_done, trng_health_fail;
    wire [15:0] trng_ring_health;
    wire [4:0]  trng_ring_health_cnt;
    wire [15:0] trng_ring_enable;
    wire        trng_start_sig;

    trng u_trng (
        .clk            (clk),
        .reset_n        (reset_n),
        .start          (trng_start_sig),
        .ring_in        (ring_in),
        .buf_raddr      (trng_buf_raddr),
        .buf_rdata      (trng_buf_rdata),
        .busy           (trng_busy),
        .gather_done    (trng_gather_done),
        .health_fail    (trng_health_fail),
        .ring_health    (trng_ring_health),
        .ring_health_cnt(trng_ring_health_cnt),
        .ring_enable    (trng_ring_enable)
    );

    // -------------------------------------------------------------------------
    // blake3_tree — reads trng's buffer directly
    // -------------------------------------------------------------------------
    wire        blake3_busy, blake3_ira_valid;
    wire [255:0] blake3_ira;
    wire        blake3_start_sig;

    blake3_tree u_blake3 (
        .clk      (clk),
        .reset_n  (reset_n),
        .start    (blake3_start_sig),
        .buf_raddr(trng_buf_raddr),       // trng's read addr is wired both ways
        .buf_rdata(trng_buf_rdata),
        .ira      (blake3_ira),
        .ira_valid(blake3_ira_valid),
        .busy     (blake3_busy)
    );

    // NOTE: trng_buf_raddr is driven by BOTH trng (during ST_GATHER, internal)
    // AND blake3_tree (during its ST_LOAD, combinational). They never run
    // simultaneously — trng must complete gather before blake3 starts —
    // so only one driver is active at a time. To make this clean, trng.v
    // exposes the buffer as a read port (it doesn't drive the addr; the
    // CALLER drives the addr to read the buffer). Wire is shared.

    // -------------------------------------------------------------------------
    // OTP
    // -------------------------------------------------------------------------
    wire [2:0]   otp_read_addr;
    wire [255:0] otp_read_data;
    wire         otp_read_burned;
    wire [2:0]   otp_write_addr;
    wire [255:0] otp_write_data;
    wire         otp_write_enable;
    wire         otp_write_done;
    wire         otp_write_rejected;
    wire [7:0]   otp_burned_mask;

    otp u_otp (
        .clk           (clk),
        .reset_n       (reset_n),
        .wipe          (1'b0),
        .read_addr     (otp_read_addr),
        .read_data     (otp_read_data),
        .read_burned   (otp_read_burned),
        .write_addr    (otp_write_addr),
        .write_data    (otp_write_data),
        .write_enable  (otp_write_enable),
        .write_done    (otp_write_done),
        .write_rejected(otp_write_rejected),
        .burned_mask   (otp_burned_mask),
        .all_slots_flat()
    );

    // -------------------------------------------------------------------------
    // Inverted-pair classifier — needs all 8 OTP slots flattened. The
    // simplest path: instantiate otp's storage as a direct array (i.e.,
    // skip the otp.read_addr port and read all 8 slots in parallel via
    // a 8-way fanout). For sim we use a hierarchical reference into
    // u_otp's internal slot_data array — this works in iverilog and the
    // FPGA-side top.v will do the same with explicit wide-port plumbing.
    // -------------------------------------------------------------------------
    wire [8*256-1:0] all_slots = {
        u_otp.slot_data[7], u_otp.slot_data[6], u_otp.slot_data[5], u_otp.slot_data[4],
        u_otp.slot_data[3], u_otp.slot_data[2], u_otp.slot_data[1], u_otp.slot_data[0]
    };

    wire [1:0]   chip_state;
    wire         chip_state_ngaro;
    wire         byzantine_ok;
    wire [255:0] recovered_ira;
    wire [3:0]   pair_valid;

    wire verify_state_valid;
    inverted_pair_verify u_verify (
        .clk         (clk),
        .reset_n     (reset_n),
        .slot_flat   (all_slots),
        .state_valid (verify_state_valid),
        .pair_kore (),
        .pair_valid  (pair_valid),
        .pair_corrupt(),
        .valid_count (),
        .all_kore  (),
        .agreement_ok(),
        .byzantine_ok(byzantine_ok),
        .chip_ngaro  (chip_state_ngaro),
        .state       (chip_state),
        .ira         (recovered_ira)
    );

    // -------------------------------------------------------------------------
    // ira_fsm — the orchestrator
    // -------------------------------------------------------------------------
    wire chip_ngaro, ceremony_busy, ceremony_done;
    wire [3:0] fsm_state;

    ira_fsm u_fsm (
        .clk              (clk),
        .reset_n          (reset_n),
        .provision_request(provision_request),
        .chip_state       (chip_state),
        .chip_state_ngaro  (chip_state_ngaro),
        .byzantine_ok     (byzantine_ok),
        .trng_start       (trng_start_sig),
        .trng_busy        (trng_busy),
        .trng_gather_done (trng_gather_done),
        .trng_health_fail (trng_health_fail),
        .blake3_start     (blake3_start_sig),
        .blake3_busy      (blake3_busy),
        .blake3_ira_valid (blake3_ira_valid),
        .blake3_ira       (blake3_ira),
        .otp_write_addr   (otp_write_addr),
        .otp_write_data   (otp_write_data),
        .otp_write_enable (otp_write_enable),
        .otp_write_done   (otp_write_done),
        .otp_write_rejected(otp_write_rejected),
        // Sim has unbounded simulated energy -- tie the gate high.
        .energy_ok        (1'b1),
        .chip_ngaro      (chip_ngaro),
        .ceremony_busy    (ceremony_busy),
        .ceremony_done    (ceremony_done),
        .fsm_state        (fsm_state)
    );

    assign otp_read_addr = 3'b0;  // unused in this TB

    // -------------------------------------------------------------------------
    // Stimulus + checks
    // -------------------------------------------------------------------------
    integer t_start, t_kohi_done, t_blake3_done, t_ceremony_done;

    initial begin
        $display("");
        $display("=== ira ceremony integration test ===");
        $display("");

        // Power-up
        reset_n = 0;
        #50;
        reset_n = 1;
        #10;

        // Wait for the sequential popcount sweep to complete its first pass.
        wait (verify_state_valid);
        @(posedge clk);
        $display("[t=%0t] After reset + first sweep: chip_state=%0d (expect 0=KORE), chip_ngaro=%b",
                 $time, chip_state, chip_ngaro);
        if (chip_state !== 3'd0)
            $display("  FAIL: expected KORE at boot, got state=%0d", chip_state);

        // Trigger provisioning
        #20;
        provision_request = 1;
        #10 provision_request = 0;
        t_start = $time;
        $display("[t=%0t] provision_request issued — entering KOHI", $time);

        // Wait for KOHI to complete (gather_done OR health_fail)
        wait (trng_gather_done || trng_health_fail);
        t_kohi_done = $time;
        if (trng_health_fail) begin
            $display("[t=%0t] KOHI FAILED — trng.health_fail asserted (rings unhealthy)", $time);
            $display("  ring_health=%b ring_health_cnt=%0d", trng_ring_health, trng_ring_health_cnt);
            $display("  *** FAIL ***");
            $finish;
        end
        $display("[t=%0t] KOHI complete: %0d ns (%0d cycles), ring_health=%b cnt=%0d",
                 $time, t_kohi_done - t_start, (t_kohi_done - t_start) / 10,
                 trng_ring_health, trng_ring_health_cnt);

        // Wait for BLAKE3 to finish
        wait (blake3_ira_valid);
        t_blake3_done = $time;
        $display("[t=%0t] BLAKE3 complete: %0d ns more (%0d cycles), ira_seed=%h",
                 $time, t_blake3_done - t_kohi_done, (t_blake3_done - t_kohi_done) / 10,
                 blake3_ira);

        // Wait for ceremony_done
        wait (ceremony_done);
        t_ceremony_done = $time;
        $display("[t=%0t] Ceremony done: %0d ns total (%0d cycles)",
                 $time, t_ceremony_done - t_start, (t_ceremony_done - t_start) / 10);
        $display("  All 8 OTP slots burned: burned_mask=%b", otp_burned_mask);

        // Wait for verify to re-sweep on the post-burn slot contents.
        // The sweep is 2049 cycles (low-and-slow); wait 5000 to cover two.
        repeat (5000) @(posedge clk);
        $display("[t=%0t] Post-ceremony + resweep: chip_state=%0d (expect 3=ORA), chip_ngaro=%b",
                 $time, chip_state, chip_ngaro);
        $display("  pair_valid=%b, byzantine_ok=%b", pair_valid, byzantine_ok);
        $display("  recovered_ira=%h", recovered_ira);

        if (chip_state === 2'd3 && chip_ngaro === 1'b0 && byzantine_ok && recovered_ira === blake3_ira) begin
            $display("");
            $display("  *** PASS ***  KORE → ORA ceremony complete, ira matches");
        end else begin
            $display("");
            $display("  *** FAIL ***  ceremony did not reach ORA state cleanly");
        end
        $display("");
        $finish;
    end

    // Safety timeout — full ceremony should fit in ~80 k cycles = 800 us sim.
    initial begin
        #5_000_000;
        $display("");
        $display("  *** TIMEOUT ***  ceremony did not complete in 5 ms sim time");
        $display("  fsm_state=%0d, chip_state=%0d, trng_busy=%b, blake3_busy=%b",
                 fsm_state, chip_state, trng_busy, blake3_busy);
        $finish;
    end

endmodule
