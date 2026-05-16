// =============================================================================
// tb_ring_health_mux.v — exercise time-multiplexed per-ring health check
// =============================================================================
//
// Drives 16 independent ring patterns on ring_sample[15:0], updating once per "slow tick" (every 16 fast clock cycles). The DUT samples each ring on successive fast cycles within the slow tick window.
//
// Patterns identical to tb_ring_scheduler:
//   0..9: distinct LFSR seeds (all healthy)
//   10:   constant 0           (fail)
//   11:   constant 1           (fail)
//   12:   00000111 periodic    (fail — level 0 popcount way off)
//   13:   01 periodic          (fail — level 1 popcount maxes)
//   14:   00001111 periodic    (fail — level 1 popcount way off)
//   15:   LFSR healthy
//
// Expected: healthy_mask = 16'h83FF (11 healthy).
//
// W reduced to 256 for sim speed: 256 slow ticks × 16 fast cycles = 4096 fast cycles per gather + 16 for verdict pass.
// =============================================================================

`timescale 1ns / 1ps

module tb_ring_health_mux;

    localparam integer N_RINGS = 16;
    localparam integer W       = 256;

    reg          clk         = 1'b0;
    reg          reset_n     = 1'b0;
    reg          start       = 1'b0;
    reg  [15:0]  ring_sample = 16'b0;
    wire         done;
    wire [15:0]  healthy_mask;

    ring_health_mux #(
        .N_RINGS (N_RINGS),
        .W       (W),
        .RCT_C   (32),
        .APT_W   (32),
        .APT_T   (28),
        .LVL_LO  (80),
        .LVL_HI  (176)
    ) dut (
        .clk          (clk),
        .reset_n      (reset_n),
        .start        (start),
        .ring_sample  (ring_sample),
        .done         (done),
        .healthy_mask (healthy_mask)
    );

    always #5 clk = ~clk;   // fast clock (100 MHz)

    // -------------------------------------------------------------------------
    // 16 pattern generators advance once per slow tick (every N_RINGS=16 fast cycles)
    // -------------------------------------------------------------------------
    reg [15:0] lfsr0 = 16'hACE1;
    reg [15:0] lfsr1 = 16'h1234;
    reg [15:0] lfsr2 = 16'hBEEF;
    reg [15:0] lfsr3 = 16'hDEAD;
    reg [15:0] lfsr4 = 16'hCAFE;
    reg [15:0] lfsr5 = 16'hF00D;
    reg [15:0] lfsr6 = 16'h5A5A;
    reg [15:0] lfsr7 = 16'hA5A5;
    reg [15:0] lfsr8 = 16'h0F0F;
    reg [15:0] lfsr9 = 16'hF0F0;
    reg [15:0] lfsr15 = 16'h1357;
    reg [7:0]  phase8 = 8'd0;
    reg [3:0]  fast_phase = 4'd0;

    // fast_phase counts fast cycles; on wrap (15→0), it's a slow-tick boundary
    always @(posedge clk) if (reset_n) fast_phase <= fast_phase + 4'd1;

    // Advance pattern generators on slow-tick boundary
    always @(posedge clk) begin
        if (reset_n && fast_phase == 4'd15) begin
            lfsr0  <= {lfsr0 [14:0], lfsr0 [15]^lfsr0 [13]^lfsr0 [12]^lfsr0 [10]};
            lfsr1  <= {lfsr1 [14:0], lfsr1 [15]^lfsr1 [13]^lfsr1 [12]^lfsr1 [10]};
            lfsr2  <= {lfsr2 [14:0], lfsr2 [15]^lfsr2 [13]^lfsr2 [12]^lfsr2 [10]};
            lfsr3  <= {lfsr3 [14:0], lfsr3 [15]^lfsr3 [13]^lfsr3 [12]^lfsr3 [10]};
            lfsr4  <= {lfsr4 [14:0], lfsr4 [15]^lfsr4 [13]^lfsr4 [12]^lfsr4 [10]};
            lfsr5  <= {lfsr5 [14:0], lfsr5 [15]^lfsr5 [13]^lfsr5 [12]^lfsr5 [10]};
            lfsr6  <= {lfsr6 [14:0], lfsr6 [15]^lfsr6 [13]^lfsr6 [12]^lfsr6 [10]};
            lfsr7  <= {lfsr7 [14:0], lfsr7 [15]^lfsr7 [13]^lfsr7 [12]^lfsr7 [10]};
            lfsr8  <= {lfsr8 [14:0], lfsr8 [15]^lfsr8 [13]^lfsr8 [12]^lfsr8 [10]};
            lfsr9  <= {lfsr9 [14:0], lfsr9 [15]^lfsr9 [13]^lfsr9 [12]^lfsr9 [10]};
            lfsr15 <= {lfsr15[14:0], lfsr15[15]^lfsr15[13]^lfsr15[12]^lfsr15[10]};
            phase8 <= phase8 + 8'd1;
        end
    end

    // Compose ring_sample[15:0]
    always @* begin
        ring_sample[0]  = lfsr0[0];
        ring_sample[1]  = lfsr1[0];
        ring_sample[2]  = lfsr2[0];
        ring_sample[3]  = lfsr3[0];
        ring_sample[4]  = lfsr4[0];
        ring_sample[5]  = lfsr5[0];
        ring_sample[6]  = lfsr6[0];
        ring_sample[7]  = lfsr7[0];
        ring_sample[8]  = lfsr8[0];
        ring_sample[9]  = lfsr9[0];
        ring_sample[10] = 1'b0;
        ring_sample[11] = 1'b1;
        // 00000111 — period 8 ones in slots 5,6,7
        ring_sample[12] = (phase8[2:0] == 3'd5)
                       || (phase8[2:0] == 3'd6)
                       || (phase8[2:0] == 3'd7);
        ring_sample[13] = phase8[0];
        ring_sample[14] = phase8[2];
        ring_sample[15] = lfsr15[0];
    end

    // -------------------------------------------------------------------------
    integer pass = 0;
    integer fail = 0;

    initial begin
        reset_n = 1'b0;
        #25;
        reset_n = 1'b1;
        // wait until fast_phase wraps so start aligns with phase 0
        @(posedge clk); while (fast_phase != 4'd15) @(posedge clk);
        @(posedge clk);   // now fast_phase = 0
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        while (!done) @(posedge clk);

        if (healthy_mask === 16'h83FF) begin
            pass = pass + 1;
            $display("PASS  healthy_mask = 0x%04h (expected 0x83FF)", healthy_mask);
        end else begin
            fail = fail + 1;
            $display("FAIL  healthy_mask got=0x%04h expected=0x83FF", healthy_mask);
        end

        $display("");
        $display("===========================================");
        $display(" tb_ring_health_mux: %0d pass / %0d fail", pass, fail);
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
