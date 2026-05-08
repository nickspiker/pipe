// =============================================================================
// prng.v — ChaCha20 nonce generator
// =============================================================================
//
// Key:   derived from boot secret (NOT the secret itself — secret stays in
//        key_register and only goes to blake3.i_chain).
// Nonce: monotonically increasing 64-bit request counter; never reuses.
//
// Output feeds:
//   - blake3.i_mblock (concat with host challenge bits in shift_rx)
//   - shift_tx idle-fill randomness (so the wire never sits at a fixed value)
//
// IP selection (Secworks ChaCha20 vs custom) deferred to module pass.
//
// =============================================================================

`timescale 1ns / 1ps

module prng (
    input  wire         clk,                    // enclave_clk
    input  wire         reset_n,                // active-low async reset

    input  wire [255:0] seed,                   // boot-secret-derived key material
    input  wire         seed_strobe,            // boot_fsm S_SEED_PRNG

    output wire         ready,                  // post-seed, can produce blocks

    input  wire         block_request,
    output wire [511:0] block_out,
    output wire         block_valid
);

    // TODO: ChaCha20 core, 64b nonce counter (no rollover allowed in lifetime).

endmodule
