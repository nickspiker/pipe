// =============================================================================
// codec.v — mirror-XOR line-code codec, one side (asymmetric pull-down)
// =============================================================================
//
// Bit-exact silicon implementation of the encode/decode rules in PROTOCOL.md. Parameterized by `OWN_IDLE` so the same module serves both sides:
//   enclave instance: OWN_IDLE = 1
//   host instance:    OWN_IDLE = 0
//
// The wire has an external 5 kΩ pull-down to GND. Neither side ever actively drives LOW — they drive HIGH (overriding the pull-down) or release (HIGH-Z, pull-down wins). drive_en is therefore gated on `my_slot AND wire_out`: drive only when (a) it is our slot, and (b) we are trying to put a 1 on the line.
//
// The codec is clocked at the slot rate (one posedge per bit-time on the wire). On each tick, the caller asserts `my_slot` to indicate whose turn this slot is. When `my_slot = 1` the codec drives the wire (or releases); when `my_slot = 0` it listens and decodes the other side's bit.
//
// Encode (combinational, valid while my_slot = 1):
//   wire_out = OWN_IDLE  XOR  tx_data  XOR  other_last
//   drive_en = my_slot AND wire_out
//
// Decode (registered, fires when my_slot = 0):
//   rx_data  = wire_in  XOR  OTHER_IDLE  XOR  own_last
//
// State (both initialise to 0 at reset):
//   own_last   — last bit this codec transmitted
//   other_last — last bit this codec decoded from the other side
//
// Idle consequences:
//   Enclave (OWN_IDLE=1, tx=0, other_last=0): wire_out=1, drive_en=1 → drives HIGH every even slot. This is the heartbeat.
//   Host (OWN_IDLE=0, tx=0, other_last=0): wire_out=0, drive_en=0 → fully passive, zero current. Pull-down holds odd slots LOW.
// =============================================================================

`timescale 1ns / 1ps

module codec #(
    parameter OWN_IDLE = 1'b1
) (
    input  wire clk,         // slot_clk: one posedge per bit-time
    input  wire reset_n,     // active-low POR
    input  wire my_slot,     // 1 = this slot is ours, 0 = other side's slot

    // TX path (sampled at posedge clk when my_slot == 1)
    input  wire tx_data,

    // RX path
    input  wire wire_in,     // sampled wire value at the slot boundary
    output reg  rx_data,     // decoded other-side bit
    output reg  rx_valid,    // pulse for one slot after a decode

    // Wire driver
    output wire wire_out,    // logical value to put on the line when driving
    output wire drive_en     // 1 = actively drive HIGH; 0 = release (HIGH-Z, pull-down holds line LOW)
);

    localparam OTHER_IDLE = OWN_IDLE ^ 1'b1;

    reg own_last;
    reg other_last;

    // Combinational TX. Valid for the entire slot during which my_slot = 1.
    assign wire_out = OWN_IDLE ^ tx_data ^ other_last;
    // Asymmetric drive: only drive when it's our slot AND we want a HIGH on the wire. Releases (HIGH-Z) otherwise; the external 5kΩ pull-down handles LOW.
    assign drive_en = my_slot && wire_out;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            own_last   <= 1'b0;
            other_last <= 1'b0;
            rx_data    <= 1'b0;
            rx_valid   <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (my_slot) begin
                own_last <= tx_data;
            end else begin
                rx_data    <= wire_in ^ OTHER_IDLE ^ own_last;
                other_last <= wire_in ^ OTHER_IDLE ^ own_last;
                rx_valid   <= 1'b1;
            end
        end
    end

endmodule
