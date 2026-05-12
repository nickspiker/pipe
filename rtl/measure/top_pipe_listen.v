// =============================================================================
// top_pipe_listen.v — Always-tristate diagnostic
// =============================================================================
//
// FPGA pin is held in Hi-Z forever. Host has full control of the wire.
// LED reflects whatever the wire shows (active-low, lit when wire is LOW).
// This isolates the BB tristate path: if the host's drive on D7 is visible
// when reading back through ADBUS7, the wiring is good and the issue with
// top_pipe_latch.v is in the latch / sample-phase logic, not the IO buffer.
//
// =============================================================================

`timescale 1ns / 1ps

`ifndef RING_STAGES
`define RING_STAGES 5
`endif
`ifndef RING_DIV
`define RING_DIV 512
`endif

module top_pipe_listen (
    inout  wire pipe_pad,
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

    wire wire_in;
    wire_io io (
        .clk      (enclave_clk),
        .reset_n  (reset_n),
        .drive_en (1'b0),       // ALWAYS TRISTATE
        .wire_out (1'b0),
        .wire_in  (wire_in),
        .pad      (pipe_pad)
    );

    assign led = wire_in;

endmodule
