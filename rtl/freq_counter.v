// =============================================================================
// freq_counter.v — measure meas_clk frequency in Hz using ref_clk as reference
// =============================================================================
//
// Counts rising edges of `meas_clk` over a window of `WINDOW_REF_CYCLES` cycles of `ref_clk`. After each window, latches `freq_hz = edge_count × MAGIC` and pulses `freq_valid` for one ref_clk cycle. The host can configure the window so that `MAGIC = 1 / window_seconds` is a clean integer.
//
// Default: 5,000,000 cycles of a 25 MHz reference → 200 ms window → MAGIC = 5, resolution ±5 Hz (= ±1 edge / 0.2 s). At the project's nominal enclave_clk ≈ 600 kHz this is ~0.001% precision — far below the ring oscillator's PVT drift.
//
// Cross-domain capture: a toggle FF on meas_clk side, 2-FF synchronizer into ref_clk domain. XOR of the last two sync stages pulses once per meas_clk rising edge.
// =============================================================================

`timescale 1ns / 1ps

module freq_counter #(
    parameter integer WINDOW_REF_CYCLES = 5_000_000,  // 200 ms at 25 MHz ref
    parameter integer MAGIC              = 5,         // 1 / window_seconds
    parameter integer EDGE_W             = 23,        // bits for edge_cnt — enough for ~16 MHz meas_clk over 200 ms
    parameter integer REF_W              = 23         // bits for ref_cnt   — enough for the window above
)(
    input  wire ref_clk,
    input  wire meas_clk,
    input  wire reset_n,
    output reg  [31:0] freq_hz,
    output reg         freq_valid
);

    // Toggle FF on meas_clk side.
    reg meas_toggle = 1'b0;
    always @(posedge meas_clk or negedge reset_n) begin
        if (!reset_n) meas_toggle <= 1'b0;
        else          meas_toggle <= ~meas_toggle;
    end

    // 2-FF synchronizer (plus one stage for edge XOR) into ref_clk domain.
    reg [2:0] toggle_sync = 3'b000;
    always @(posedge ref_clk or negedge reset_n) begin
        if (!reset_n) toggle_sync <= 3'b000;
        else          toggle_sync <= {toggle_sync[1:0], meas_toggle};
    end

    wire meas_edge = toggle_sync[2] ^ toggle_sync[1]; // pulses once per meas_clk rising edge

    reg [REF_W-1:0]  ref_cnt  = 0;
    reg [EDGE_W-1:0] edge_cnt = 0;

    always @(posedge ref_clk or negedge reset_n) begin
        if (!reset_n) begin
            ref_cnt    <= 0;
            edge_cnt   <= 0;
            freq_hz    <= 32'd0;
            freq_valid <= 1'b0;
        end else begin
            freq_valid <= 1'b0;
            if (ref_cnt == WINDOW_REF_CYCLES - 1) begin
                freq_hz    <= edge_cnt * MAGIC;
                ref_cnt    <= 0;
                edge_cnt   <= meas_edge ? 1 : 0;  // carry the edge that landed on this very cycle
                freq_valid <= 1'b1;
            end else begin
                ref_cnt <= ref_cnt + 1;
                if (meas_edge) edge_cnt <= edge_cnt + 1;
            end
        end
    end

endmodule
