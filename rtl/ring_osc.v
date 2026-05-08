// =============================================================================
// ring_osc.v — Ungoverned ring oscillator (the only clock source in PIPE)
// =============================================================================
//
// Single-inverter topology: stage 0 is a NOT (LUT4 INIT=G#5555 → Z=~A);
// stages 1..N-1 are BUFs (LUT4 INIT=G#AAAA → Z=A). One inversion per loop,
// so any N ≥ 1 oscillates regardless of parity. Period scales linearly with
// N — each LUT contributes ~A#340 ps of fabric delay on ECP5.
//
// (* keep *) on every LUT4 prevents yosys from optimizing the BUFs away
// (Z = A reduces to a wire) or collapsing the loop to a constant.
// (* noglobal *) on ring_q wires keeps the oscillator loop direct-routed
// through the LUT fabric (no DCCA buffer inserted, which would slow the
// loop by 3-5 ns per insertion).
//
// CRITICAL: clk_raw is direct-routed through fabric. It must NOT be used
// to clock more than a few flip-flops. For distributing the clock to the
// rest of the enclave (blake3, FSM, accumulators, ~thousands of FFs), an
// explicit DCCA buffer must be instantiated downstream — see top.v's
// enclave_clk distribution. Without that buffer, fabric routing skew across
// the chip causes setup/hold violations even at frequencies far below
// silicon Fmax (lesson learned during Phase D bringup on the spirix harness).
//
// Stage count is chosen during Phase D from Phase B (ring frequency vs N
// curve) and Phase C (blake3 silicon Fmax) measurements. Current data:
//   Phase B: 32 stages = 46.22 MHz on ECP5-25F speed-6 (Colorlight 5A-75B v8)
//   Phase C: blake3 stable Fmax = 125 MHz, marginal = 131 MHz
// Combined: 12 stages (~123 MHz) is the empirical max before blake3 fails;
// for production we want comfortable margin (e.g., 5 stages + /N divider —
// see ring sizing decision in PIPE.md / phase_d_results.csv).
//
// Hard rule: this module is the ONLY clock-producing module in pipe/rtl/.
// netlist_assertions.py::test_no_clock_primitives enforces zero EHXPLLL,
// EHXPLLL_CORE, OSCG, PLLREFCS instances in the synthesized netlist.
//
// =============================================================================

`timescale 1ns / 1ps

module ring_osc #(
    parameter integer STAGES = 5   // chosen in Phase D — see header above
) (
    output wire clk_raw            // raw ring oscillator output (DIRECT-ROUTED;
                                   // must be DCCA-buffered downstream before
                                   // driving multi-FF loads — see top.v)
);

    (* noglobal *) wire [STAGES-1:0] ring_q;

    (* keep *) LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[STAGES-1]),
        .B(1'b0), .C(1'b0), .D(1'b0),
        .Z(ring_q[0])
    );

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

    assign clk_raw = ring_q[0];

endmodule
