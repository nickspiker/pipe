// =============================================================================
// top_pipe_latch.v — Wire latch for bidirectional smoke test
// =============================================================================
//
// The FPGA drives the wire with a 1-bit "latched" register most of the time;
// every 256 enclave_clk cycles it tristates for one cycle to sample what the
// wire actually looks like, and updates the latch from that sample. The
// 400 Ω series resistor is on the FPGA side, so when the FPGA is driving its
// own pin sits at the driven voltage regardless of what the host does on the
// other end of the resistor — only the brief tristate window exposes the
// wire's true voltage to the input buffer.
//
// Behaviour as observed by the host:
//   • At rest, the wire holds the last sampled value (high or low).
//   • Drive the wire HIGH for > ~430 µs, release: the wire stays HIGH.
//   • Drive LOW for > ~430 µs, release: the wire stays LOW.
//
// LED on T6 mirrors the latched bit (active-low: bright when bit = 0).
//
// =============================================================================

`timescale 1ns / 1ps

`ifndef RING_STAGES
`define RING_STAGES 5
`endif
`ifndef RING_DIV
`define RING_DIV 512
`endif
`ifndef SAMPLE_PERIOD
`define SAMPLE_PERIOD 256   // enclave_clk cycles between tristate-samples
`endif

module top_pipe_latch (
    inout  wire pipe_pad,
    output wire led
);

    // -------------------------------------------------------------------------
    // Ring oscillator → mod-N divider → enclave_clk  (same as top_pipe_test.v)
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
    // POR
    // -------------------------------------------------------------------------
    reg [3:0] por_cnt = 0;
    wire      por_done = &por_cnt;
    wire      reset_n  = por_done;
    always @(posedge enclave_clk) if (!por_done) por_cnt <= por_cnt + 1'b1;

    // -------------------------------------------------------------------------
    // Sample-phase scheduler. Tristate for 8 cycles (≈13 µs at 600 kHz),
    // latch on cycle 7, then drive for the remaining (SAMPLE_PERIOD - 8)
    // cycles. The long tristate gives the pad time to settle and the input
    // synchronizer two clean cycles to propagate the external voltage.
    // -------------------------------------------------------------------------
    localparam integer CNT_W = $clog2(`SAMPLE_PERIOD);
    localparam integer SAMPLE_WIDE = 8;
    localparam integer LATCH_AT = SAMPLE_WIDE - 1; // 7

    reg [CNT_W-1:0] sample_cnt = 0;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n) sample_cnt <= 0;
        else if (sample_cnt == (`SAMPLE_PERIOD - 1)) sample_cnt <= 0;
        else sample_cnt <= sample_cnt + 1'b1;
    end

    // Drive disabled during cycles 0..SAMPLE_WIDE-1.
    wire drive_en = (sample_cnt >= SAMPLE_WIDE);

    wire wire_in;
    reg  latched = 1'b0;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n)                       latched <= 1'b0;
        else if (sample_cnt == LATCH_AT)    latched <= wire_in;
    end

    wire_io io (
        .clk      (enclave_clk),
        .reset_n  (reset_n),
        .drive_en (drive_en),
        .wire_out (latched),
        .wire_in  (wire_in),
        .pad      (pipe_pad)
    );

    assign led = latched;

endmodule
