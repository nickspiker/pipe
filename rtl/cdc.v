// =============================================================================
// cdc.v — Half-duplex bidirectional IO with 2-flop synchronizer
// =============================================================================
//
// Single bidirectional pin connecting enclave to host.
//
// Inside the enclave there is ONE clock domain (enclave_clk). The host runs on
// its own (uncorrelated) clock. The IO pin is async data, not a clock.
// This module is a 2-flop synchronizer for the RX path; the TX path drives
// directly because it's already in the enclave_clk domain.
//
// Direction is controlled by shift_tx/shift_rx state via tx_drive_enable.
// Half-duplex: tx_drive_enable=1 means we drive; =0 means we listen.
//
// =============================================================================

`timescale 1ns / 1ps

module cdc (
    input  wire clk,                    // enclave_clk
    input  wire reset_n,

    inout  wire pad,                    // bidirectional IO pad

    // TX side (drive)
    input  wire tx_data,                // from shift_tx
    input  wire tx_drive_enable,        // from shift_tx (half-duplex direction)

    // RX side (sample, synchronized)
    output wire rx_data_sync            // to shift_rx (already in enclave_clk)
);

    // TODO: tristate driver, 2-flop synchronizer for rx path.

endmodule
