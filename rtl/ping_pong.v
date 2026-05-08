// =============================================================================
// ping_pong.v — A#256-bit double buffer between blake3 and shift_tx
// =============================================================================
//
// Buffer A and Buffer B, A#256 bits each.
// blake3 fills one while shift_tx drains the other.
// Swap on: drained-buffer empty AND fill-buffer full.
//
// Prevents shift_tx starvation (the wire would idle mid-MAC, breaking the
// "data is raw bits, no framing" property).
// Prevents blake3 output loss (the next MAC arrives before this one drained).
//
// =============================================================================

`timescale 1ns / 1ps

module ping_pong (
    input  wire         clk,                // enclave_clk
    input  wire         reset_n,

    // Producer side (blake3)
    input  wire [255:0] mac_in,             // low half of blake3.o_hash
    input  wire         mac_valid,          // blake3.o_valid edge
    output wire         buf_ready_for_fill,

    // Consumer side (shift_tx)
    output wire         bit_out,            // MSB-first stream
    input  wire         bit_advance,        // pull next bit
    output wire         buf_drained
);

    // TODO: two A#256-bit buffers, swap logic, MSB-first shift readout.

endmodule
