// =============================================================================
// top_pipe_split.v — TX-tristate-clocked + RX-only split bidir
// =============================================================================
//
// E16 (pipe_tx_pad): bidir, periodically tristates. Drives `latched` when
// active; releases the bus during the sample window so the host's drive
// (if any) can pull the wire.
// F15 (pipe_rx_pad): pure IBUF, reads the shorted node continuously. During
// E16's tristate window F15 sees the wire voltage (host or floating);
// during E16's drive window F15 sees E16's drive (used as a sanity bit).
//
// Behaviour: at sample-window time, latch F15's reading into `latched`.
// `latched` is what E16 drives during the next drive phase. A host write
// (HIGH or LOW) is captured during the sample window and held by E16 on
// the subsequent drive cycles — including after the host releases.
//
// Tristate window is ~32 cycles of 8 cycles wide (every 256 enclave_clks);
// at 600 kHz enclave_clk that's a 13.3 µs sample window every 426 µs.
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
`define SAMPLE_PERIOD 256
`endif
`ifndef SAMPLE_WIDE
`define SAMPLE_WIDE 8
`endif

module top_pipe_split (
    inout  wire pipe_tx_pad,
    input  wire pipe_rx_pad,
    output wire led
);

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

    reg [3:0] por_cnt = 0;
    wire      por_done = &por_cnt;
    wire      reset_n  = por_done;
    always @(posedge enclave_clk) if (!por_done) por_cnt <= por_cnt + 1'b1;

    // Sample window scheduler — same as top_pipe_latch.v
    localparam integer CNT_W    = $clog2(`SAMPLE_PERIOD);
    localparam integer LATCH_AT = `SAMPLE_WIDE - 1;
    reg [CNT_W-1:0] sample_cnt = 0;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n) sample_cnt <= 0;
        else if (sample_cnt == (`SAMPLE_PERIOD - 1)) sample_cnt <= 0;
        else sample_cnt <= sample_cnt + 1'b1;
    end
    wire tx_drive_en = (sample_cnt >= `SAMPLE_WIDE);

    // RX path: 2-FF sync on F15's IBUF.
    reg [1:0] rx_sync = 2'b00;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n) rx_sync <= 2'b00;
        else          rx_sync <= {rx_sync[0], pipe_rx_pad};
    end
    wire wire_in = rx_sync[1];

    // Latch sampled value during the tristate window.
    reg latched = 1'b0;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n)                       latched <= 1'b0;
        else if (sample_cnt == LATCH_AT)    latched <= wire_in;
    end

    // E16 BB primitive with explicit tristate.
    wire pipe_tx_pad_in_unused;
    BB tx_bb (
        .I(latched),
        .T(~tx_drive_en),
        .O(pipe_tx_pad_in_unused),
        .B(pipe_tx_pad)
    );

    assign led = latched;

endmodule
