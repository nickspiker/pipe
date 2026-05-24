// =============================================================================
// top_pipe_toggle.v — straight toggle on pipe_pad, no codec, no XOR, no slots
// =============================================================================
//
// Smoke test: drive a clean square wave at a known rate so the bridge sees
// actual transitions instead of the codec's idle 1010 pattern (which mirrors
// host state and looks the same as no data). Lets us validate the bridge's
// rising/falling edge tracker against a ground-truth toggle source before
// wiring real codec data emission.
//
// Wire setup: pipe_pad is a direct output (no tristate, no drive_en gating).
// The bridge end sees a continuous square wave. Toggle rate is ring osc / 2^N
// with N chosen so the rate matches the bridge's expected slot range
// (~25-50 kHz). Counter[10] off the divided enclave clock lands in that band.
//
// LED is a slow heartbeat off the same counter so we can eyeball "alive".
//
// =============================================================================

`timescale 1ns / 1ps

`ifndef RING_STAGES
`define RING_STAGES 5
`endif
`ifndef RING_DIV
`define RING_DIV 512
`endif

module top_pipe_toggle (
    output wire pipe_pad,
    output wire led
);

    // -------------------------------------------------------------------------
    // Ring osc + mod-N divider — identical structure to top_pipe_codec.v.
    //
    // Placement is pinned via BEL attributes so the ring osc frequency is
    // consistent build-to-build. Without pinning, nextpnr places the 5 LUTs
    // wherever it finds room and the inter-LUT routing delays vary by ±tens
    // of percent across builds, which shifts the osc frequency the same way.
    // Pinned: all 5 stages in adjacent SLICEs of one tile (X4/Y20) so the
    // ring is physically tight. PROD-side TRNG rings will use the same
    // approach but scattered across the die to avoid injection-locking.
    // -------------------------------------------------------------------------
    (* noglobal *) wire [`RING_STAGES-1:0] ring_q;
    (* keep, BEL="X4/Y20/SLICEA.K0" *)
    LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[`RING_STAGES-1]), .B(1'b0), .C(1'b0), .D(1'b0),
        .Z(ring_q[0])
    );
    // Per-stage BEL strings. Adjacent K0/K1 in each SLICE pack 2 LUTs per
    // SLICE; ring crosses 3 SLICEs (A.K0/A.K1, B.K0/B.K1, C.K0) of tile X4/Y20.
    (* keep, BEL="X4/Y20/SLICEA.K1" *)
    LUT4 #(.INIT(16'hAAAA)) ring_buf_1 (
        .A(ring_q[0]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(ring_q[1])
    );
    (* keep, BEL="X4/Y20/SLICEB.K0" *)
    LUT4 #(.INIT(16'hAAAA)) ring_buf_2 (
        .A(ring_q[1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(ring_q[2])
    );
    (* keep, BEL="X4/Y20/SLICEB.K1" *)
    LUT4 #(.INIT(16'hAAAA)) ring_buf_3 (
        .A(ring_q[2]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(ring_q[3])
    );
    (* keep, BEL="X4/Y20/SLICEC.K0" *)
    LUT4 #(.INIT(16'hAAAA)) ring_buf_4 (
        .A(ring_q[3]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(ring_q[4])
    );

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
    // Toggle counter — divides enclave_clk further so the wire toggle rate
    // lands in the bridge's expected slot band.
    // enclave_clk ≈ 600 kHz with default RING_STAGES=5, RING_DIV=512.
    // counter[3] = enclave_clk / 16 ≈ 37 kHz toggle.
    // counter[4] = enclave_clk / 32 ≈ 19 kHz toggle.
    // counter[15] = enclave_clk / 65536 ≈ visible LED blink.
    // -------------------------------------------------------------------------
    reg [15:0] counter = 0;
    always @(posedge enclave_clk) counter <= counter + 1'b1;

    assign pipe_pad = counter[3];
    assign led      = 1'b0;

endmodule
