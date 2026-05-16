// =============================================================================
// top_ring_health_synth.v — Fmax bench for ring_health.v (Claim 3c)
// =============================================================================
//
// Wraps a single ring_health instance in a self-restart harness so nextpnr can
// time the critical path through RCT + APT + iterated-diff popcount counters.
// Sample input is the LSB of a 16-bit Fibonacci LFSR that advances every cycle,
// providing pseudorandom-but-deterministic input that the synthesis tool
// cannot reduce to a constant.
//
// Outputs:
//   led      — toggles each completed gather (~1.5 kHz at 100 MHz, since each
//              gather is ~W=65536 cycles)
//   ext_led  — `healthy` output, asserted while last gather's verdict held
//
// Resource report = per-ring health-monitor cost. Multiply by 16 to estimate
// the cost of N=16 rings in trng.v.
//
// =============================================================================

`timescale 1ns / 1ps

module top_ring_health_synth (
    input  wire clk,         // P6 (25 MHz crystal); nextpnr targets this
    input  wire reset_n,     // R7 user button (active-low pull-up)
    output reg  led,         // T6 (active-low) — toggles each gather
    output wire ext_led      // T2 — `healthy` from last completed gather
);

    // ---- pseudorandom sample driver ---------------------------------------
    reg  [15:0] lfsr;
    wire        lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    // ---- self-restart logic -----------------------------------------------
    reg         start_r;
    reg         started;
    wire        done;
    wire        healthy;

    ring_health dut (
        .clk     (clk),
        .reset_n (reset_n),
        .start   (start_r),
        .sample  (lfsr[0]),
        .done    (done),
        .healthy (healthy)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            lfsr    <= 16'hACE1;
            start_r <= 1'b0;
            started <= 1'b0;
            led     <= 1'b1;
        end else begin
            // advance LFSR every cycle so `sample` keeps changing
            lfsr <= {lfsr[14:0], lfsr_fb};

            start_r <= 1'b0;
            if (!started) begin
                start_r <= 1'b1;
                started <= 1'b1;
            end else if (done) begin
                start_r <= 1'b1;
                led     <= ~led;
            end
        end
    end

    assign ext_led = healthy;

endmodule
