// deps: ring_health.v ring_scheduler.v
// =============================================================================
// tb_trng.v — integration test for trng + ring_scheduler + ring_health
// =============================================================================
//
// Drives 16 ring inputs with mixed patterns thru one KOHI gather. Uses a tiny SCHED_W=128 so total sim time is bounded.
//
// Patterns:
//   0..11:  distinct LFSRs (healthy)
//   12:     constant 0     (fail)
//   13:     constant 1     (fail)
//   14:     LFSR (healthy)
//   15:     LFSR (healthy)
//
// Expected after gather:
//   ring_health[i]   = 1 for i in {0..11, 14, 15}; 0 for {12, 13}
//   ring_health_cnt  = 14
//   health_fail      = 0 (>= 8 healthy → not FUCKED)
//   gather_done      pulsed
//   buffer holds bit-stream data (non-zero in many bytes)
//
// =============================================================================

`timescale 1ns / 1ps

module tb_trng;

    localparam integer SCHED_W = 128;

    // Recompute scaled thresholds for the tiny W:
    //   sigma = sqrt(W)/2 = ~5.66 → 6*sigma ≈ 34
    //   LVL_LO = 64 - 34 = 30;  LVL_HI = 64 + 34 = 98
    //   APT_W = 16 (W/APT_W = 8 windows per ring); APT_T = 14
    //   RCT_C stays 32 (window-independent)
    localparam integer LVL_LO = 30;
    localparam integer LVL_HI = 98;
    localparam integer APT_W  = 16;
    localparam integer APT_T  = 14;
    localparam integer RCT_C  = 32;

    reg          clk     = 1'b0;
    reg          reset_n = 1'b0;
    reg          start   = 1'b0;
    reg  [15:0]  ring_in = 16'b0;
    reg  [12:0]  buf_raddr = 13'b0;
    wire [7:0]   buf_rdata;
    wire         busy;
    wire         gather_done;
    wire         health_fail;
    wire [15:0]  ring_health;
    wire [4:0]   ring_health_cnt;
    wire [15:0]  ring_enable;

    trng #(
        .SCHED_W      (SCHED_W),
        .SCHED_RCT_C  (RCT_C),
        .SCHED_APT_W  (APT_W),
        .SCHED_APT_T  (APT_T),
        .SCHED_LVL_LO (LVL_LO),
        .SCHED_LVL_HI (LVL_HI)
    ) dut (
        .clk             (clk),
        .reset_n         (reset_n),
        .start           (start),
        .ring_in         (ring_in),
        .buf_raddr       (buf_raddr),
        .buf_rdata       (buf_rdata),
        .busy            (busy),
        .gather_done     (gather_done),
        .health_fail     (health_fail),
        .ring_health     (ring_health),
        .ring_health_cnt (ring_health_cnt),
        .ring_enable     (ring_enable)
    );

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // 16 distinct LFSRs (rings 0..11, 14, 15) + 2 constant rings (12, 13)
    // -------------------------------------------------------------------------
    reg [15:0] lfsr [0:15];
    integer li;

    always @(posedge clk) begin
        if (reset_n) begin
            for (li = 0; li < 16; li = li + 1) begin
                lfsr[li] <= {lfsr[li][14:0],
                             lfsr[li][15] ^ lfsr[li][13] ^ lfsr[li][12] ^ lfsr[li][10]};
            end
        end
    end

    integer ri;
    always @* begin
        for (ri = 0; ri < 16; ri = ri + 1)
            ring_in[ri] = lfsr[ri][0];
        ring_in[12] = 1'b0;          // stuck low
        ring_in[13] = 1'b1;          // stuck high
    end

    // -------------------------------------------------------------------------
    integer pass = 0;
    integer fail = 0;
    integer buf_nonzero;
    integer cyc;

    initial begin
        // Init LFSRs with distinct seeds
        for (li = 0; li < 16; li = li + 1)
            lfsr[li] = 16'hACE1 + li[15:0] * 16'h0BAD;

        reset_n = 1'b0;
        #25;
        reset_n = 1'b1;
        #10;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Wait for gather to complete. Worst case: 16 rings * (W + a few FSM cycles)
        // ~= 16 * 140 = 2240 cycles. Plus settling. Pad to 10k.
        cyc = 0;
        while (!gather_done && !health_fail && cyc < 10000) begin
            @(negedge clk);
            cyc = cyc + 1;
        end

        if (cyc >= 10000) begin
            fail = fail + 1;
            $display("FAIL  gather never completed (cyc=%0d)", cyc);
        end else begin
            // ring_health_mask check: bits 0..11, 14, 15 should be 1; 12, 13 should be 0
            if (ring_health === 16'b1100_1111_1111_1111) begin
                pass = pass + 1;
                $display("PASS  ring_health = 0x%04h (rings 12, 13 failed as expected)", ring_health);
            end else begin
                fail = fail + 1;
                $display("FAIL  ring_health = 0x%04h  expected 0xCFFF", ring_health);
            end

            if (ring_health_cnt === 5'd14) begin
                pass = pass + 1;
                $display("PASS  ring_health_cnt = 14");
            end else begin
                fail = fail + 1;
                $display("FAIL  ring_health_cnt = %0d  expected 14", ring_health_cnt);
            end

            if (!health_fail) begin
                pass = pass + 1;
                $display("PASS  health_fail = 0 (14 healthy >= byzantine threshold of 8)");
            end else begin
                fail = fail + 1;
                $display("FAIL  health_fail = 1 unexpectedly");
            end

            if (gather_done) begin
                pass = pass + 1;
                $display("PASS  gather_done pulsed");
            end else begin
                fail = fail + 1;
                $display("FAIL  gather_done did not pulse");
            end

            // Check buffer has data (sample a few addresses)
            buf_nonzero = 0;
            for (cyc = 0; cyc < 64; cyc = cyc + 1) begin
                buf_raddr = cyc[12:0] * 13'd16;     // every 16th byte
                @(posedge clk);
                @(negedge clk);
                if (buf_rdata !== 8'h00) buf_nonzero = buf_nonzero + 1;
            end
            if (buf_nonzero >= 32) begin
                pass = pass + 1;
                $display("PASS  buffer non-empty: %0d/64 sampled bytes non-zero", buf_nonzero);
            end else begin
                fail = fail + 1;
                $display("FAIL  buffer too sparse: only %0d/64 non-zero", buf_nonzero);
            end
        end

        $display("");
        $display("===========================================");
        $display(" tb_trng: %0d pass / %0d fail", pass, fail);
        $display("===========================================");
        if (fail == 0) $display("OVERALL PASS");
        else           $display("OVERALL FAIL");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL  testbench TIMEOUT");
        $display("OVERALL FAIL");
        $finish;
    end

endmodule
