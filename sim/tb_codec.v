// =============================================================================
// tb_codec.v — paired enclave/host codec end-to-end test
// =============================================================================
//
// Two `codec` instances back-to-back over a shared simulated wire:
//   enc  : OWN_IDLE = 1, drives even slots (slot_idx[0] == 0)
//   host : OWN_IDLE = 0, drives odd  slots (slot_idx[0] == 1)
//
// On each posedge clk, slot_idx increments. my_slot for each side is derived
// combinationally from slot_idx, and the wire is sourced from whoever's
// drive_en is currently asserted.
//
// Stimulus: 128 slots covering idle, single-bit injections from each side,
// simultaneous injection from both, and a longer random pattern.
//
// Check at each posedge (with one slot of pipeline delay): the side whose
// slot just ended should have the OTHER side's tx_data from the prior slot
// available on its rx_data port.
// =============================================================================

`timescale 1ns / 1ps

module tb_codec;

    reg clk = 0;
    reg reset_n = 0;

    reg [31:0] slot_idx = 0;

    reg enc_tx_data  = 0;
    reg host_tx_data = 0;

    wire enc_my_slot  = ~slot_idx[0];
    wire host_my_slot =  slot_idx[0];

    wire enc_wire_out,  enc_drive_en;
    wire host_wire_out, host_drive_en;

    wire enc_rx_data,  enc_rx_valid;
    wire host_rx_data, host_rx_valid;

    // Wire bus: whichever side is driving wins. drive_en is mutually exclusive
    // by construction (my_slot signals are inverses).
    wire wire_value = enc_drive_en ? enc_wire_out : host_wire_out;

    codec #(.OWN_IDLE(1'b1)) enc (
        .clk      (clk),
        .reset_n  (reset_n),
        .my_slot  (enc_my_slot),
        .tx_data  (enc_tx_data),
        .wire_in  (wire_value),
        .rx_data  (enc_rx_data),
        .rx_valid (enc_rx_valid),
        .wire_out (enc_wire_out),
        .drive_en (enc_drive_en)
    );

    codec #(.OWN_IDLE(1'b0)) host (
        .clk      (clk),
        .reset_n  (reset_n),
        .my_slot  (host_my_slot),
        .tx_data  (host_tx_data),
        .wire_in  (wire_value),
        .rx_data  (host_rx_data),
        .rx_valid (host_rx_valid),
        .wire_out (host_wire_out),
        .drive_en (host_drive_en)
    );

    always #5 clk = ~clk;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) slot_idx <= 32'd0;
        else          slot_idx <= slot_idx + 32'd1;
    end

    // Reference: tx_data shifted by one slot (to match rx_data pipeline).
    reg enc_tx_prev  = 0;
    reg host_tx_prev = 0;
    always @(posedge clk) begin
        enc_tx_prev  <= enc_tx_data;
        host_tx_prev <= host_tx_data;
    end

    // -------------------------------------------------------------------------
    // Stimulus: drive tx_data per side as a function of slot_idx.
    // -------------------------------------------------------------------------
    // 0..15      idle
    // 17         host injects single 1
    // 19..27     idle
    // 28         enc injects single 1
    // 29..39     idle
    // 41         host = 1
    // 42         enc  = 1
    // 43..51     idle
    // 53..52+64  random pattern from both (LFSR-driven)
    // -------------------------------------------------------------------------
    reg [15:0] lfsr_h = 16'hACE1;
    reg [15:0] lfsr_e = 16'hBEEF;

    always @(*) begin
        enc_tx_data  = 1'b0;
        host_tx_data = 1'b0;
        case (slot_idx)
            32'd17: host_tx_data = 1'b1;
            32'd28: enc_tx_data  = 1'b1;
            32'd41: host_tx_data = 1'b1;
            32'd42: enc_tx_data  = 1'b1;
            default: begin
                if (slot_idx >= 32'd52 && slot_idx < 32'd128) begin
                    if (host_my_slot) host_tx_data = lfsr_h[0];
                    if (enc_my_slot)  enc_tx_data  = lfsr_e[0];
                end
            end
        endcase
    end

    always @(posedge clk) begin
        if (slot_idx >= 32'd51) begin
            if (host_my_slot) lfsr_h <= {lfsr_h[0] ^ lfsr_h[2] ^ lfsr_h[3] ^ lfsr_h[5], lfsr_h[15:1]};
            if (enc_my_slot)  lfsr_e <= {lfsr_e[0] ^ lfsr_e[2] ^ lfsr_e[3] ^ lfsr_e[5], lfsr_e[15:1]};
        end
    end

    // -------------------------------------------------------------------------
    // Checks
    // -------------------------------------------------------------------------
    integer pass = 0;
    integer fail = 0;

    task check_bit;
        input [255:0] tag;
        input        actual;
        input        expected;
        begin
            if (actual === expected) begin
                pass = pass + 1;
            end else begin
                fail = fail + 1;
                $display("FAIL  slot=%0d  %s  got=%b expected=%b",
                         slot_idx, tag, actual, expected);
            end
        end
    endtask

    // Track who drove what at the slot that just ended, to check the other
    // side decoded it.
    integer first_check_slot = 2;  // give pipeline a couple of cycles
    always @(posedge clk) begin
        #1;  // settle non-blocking updates
        if (reset_n && slot_idx >= first_check_slot) begin
            // slot_idx now reflects the slot that just BEGAN.
            // The slot that ended was slot_idx - 1.
            // If (slot_idx - 1) was enc's slot (even), host should have decoded
            // it: host.rx_data === enc_tx (one slot earlier on enc's side).
            // tx_prev captures the value tx_data had at slot_idx - 1.
            if (slot_idx[0] == 1'b1) begin
                // We just entered an odd slot → the slot that ended was even (enc's)
                check_bit("host decoded enc's last bit",
                          host_rx_data, enc_tx_prev);
                check_bit("host rx_valid asserted",
                          host_rx_valid, 1'b1);
            end else begin
                // We just entered an even slot → the slot that ended was odd (host's)
                check_bit("enc decoded host's last bit",
                          enc_rx_data, host_tx_prev);
                check_bit("enc rx_valid asserted",
                          enc_rx_valid, 1'b1);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Wire-pattern dump for the manually-set test points (slots 14..30 covers
    // both single-injection cases). Useful for visual sanity-check.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset_n && slot_idx >= 32'd14 && slot_idx <= 32'd30) begin
            $display("slot=%0d  owner=%s  enc_tx=%b host_tx=%b  wire=%b",
                     slot_idx, slot_idx[0] ? "host" : "enc ",
                     enc_tx_data, host_tx_data, wire_value);
        end
    end

    // -------------------------------------------------------------------------
    // Run
    // -------------------------------------------------------------------------
    initial begin
        reset_n = 0;
        #20;
        reset_n = 1;

        // Run for 130 slots
        repeat (260) @(posedge clk);

        $display("");
        $display("codec tests: %0d pass, %0d fail", pass, fail);
        if (fail == 0)
            $display("OVERALL PASS");
        else
            $display("OVERALL FAIL");
        $finish;
    end

endmodule
