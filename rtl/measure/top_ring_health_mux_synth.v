// =============================================================================
// top_ring_health_mux_synth.v — Fmax bench for ring_health_mux.v (Variant E)
// =============================================================================
//
// Wraps a single ring_health_mux instance in a self-restart harness. 16 LFSRs with distinct seeds drive ring_sample, updated once every N_RINGS=16 fast cycles (the implicit slow-tick boundary). The DUT clock IS the fast clock.
//
// Outputs:
//   led      — toggles each completed full KOHI (16-ring health verdict)
//   ext_led  — XOR-fold of healthy_mask so synthesis preserves the health logic
//
// Resource report = full time-multiplexed 16-ring health monitoring subsystem.
//
// =============================================================================

`timescale 1ns / 1ps

module top_ring_health_mux_synth (
    input  wire clk,         // P6 (25 MHz crystal); nextpnr targets this — IS the fast clock
    input  wire reset_n,     // R7 user button (active-low pull-up)
    output reg  led,         // T6 — toggles per KOHI
    output wire ext_led      // T2 — XOR-fold of healthy_mask
);

    // ---- 16 LFSR drivers, advancing once every 16 fast cycles --------------
    reg  [15:0] lfsr [0:15];
    wire [15:0] lfsr_fb;
    reg  [15:0] ring_sample_latched;
    reg  [3:0]  fast_phase;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_lfsr
            assign lfsr_fb[gi] = lfsr[gi][15] ^ lfsr[gi][13] ^ lfsr[gi][12] ^ lfsr[gi][10];
        end
    endgenerate

    integer li;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (li = 0; li < 16; li = li + 1)
                lfsr[li] <= 16'hACE1 + li[15:0] * 16'h0BAD;
            fast_phase <= 4'd0;
            ring_sample_latched <= 16'd0;
        end else begin
            fast_phase <= fast_phase + 4'd1;
            // advance LFSRs and latch new sample once per slow tick
            if (fast_phase == 4'd15) begin
                for (li = 0; li < 16; li = li + 1)
                    lfsr[li] <= {lfsr[li][14:0], lfsr_fb[li]};
                for (li = 0; li < 16; li = li + 1)
                    ring_sample_latched[li] <= lfsr[li][0];
            end
        end
    end

    // ---- self-restart logic ----------------------------------------------
    reg          start_r;
    reg          started;
    wire         done;
    wire [15:0]  healthy_mask;

    ring_health_mux dut (
        .clk          (clk),
        .reset_n      (reset_n),
        .start        (start_r),
        .ring_sample  (ring_sample_latched),
        .done         (done),
        .healthy_mask (healthy_mask)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            start_r <= 1'b0;
            started <= 1'b0;
            led     <= 1'b1;
        end else begin
            start_r <= 1'b0;
            // align start with phase 0 (when LFSRs just advanced)
            if (!started && fast_phase == 4'd0) begin
                start_r <= 1'b1;
                started <= 1'b1;
            end else if (done) begin
                start_r <= 1'b1;
                led     <= ~led;
            end
        end
    end

    // XOR-fold healthy_mask to one bit
    wire [7:0] xf8 = healthy_mask[15:8] ^ healthy_mask[7:0];
    wire [3:0] xf4 = xf8[7:4]            ^ xf8[3:0];
    wire [1:0] xf2 = xf4[3:2]            ^ xf4[1:0];
    assign ext_led = xf2[1] ^ xf2[0];

endmodule
