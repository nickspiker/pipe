// =============================================================================
// ring_osc.v — Ungoverned ring oscillator (the only clock source in PIPE)
// =============================================================================
//
// Single-inverter ring oscillator with on-chip DCCA buffering.
//
// Loop topology: stage 0 is a NOT (LUT4 INIT=G#5555 → Z=~A); stages 1..N-1 are BUFs (LUT4 INIT=G#AAAA → Z=A). One inversion per loop, so any STAGES ≥ 1 oscillates. Period scales linearly with STAGES — each LUT contributes ~A#340 ps of fabric delay on ECP5 (measured Phase B).
//
// ATTRIBUTES (DO NOT REMOVE):
//   (* keep *) on each LUT4 — prevents yosys from optimizing the buffers away
//                              (Z=A reduces to a wire) or collapsing the loop
//                              to a constant.
//   (* noglobal *) on ring_q — keeps the oscillator loop direct-routed in the
//                              fabric (no DCCA inserted into the loop, which
//                              would slow it by 3-5 ns per insertion).
//
// DISTRIBUTION: clk_out is taken from the loop and routed thru an explicit DCCA primitive onto the global clock network. Without this, fabric routing skew across the chip causes setup/hold violations even at ring frequencies far below silicon Fmax (lesson from Phase D bringup — see commit history).
//
// SIMULATION: this module instantiates ECP5-specific primitives (LUT4, DCCA) that iverilog cannot model. Testbenches must NOT include this module — downstream modules' TBs supply a behavioral clock generator instead. The ring_osc.v itself is validated only on real silicon (Phase B/D measurements).
//
// PHASE D PARAMETERS (per design notes section 3):
//   STAGES = 5    raw ring frequency ≈ 290 MHz on ECP5-25F speed-6
//                 (placement-dependent ±10 MHz observed across seeds)
//   The ring output is divided externally (in top.v) — typically /8 lands
//   enclave_clk near 30-40 MHz, comfortably below blake3's 125 MHz Fmax.
//
// PATENT INVARIANT: this is the ONLY clock-producing module in pipe/rtl/. netlist_assertions.py::test_no_clock_primitives enforces zero EHXPLLL, EHXPLLL_CORE, OSCG, PLLREFCS instances in the synthesized netlist. DCCA is permitted (it's a buffer, not a clock source).
//
// =============================================================================

`timescale 1ns / 1ps

module ring_osc #(
    parameter integer STAGES = 5   // chosen Phase D — see header
) (
    output wire clk_out            // DCCA-buffered, on global clock network
);

    // Internal loop wires — direct-routed (no DCCA inside the loop).
    (* noglobal *) wire [STAGES-1:0] ring_q;

    // Stage 0 — the inverter. LUT4 INIT=h5555 implements Z = ~A.
    (* keep *) LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[STAGES-1]),
        .B(1'b0), .C(1'b0), .D(1'b0),
        .Z(ring_q[0])
    );

    // Stages 1..STAGES-1 — buffers. LUT4 INIT=hAAAA implements Z = A.
    genvar ri;
    generate
        for (ri = 1; ri < STAGES; ri = ri + 1) begin : ring_buf_stage
            (* keep *) LUT4 #(.INIT(16'hAAAA)) ring_buf (
                .A(ring_q[ri - 1]),
                .B(1'b0), .C(1'b0), .D(1'b0),
                .Z(ring_q[ri])
            );
        end
    endgenerate

    // Distribution buffer onto global clock network. Without this, downstream FFs see uncontrolled skew and the design fails far below Fmax.
    DCCA dcca_clk_out (
        .CLKI(ring_q[0]),
        .CE  (1'b1),
        .CLKO(clk_out)
    );

endmodule
