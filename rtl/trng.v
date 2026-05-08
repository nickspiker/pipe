// =============================================================================
// trng.v — Entropy accumulator for the boot secret
// =============================================================================
//
// Two ring oscillators at different frequencies (different STAGES counts).
// Fast ring sampled by slow ring → jitter bits. A#256-bit shift register
// accumulates samples until full, then strobes `entropy_full`.
//
// The 256 bits feed blake3 in keyed-hash mode to derive the boot secret which
// is locked into key_register (one-way, irreversible).
//
// Reference: spirix/fpga/bench/top_trng.v (8192-loop ring oscillator TRNG with
// OLED bitmap visualization of jitter).
//
// =============================================================================

`timescale 1ns / 1ps

module trng (
    input  wire         clk,            // enclave_clk (slow ring divided)
    input  wire         reset_n,        // active-low async reset

    output wire [255:0] entropy,        // accumulated entropy bits
    output wire         entropy_full    // strobe: 256 bits ready
);

    // TODO: dual ring oscillators (fast + slow), shift register accumulator,
    // full flag → boot_fsm.

endmodule
