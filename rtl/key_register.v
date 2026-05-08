// =============================================================================
// key_register.v — A#256-bit write-once secret store
// =============================================================================
//
// Writeable EXACTLY ONCE per power-on, by boot_fsm.v only.
// Output port connects to blake3.i_chain. NO other consumer.
//
// Hard invariants enforced by netlist_assertions.py::test_key_register_fanout:
//   - register output net has fanout == 1
//   - the single sink is blake3 (any instance) i_chain port
//   - no path from register output to any IOB
//   - no path from register output to any RAM/ROM/FIFO
//
// `locked` flag is irreversible: once set, write-enable is permanently masked.
// The only way to clear `locked` is full power cycle (the register itself loses
// state on power loss; there is no soft-reset path).
//
// =============================================================================

`timescale 1ns / 1ps

module key_register (
    input  wire         clk,                // enclave_clk
    input  wire         reset_n,            // active-low async reset (POR only)

    input  wire [255:0] key_in,             // from blake3 (entropy → seed)
    input  wire         write_strobe,       // from boot_fsm (S_LOCK_KEY)
    output wire         locked,             // irreversibly high after first write

    output wire [255:0] key_out             // FANOUT==1 → blake3.i_chain
);

    // TODO: 256b register, write-once enforcement, locked flag.

endmodule
