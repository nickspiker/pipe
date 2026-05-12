// =============================================================================
// slot_clk.v — Bit-slot clock generator for the PIPE wire
// =============================================================================
//
// Divides enclave_clk down to slot_rate. One slot = one bit-time on the wire.
// At enclave_clk ≈ 600 kHz and DIV = 12, slot_rate ≈ 50 kbps — slow enough for
// a host-side FT232H bit-bang to oversample cleanly, fast enough that the
// heartbeat is visible on a multimeter / scope without waiting forever.
//
// Outputs:
//   slot_tick   pulses 1 enclave_clk cycle on each slot boundary (the moment
//               at which TX latches new data onto the wire and RX samples).
//   my_slot     alternates each tick (1 = our turn to drive, 0 = listen).
//               POR state: my_slot = OWN_IDLE_FIRST. For the TX-only smoke
//               test we keep my_slot tied high externally so we drive every
//               slot; for full bidir later we let it alternate.
//
// =============================================================================

`timescale 1ns / 1ps

module slot_clk #(
    parameter integer DIV             = 12,    // enclave_clk cycles per slot
    parameter         OWN_IDLE_FIRST  = 1'b1
) (
    input  wire clk,                            // enclave_clk
    input  wire reset_n,
    output reg  slot_tick = 1'b0,
    output reg  my_slot   = OWN_IDLE_FIRST
);

    localparam integer CW = (DIV <= 2) ? 1 : $clog2(DIV);
    reg [CW-1:0] cnt = 0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cnt       <= 0;
            slot_tick <= 1'b0;
            my_slot   <= OWN_IDLE_FIRST;
        end else begin
            slot_tick <= 1'b0;
            if (cnt == DIV - 1) begin
                cnt       <= 0;
                slot_tick <= 1'b1;
                my_slot   <= ~my_slot;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
