// =============================================================================
// top_pipe_codec.v — Real PIPE protocol on the wire (enclave side)
// =============================================================================
//
// Instantiates the slot-based codec from rtl/codec.v with drive_en gated to my_slot, so the enclave only drives its own slots and tristates during host slots. This avoids the FPGA-vs-host wire contention that broke the latch-style experiments.
//
// Echo policy: tx_data mirrors the last decoded RX bit. So:
//   • Host idle  → host_codec drives 0 in its slot → enclave decodes 0 → tx_data stays 0 → enclave drives OWN_IDLE = 1 in its slot.
//   • Host injects 1 → enclave decodes 1 → next enclave slot, the encoding XORs in other_last=1, shifting the wire pattern → the host_codec recovers the 1 as `rx_data`.
//
// SLOT_DIV chosen by build script. Default 12 → ~50 kHz slot rate at enclave_clk ≈ 600 kHz.
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

module top_pipe_codec (
    inout  wire pipe_pad,
    output wire led
);

    // -------------------------------------------------------------------------
    // Ring osc + mod-N divider → enclave_clk (production scheme)
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

    // POR
    reg [3:0] por_cnt = 0;
    wire      por_done = &por_cnt;
    wire      reset_n  = por_done;
    always @(posedge enclave_clk) if (!por_done) por_cnt <= por_cnt + 1'b1;

    // -------------------------------------------------------------------------
    // Slot clock — generates slot_tick (one enclave_clk pulse per slot) and my_slot (alternates each tick). The codec is clocked off slot_tick.
    // -------------------------------------------------------------------------
    wire slot_tick;
    wire my_slot;
    slot_clk #(.DIV(`SLOT_DIV)) sc (
        .clk       (enclave_clk),
        .reset_n   (reset_n),
        .slot_tick (slot_tick),
        .my_slot   (my_slot)
    );

    // -------------------------------------------------------------------------
    // Codec — clocked at slot rate. Echoes the last decoded RX bit back.
    // -------------------------------------------------------------------------
    wire wire_in;
    wire codec_wire_out;
    wire codec_drive_en;
    wire rx_data;
    wire rx_valid;

    reg tx_data = 1'b0;
    always @(posedge slot_tick or negedge reset_n) begin
        if (!reset_n)   tx_data <= 1'b0;
        else if (rx_valid) tx_data <= rx_data;
    end

    codec #(.OWN_IDLE(1'b1)) cd (
        .clk      (slot_tick),
        .reset_n  (reset_n),
        .my_slot  (my_slot),
        .tx_data  (tx_data),
        .wire_in  (wire_in),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .wire_out (codec_wire_out),
        .drive_en (codec_drive_en)
    );

    // -------------------------------------------------------------------------
    // Wire driver. drive_en comes from the codec (= my_slot, gated by reset).
    // -------------------------------------------------------------------------
    wire_io io (
        .clk      (enclave_clk),
        .reset_n  (reset_n),
        .drive_en (codec_drive_en),
        .wire_out (codec_wire_out),
        .wire_in  (wire_in),
        .pad      (pipe_pad)
    );

    // LED mirrors current my_slot for a visible heartbeat.
    assign led = my_slot;

endmodule
