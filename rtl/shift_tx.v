// =============================================================================
// shift_tx.v — Serializer with idle heartbeat and TX initiate bit
// =============================================================================
//
// Idle:    continuous 1010 pattern on the IO pin (heartbeat).
// TX init: emit an unexpected 1 where 0 was expected (or vice versa).
// Active:  raw MAC bits, no encoding, no framing — output of ping_pong.
//
// Watches the line for HOST init (unexpected 0 from the host's perspective —
// detected via shift_rx). If host init arrives BEFORE we've sent our own,
// defer to listen mode. One-bit handshake; collision is impossible because
// both sides are always watching.
//
// =============================================================================

`timescale 1ns / 1ps

module shift_tx (
    input  wire         clk,                // enclave_clk
    input  wire         reset_n,
    input  wire         operational,        // boot_fsm gates idle output

    // From ping_pong
    input  wire         bit_in,
    output wire         bit_advance,
    input  wire         buf_drained,

    // To IO pin (when in TX direction)
    output wire         tx_data,
    output wire         tx_drive_enable,    // half-duplex direction control

    // From shift_rx
    input  wire         host_init_detected, // defer if true

    // Internal status
    output wire         tx_active
);

    // TODO: idle heartbeat counter, init-bit FSM, MSB-first shift, host-defer.

endmodule
