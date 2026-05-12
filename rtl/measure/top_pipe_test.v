// =============================================================================
// top_pipe_test.v — TX-only wire smoke test
// =============================================================================
//
// Minimum viable "is the wire alive" experiment. The enclave drives the
// PIPE pad with a 1010 square wave at the slot rate. No codec, no listen
// path yet — just enough to verify the pad+slot_clk+wire_io chain produces
// a clean signal a host can sample.
//
// Clock source: same ring oscillator + mod-N divider used in the DUT
// bench, so the wire bit rate tracks the actual production sys_clk
// (≈600 kHz / DIV_SLOT). At DIV_SLOT = 12 the wire toggles at ~25 kHz
// (one full period per 2 slots).
//
// Defines (set by build script):
//   RING_STAGES   — ring-osc stage count (required)
//   RING_DIV      — modulo-N divider on the ring (required)
//   SLOT_DIV      — enclave_clk cycles per slot (default 12)
//
// =============================================================================

`timescale 1ns / 1ps

`ifndef RING_STAGES
`define RING_STAGES 5
`endif
`ifndef RING_DIV
`define RING_DIV 512
`endif
`ifndef SLOT_DIV
`define SLOT_DIV 12
`endif

module top_pipe_test (
    inout  wire pipe_pad,    // the wire
    output wire led          // T6 liveness — toggles at slot rate / 4096
);

    // -------------------------------------------------------------------------
    // Ring oscillator → DCCA → mod-N counter → DCCA → enclave_clk
    // -------------------------------------------------------------------------
    (* noglobal *) wire [`RING_STAGES-1:0] ring_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[`RING_STAGES-1]), .B(1'b0), .C(1'b0), .D(1'b0),
        .Z(ring_q[0])
    );
    genvar ri;
    generate
        for (ri = 1; ri < `RING_STAGES; ri = ri + 1) begin : ring_buf_stage
            (* keep *) LUT4 #(.INIT(16'hAAAA)) ring_buf (
                .A(ring_q[ri - 1]), .B(1'b0), .C(1'b0), .D(1'b0),
                .Z(ring_q[ri])
            );
        end
    endgenerate

    wire ring_raw;
    (* keep *) DCCA dcca_ring_raw (.CLKI(ring_q[0]), .CE(1'b1), .CLKO(ring_raw));

    localparam integer DIV_HALF = (`RING_DIV >> 1);
    localparam integer DIV_W    = ($clog2(DIV_HALF) > 0) ? $clog2(DIV_HALF) : 1;
    reg [DIV_W-1:0] ring_div_cnt = 0;
    reg             ring_div_out = 0;
    always @(posedge ring_raw) begin
        if (ring_div_cnt == (DIV_HALF - 1)) begin
            ring_div_cnt <= 0;
            ring_div_out <= ~ring_div_out;
        end else begin
            ring_div_cnt <= ring_div_cnt + 1'b1;
        end
    end

    wire enclave_clk;
    (* keep *) DCCA dcca_enclave_clk (.CLKI(ring_div_out), .CE(1'b1), .CLKO(enclave_clk));

    // -------------------------------------------------------------------------
    // Power-on reset — count enclave_clk cycles after start.
    // -------------------------------------------------------------------------
    reg [3:0] por_cnt = 0;
    wire      por_done = &por_cnt;
    wire      reset_n  = por_done;
    always @(posedge enclave_clk) if (!por_done) por_cnt <= por_cnt + 1'b1;

    // -------------------------------------------------------------------------
    // Slot clock — divide enclave_clk by SLOT_DIV. slot_tick fires once per
    // slot; we use it to toggle tx_bit (the data we drive onto the wire) so
    // the wire alternates 1010 at slot_rate / 2.
    // -------------------------------------------------------------------------
    wire slot_tick;
    wire slot_my_slot_unused;  // not used in TX-only mode
    slot_clk #(.DIV(`SLOT_DIV)) slot (
        .clk       (enclave_clk),
        .reset_n   (reset_n),
        .slot_tick (slot_tick),
        .my_slot   (slot_my_slot_unused)
    );

    reg tx_bit = 1'b0;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n)        tx_bit <= 1'b0;
        else if (slot_tick)  tx_bit <= ~tx_bit;
    end

    // -------------------------------------------------------------------------
    // Wire — drive always (TX-only), output = tx_bit.
    // -------------------------------------------------------------------------
    wire wire_in_unused;
    wire_io io (
        .clk      (enclave_clk),
        .reset_n  (reset_n),
        .drive_en (1'b1),
        .wire_out (tx_bit),
        .wire_in  (wire_in_unused),
        .pad      (pipe_pad)
    );

    // -------------------------------------------------------------------------
    // LED liveness — divide slot_tick by 4096 for a visible blink. At
    // ~50 kbps slot rate, 4096-slot period = ~80 ms = ~12 Hz LED flicker.
    // -------------------------------------------------------------------------
    reg [11:0] led_cnt = 0;
    reg        led_reg = 1'b1;     // T6 is active-low; start "off"
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n) begin
            led_cnt <= 0;
            led_reg <= 1'b1;
        end else if (slot_tick) begin
            led_cnt <= led_cnt + 1'b1;
            if (&led_cnt) led_reg <= ~led_reg;
        end
    end
    assign led = led_reg;

endmodule
