// =============================================================================
// top_chaos_amp_v2_synth.v — Fmax bench for chaos_amp_v2.v (Dragonfly v2)
// =============================================================================
//
// Same harness pattern as top_chaos_amp_synth.v (v1) but adapted for the
// v2 module's narrower 384-bit state output and self-restart via state→input
// path. Lets nextpnr time the FF→combinational-round→FF critical path.
//
// Self-restart: at reset, in_data_r = 0 and start fires once. On every
// `done`, we feed state_out (384b) back into in_data_r (512b) — high 128
// bits are kept zero, low 384 from state_out — and re-pulse start.
//
// Outputs:
//   led      — toggles each completed chaos_amp_v2 call (~50 kHz at 50 MHz × 512 cycles)
//   ext_led  — XOR-fold of state_out (toggles every iteration, alive indicator)
//
// =============================================================================

`timescale 1ns / 1ps

module top_chaos_amp_v2_synth (
    input  wire clk,         // P6 (25 MHz crystal); nextpnr targets this
    input  wire reset_n,     // R7 user button (active-low pull-up)
    output reg  led,         // T6 (active-low) — toggles each completed call
    output wire ext_led      // T2 — state_out XOR fold
);

    reg  [511:0] in_data_r = 512'd0;
    reg          start_r   = 1'b0;
    reg          started   = 1'b0;
    wire [383:0] state_out;
    wire         done;

    chaos_amp_v2 dut (
        .clk       (clk),
        .reset_n   (reset_n),
        .start     (start_r),
        .in_data   (in_data_r),
        .state_out (state_out),
        .done      (done)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            start_r   <= 1'b0;
            started   <= 1'b0;
            in_data_r <= 512'd0;
            led       <= 1'b1;
        end else begin
            start_r <= 1'b0;
            if (!started) begin
                start_r <= 1'b1;
                started <= 1'b1;
            end else if (done) begin
                start_r   <= 1'b1;
                in_data_r <= {128'd0, state_out};
                led       <= ~led;
            end
        end
    end

    // XOR-fold state_out → 1 bit, drive to ext_led so synthesis can't
    // optimise state_out away.
    wire [191:0] xf192 = state_out[383:192] ^ state_out[191:0];
    wire [ 95:0] xf96  = xf192[191:96]      ^ xf192[95:0];
    wire [ 47:0] xf48  = xf96[95:48]        ^ xf96[47:0];
    wire [ 23:0] xf24  = xf48[47:24]        ^ xf48[23:0];
    wire [ 11:0] xf12  = xf24[23:12]        ^ xf24[11:0];
    wire [  5:0] xf6   = xf12[11:6]         ^ xf12[5:0];
    wire [  2:0] xf3   = xf6[5:3]           ^ xf6[2:0];
    assign ext_led = xf3[2] ^ xf3[1] ^ xf3[0];

endmodule
