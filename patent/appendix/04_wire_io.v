// ============================================================================
// wire_io.v -- Bidirectional channel port driver + input synchronizer
// ============================================================================
//
// Wraps the single bidirectional channel port.
// In an electrical embodiment (depicted here), the port is a tristate input/output pin coupled to a single conductor with an external asymmetric pull-down to ground.
// In alternative embodiments the port couples to an optical fiber via a paired emitter and detector, to a magnetic coupling coil, or to any other bidirectional coupling structure satisfying the asymmetric-drive requirement of the mirror-XOR line code.
//
// The input path is synchronized thru two flip-flops into the receiving clock domain.
// The two endpoints share no clock; every received bit crosses a domain boundary and must be synchronized to avoid metastability propagating into the decode logic.
//
// SYNTHESIS NOTE: the tristate behaviour is depicted here as a behavioural `assign pad = drive_en ? wire_out : 1'bz;` for portability.
// Production synthesis tools may infer this onto a vendor-specific bidirectional buffer primitive; the depicted form does not limit the claim to any particular vendor primitive.
//
// ============================================================================

`timescale 1ns / 1ps

module wire_io (
    input  wire clk,
    input  wire reset_n,
    input  wire drive_en,
    input  wire wire_out,
    output wire wire_in,
    inout  wire pad
);

    // Tristate driver. drive_en = 1 actively drives the pad with wire_out; drive_en = 0 releases the pad (high impedance), and the external asymmetric pull-down holds the channel at its idle state.
    assign pad = drive_en ? wire_out : 1'bz;

    // Two-flip-flop synchronizer crossing the externally-driven pad value into the local clock domain.
    reg [1:0] in_sync;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) in_sync <= 2'b00;
        else          in_sync <= {in_sync[0], pad};
    end
    assign wire_in = in_sync[1];

endmodule
