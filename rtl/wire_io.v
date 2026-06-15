// =============================================================================
// wire_io.v — Bidirectional pad driver + 2-FF input synchronizer
// =============================================================================
//
// Wraps the single PIPE pad. Registered tristate enable + drive value, 2-FF sync on the input path (no async wire entering the enclave domain). The input synchronizer is needed even when the other side is locally clocked (host) because they share no clock — every received bit crosses a domain boundary.
//
// The `inout` is driven via an explicit BB (bidirectional buffer) primitive rather than relying on the synthesizer to infer it from `assign pad = en ? out : 1'bz`. The explicit form makes the netlist auditable (test_single_io_pin in netlist_assertions.py expects exactly one BB).
//
// For the TX-only smoke test, drive_en is held high and wire_in is unused (the host doesn't drive). For full bidir we let drive_en toggle with the slot ownership.
//
// =============================================================================

`timescale 1ns / 1ps

module wire_io (
    input  wire clk,                // enclave_clk (for the input sync FFs)
    input  wire reset_n,
    input  wire drive_en,           // 1 = drive pad with wire_out, 0 = tristate
    input  wire wire_out,           // value to drive when drive_en = 1
    output wire wire_in,            // sampled+synchronized pad input
    inout  wire pad                 // the wire (physical pin)
);

    // Bidirectional buffer. BB is the ECP5 inout primitive Trellis recognizes. T = tristate enable, ACTIVE LOW (T=0 → drive, T=1 → tristate).
    wire pad_raw;
    BB pad_bb (
        .I(wire_out),
        .T(~drive_en),
        .O(pad_raw),
        .B(pad)
    );

    // 2-FF synchronizer: every external wire value must cross into the enclave_clk domain thru 2 FFs before any combinational use.
    reg [1:0] in_sync = 2'b00;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) in_sync <= 2'b00;
        else          in_sync <= {in_sync[0], pad_raw};
    end
    assign wire_in = in_sync[1];

endmodule
