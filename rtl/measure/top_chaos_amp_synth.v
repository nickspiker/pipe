// =============================================================================
// top_chaos_amp_synth.v — minimal Fmax bench for chaos_amp.v
// =============================================================================
//
// Wraps chaos_amp in a self-restarting feedback loop so nextpnr can time the
// internal FF→combinational→FF critical path. The harness is intentionally
// thin — no OLED, no I2C, no PRBS source — so chaos_amp's logic dominates
// utilisation and the reported max-frequency reflects the chaos_amp critical
// path almost exclusively.
//
// Self-restart: at reset, in_data_r = 0 and start fires once. On every
// `done`, we feed state_out back into in_data_r and pulse start again.
// chaos_amp runs back-to-back forever; the critical path inside it is
// continuously exercised.
//
// Outputs:
//   led      — bright while chaos_amp is mid-round, dim during done pulse
//   ext_led  — XOR of state_out (toggles every iteration, "alive" indicator)
//
// Usage from scripts/build_chaos_amp_synth.sh:
//   read_verilog rtl/chaos_amp.v rtl/measure/top_chaos_amp_synth.v
//   synth_ecp5 -nowidelut -abc2 -top top_chaos_amp_synth -json out.json
//   nextpnr-ecp5 --25k --package CABGA256 --speed 6 --lpf chaos_amp_synth.lpf
//
// =============================================================================

`timescale 1ns / 1ps

module top_chaos_amp_synth (
    input  wire clk,         // P6 (25 MHz crystal); nextpnr targets this
    input  wire reset_n,     // R7 user button (active-low pull-up)
    output reg  led,         // T6 (active-low) — done indicator
    output wire ext_led      // T2 — state_out XOR fold, toggles each iteration
);

    reg  [511:0] in_data_r = 512'd0;
    reg          start_r   = 1'b0;
    reg          started   = 1'b0;
    wire [511:0] state_out;
    wire         done;

    chaos_amp dut (
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
                in_data_r <= state_out;
                led       <= ~led;
            end
        end
    end

    // XOR-fold state_out → 1 bit, drive to ext_led so synthesis can't optimise
    // state_out away.
    wire [255:0] xf256 = state_out[511:256] ^ state_out[255:0];
    wire [127:0] xf128 = xf256[255:128] ^ xf256[127:0];
    wire [ 63:0] xf64  = xf128[127:64]  ^ xf128[63:0];
    wire [ 31:0] xf32  = xf64[63:32]    ^ xf64[31:0];
    wire [ 15:0] xf16  = xf32[31:16]    ^ xf32[15:0];
    wire [  7:0] xf8   = xf16[15:8]     ^ xf16[7:0];
    wire [  3:0] xf4   = xf8[7:4]       ^ xf8[3:0];
    wire [  1:0] xf2   = xf4[3:2]       ^ xf4[1:0];
    assign ext_led = xf2[1] ^ xf2[0];

endmodule
