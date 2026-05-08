// =============================================================================
// top.v — PIPE top level (single clock domain, single bidirectional IO)
// =============================================================================
//
// External interface:
//   pipe_pad — single bidirectional IO pin (the entire PIPE wire)
//
// No external clock input. No reset input.
// POR comes from ECP5 CFGPOR (config-time POR — not a clock primitive) feeding
// a ring-osc-cycle counter.
//
// Block diagram:
//
//   ring_osc → /N divider → enclave_clk
//
//   enclave_clk drives EVERYTHING: blake3, prng, trng, boot_fsm,
//                                  ping_pong, shift_tx, shift_rx, cdc.
//
//   trng → blake3 (HASH_SEED) → key_register (LOCK_KEY) → blake3.i_chain (forever)
//   prng ─┐
//   shift_rx (challenge) ─┴→ blake3.i_mblock → blake3 → low half → ping_pong
//                                                                    → shift_tx
//   shift_tx ⇄ cdc ⇄ pipe_pad
//
// Hard invariants (netlist_assertions.py):
//   1. test_key_register_fanout       — fanout(key_register.key_out) == 1
//   2. test_no_external_clock         — zero PCLKT pad uses
//   3. test_single_io_pin             — exactly one IO_PORT (pipe_pad)
//   4. test_boot_fsm_trap             — no exit edge from OPERATIONAL
//   5. test_no_clock_primitives       — zero EHXPLLL/EHXPLLL_CORE/OSCG/PLLREFCS
//
// =============================================================================

`timescale 1ns / 1ps

module top #(
    parameter integer RING_STAGES   = 7,   // chosen in Phase D
    parameter integer DIV_BITS      = 2    // enclave_clk = clk_raw / 2^DIV_BITS
) (
    inout wire pipe_pad                    // the wire
);

    // TODO Phase D — wire up:
    //   ring_osc → divider → enclave_clk
    //   POR counter (CFGPOR-derived)
    //   trng / blake3 / key_register / boot_fsm / prng / ping_pong
    //   shift_tx / shift_rx / cdc → pipe_pad

endmodule
