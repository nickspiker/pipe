// deps: ring_health.v
// =============================================================================
// tb_ring_scheduler.v — exercise round-robin per-ring health gather
// =============================================================================
//
// Drives 16 independent ring patterns:
//   0..9: distinct LFSR seeds (all healthy)
//   10:   constant 0           (fail)
//   11:   constant 1           (fail)
//   12:   00000111 periodic    (fail — level 0 popcount way off)
//   13:   01 periodic          (fail — level 1 popcount maxes)
//   14:   00001111 periodic    (fail — level 1 popcount way off)
//   15:   LFSR healthy
//
// Expected: 11 healthy, 5 unhealthy. ring_health_cnt = 11.
//
// W is reduced to 256 for sim speed (16*256 = ~4K cycles total per KOHI).
// =============================================================================

`timescale 1ns / 1ps

module tb_ring_scheduler;

    localparam integer N_RINGS = 16;
    localparam integer W       = 256;

    reg          clk     = 1'b0;
    reg          reset_n = 1'b0;
    reg          start   = 1'b0;
    reg  [15:0]  ring_in = 16'b0;
    wire [15:0]  ring_enable;
    wire         sample_bit;
    wire         sample_valid;
    wire         busy;
    wire         all_done;
    wire [15:0]  ring_health_mask;
    wire [4:0]   ring_health_cnt;

    // DUT: scheduler with shrunken W for sim speed. Thresholds scaled to W=256:
    //   sigma = sqrt(W)/2 = 8;  6*sigma = 48
    //   LVL_LO = 128 - 48 = 80;  LVL_HI = 128 + 48 = 176
    //   APT_W = 32 (W/APT_W = 8 windows per gather);
    //     APT_T = 32/2 + 6*sqrt(32)/2 = 16 + ~17 = ~24, round up to 28 for margin
    ring_scheduler #(
        .N_RINGS      (N_RINGS),
        .W            (W),
        .ENABLE_DELAY (4),
        .RCT_C        (32),
        .APT_W        (32),
        .APT_T        (28),
        .LVL_LO       (80),
        .LVL_HI       (176)
    ) dut (
        .clk              (clk),
        .reset_n          (reset_n),
        .start            (start),
        .ring_in          (ring_in),
        .ring_enable      (ring_enable),
        .sample_bit       (sample_bit),
        .sample_valid     (sample_valid),
        .busy             (busy),
        .all_done         (all_done),
        .ring_health_mask (ring_health_mask),
        .ring_health_cnt  (ring_health_cnt)
    );

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // 16 independent pattern generators that advance every clock
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

    integer cycle_cnt = 0;

    always @(posedge clk) begin
        if (reset_n) begin
            // step each LFSR (taps 16,14,13,11 = bits [15,13,12,10])
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
            cycle_cnt <= cycle_cnt + 1;
        end
    end

    // Periodic-pattern phase counter, advances every cycle
    reg [7:0] phase = 8'd0;
    always @(posedge clk) if (reset_n) phase <= phase + 8'd1;

    // Compose ring_in[15:0]
    always @* begin
        ring_in[0]  = lfsr0[0];
        ring_in[1]  = lfsr1[0];
        ring_in[2]  = lfsr2[0];
        ring_in[3]  = lfsr3[0];
        ring_in[4]  = lfsr4[0];
        ring_in[5]  = lfsr5[0];
        ring_in[6]  = lfsr6[0];
        ring_in[7]  = lfsr7[0];
        ring_in[8]  = lfsr8[0];
        ring_in[9]  = lfsr9[0];
        ring_in[10] = 1'b0;                               // constant 0
        ring_in[11] = 1'b1;                               // constant 1
        // 00000111 — period 8
        ring_in[12] = (phase[2:0] == 3'd5)
                   || (phase[2:0] == 3'd6)
                   || (phase[2:0] == 3'd7);
        // 01 — period 2
        ring_in[13] = phase[0];
        // 00001111 — period 8, balanced
        ring_in[14] = phase[2];
        ring_in[15] = lfsr15[0];
    end

    // -------------------------------------------------------------------------
    integer pass = 0;
    integer fail = 0;

    task expect_eq;
        input [255:0] tag;
        input [15:0]  actual;
        input [15:0]  expected;
        begin
            if (actual === expected) begin
                pass = pass + 1;
                $display("PASS  %0s  (got=0x%04h)", tag, actual);
            end else begin
                fail = fail + 1;
                $display("FAIL  %0s  got=0x%04h expected=0x%04h",
                          tag, actual, expected);
            end
        end
    endtask

    initial begin
        reset_n = 1'b0;
        #25;
        reset_n = 1'b1;
        #20;

        // kick off the full schedule
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // wait for completion — schedule = 16 * (W + a few cycles) ~= 16*270 = 4320 cycles
        // at 10 ns each = 43.2 us. Margin generously.
        while (!all_done) @(negedge clk);

        // Healthy mask: rings 10..14 fail, rest pass
        // bits: 0-9 pass, 10-14 fail, 15 pass
        // = 16'b1000_0011_1111_1111 = 16'h83FF
        expect_eq("ring_health_mask matches", ring_health_mask, 16'h83FF);

        if (ring_health_cnt === 5'd11) begin
            pass = pass + 1;
            $display("PASS  ring_health_cnt = 11");
        end else begin
            fail = fail + 1;
            $display("FAIL  ring_health_cnt got=%0d expected=11", ring_health_cnt);
        end

        // -- Summary --
        $display("");
        $display("===========================================");
        $display(" tb_ring_scheduler: %0d pass / %0d fail", pass, fail);
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
