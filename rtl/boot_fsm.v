// =============================================================================
// boot_fsm.v — One-way boot sequence to OPERATIONAL trap state
// =============================================================================
//
// State chart:
//
//   WAIT_ENTROPY ──[trng.entropy_full]──▶ HASH_SEED
//   HASH_SEED    ──[blake3.o_valid]────▶ LOCK_KEY
//   LOCK_KEY     ──[key_register.locked]▶ SEED_PRNG
//   SEED_PRNG    ──[prng.ready]─────────▶ OPERATIONAL ⟲ (trap)
//
// OPERATIONAL is a trap state — no transition out. Only power cycle clears it.
//
// Hard invariant enforced by netlist_assertions.py::test_boot_fsm_trap:
//   - no transitions where from_state == OPERATIONAL
//
// =============================================================================

`timescale 1ns / 1ps

module boot_fsm (
    input  wire clk,                // enclave_clk
    input  wire reset_n,            // active-low async reset (POR only)

    // From trng
    input  wire entropy_full,
    // From blake3 (driven during HASH_SEED)
    input  wire blake3_valid,
    output wire blake3_strobe,
    // From key_register
    input  wire key_locked,
    output wire key_write_strobe,
    // From prng
    input  wire prng_ready,
    output wire prng_seed_strobe,

    // Status
    output wire operational         // high once boot complete (latched)
);

    // TODO: 5-state one-way FSM; OPERATIONAL has no exit edge.

endmodule
