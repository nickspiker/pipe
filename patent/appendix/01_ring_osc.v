// ============================================================================
// ring_osc.v -- Ring oscillator (the only clock source in the device)
// ============================================================================
//
// Single-inversion ring oscillator.
// Stage 0 is a logical inverter; stages 1..STAGES-1 are logical buffers.
// One inversion per loop -- any STAGES >= 1 oscillates.
// Period scales linearly with STAGES; each gate contributes a process-, voltage-, and temperature-dependent delay characteristic of the underlying silicon technology, ensuring that the ring frequency is not reproducible across manufactured instances and that the per-cycle sample the noise-detection circuitry captures includes a contribution from transient environmental physics (thermal noise, shot noise, voltage and temperature drift) at the moment of sampling.
//
// SYNTHESIS NOTE: the `keep` attribute on each loop wire prevents logic optimization from collapsing the buffers (Z = A reduces to a wire) or reducing the loop to a constant.
// Equivalent attributes exist in every production synthesis tool flow; the specific attribute syntax depicted is non-limiting.
//
// PATENT INVARIANT: this module is the sole clock-producing module in the device.
// No phase-locked loop, no external crystal oscillator, no vendor-supplied clock primitive, and no externally accessible clock input is present anywhere in the chip-side implementation.
//
// ============================================================================

`timescale 1ns / 1ps

module ring_osc #(
    parameter integer STAGES = 5
) (
    output wire clk_out
);

    (* keep = "true" *) wire [STAGES-1:0] ring_q;

    // Stage 0 is the inverter.
    assign ring_q[0] = ~ring_q[STAGES-1];

    // Stages 1..STAGES-1 are buffers.
    genvar ri;
    generate
        for (ri = 1; ri < STAGES; ri = ri + 1) begin : ring_buf_stage
            assign ring_q[ri] = ring_q[ri - 1];
        end
    endgenerate

    assign clk_out = ring_q[0];

endmodule
