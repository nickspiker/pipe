// =============================================================================
// key_register.v — A#256-bit write-once secret store
// =============================================================================
//
// Holds the boot-derived attestation secret. Written EXACTLY ONCE per power-on
// by boot_fsm.v during the LOCK_KEY transition. After lock asserts, no further
// writes are accepted — the only way to clear the lock is full power loss
// (the register itself loses state on power loss; there is no soft reset).
//
// The output port `key_out` connects to blake3.i_chain ONLY. No other consumer
// in the netlist. This is the structural foundation of the unextractability
// claim: the secret has no path to any IO pin, data bus, RAM, or multiplexer.
//
// HARD INVARIANTS (enforced by netlist_assertions.py after synthesis):
//   1. fanout(key_register.key_out) == 1
//   2. the single sink is blake3.i_chain (any blake3 instance)
//   3. no path from key_out to any IOB or RAM
//
// SYNTHESIS CONSTRAINT (apply in build_pipe.sh / .lpf):
//   set_false_path -from [get_cells key_register/key*] -to [get_ports *]
//
// SELF-REFERENTIAL PROTECTION (per design notes section 10):
//   The key register's address falls outside all valid process regions.
//   Two independent protections: (1) no wire from key register to data bus
//   exists in netlist, (2) key register address is outside valid bounds.
//   Neither depends on the other.
//
// RESET BEHAVIOR:
//   reset_n is for power-on reset only (CFGPOR-derived). When reset_n is low
//   (POR active), key and locked are cleared. After POR releases, the register
//   is empty and unlocked, ready for the boot FSM's single write.
//
// =============================================================================

`timescale 1ns / 1ps

module key_register (
    input  wire         clk,            // enclave_clk
    input  wire         reset_n,        // active-low POR (CFGPOR + counter)

    // Write port (boot_fsm only; ignored after lock)
    input  wire [255:0] key_in,         // from blake3 (HASH_SEED output)
    input  wire         write_strobe,   // boot_fsm S_LOCK_KEY pulse

    // Status
    output wire         locked,         // irreversibly high after first write

    // Output port (FANOUT==1 → blake3.i_chain ONLY)
    output wire [255:0] key_out
);

    reg [255:0] key;
    reg         locked_r;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key      <= 256'b0;
            locked_r <= 1'b0;
        end else if (write_strobe && !locked_r) begin
            key      <= key_in;
            locked_r <= 1'b1;
        end
        // After locked_r is set, no further writes accepted.
        // No path to clear locked_r short of POR.
    end

    assign key_out = key;
    assign locked  = locked_r;

endmodule
