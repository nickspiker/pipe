// =============================================================================
// shift_rx.v — Deserializer with CDR and RX initiate detection
// =============================================================================
//
// 8x oversampling off enclave_clk.
// Early/late phase detector → proportional CDR with gain 1/16.
// Lock acquisition target: ≤ A#8 bit periods from idle pattern.
// Steady-state drift margin: A#125:1 against worst-case PVT.
//
// Detects host init: an unexpected 0 in the heartbeat pattern.
//
// Deserializes incoming challenge bits into blake3.i_mblock buffer (MSB-first),
// then strobes blake3.i_valid when the message is complete (counter check).
//
// =============================================================================

`timescale 1ns / 1ps

module shift_rx (
    input  wire         clk,                // enclave_clk (≥ 8× bit rate)
    input  wire         reset_n,

    // From IO pin (when in RX direction)
    input  wire         rx_data_async,      // async — synchronize via cdc.v

    // Init detection (gates shift_tx.host_init_detected)
    output wire         host_init_detected,

    // Challenge buffer to blake3
    output wire [511:0] challenge_block,
    output wire         challenge_valid,    // strobe → blake3.i_valid

    // Status
    output wire         locked              // CDR has lock
);

    // TODO: 8x oversample, early/late PD, proportional CDR, init detector,
    // A#512-bit shift register for challenge accumulation.

endmodule
