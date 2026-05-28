// =============================================================================
// top_pipe_pattern.v — Continuous slot-ownership pattern transmitter
// =============================================================================
// FPGA owns the wire. Each wire_clk drives one slot's worth:
//   slot N (even) = "enclave": drive bit N/2 of a rotating 256-bit pattern
//   slot N (odd)  = "host":    drive constant 1 (= simulates bridge driving)
//
// This is the simplest possible slot-based encoding — no mirror-XOR, no data_mode
// handshake, no contention with bridge. Bridge listens via wire_trace, decodes
// pattern bits using the median + P-loop pipeline that worked for counter test.
//
// Same I/O port list as top_pipe_mirror_xor so the LPF works unchanged.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_pipe_pattern (
    input  wire clk,
    output wire oled_scl,
    output wire oled_sda,
    inout  wire pipe_pad,
    output reg  led,
    output wire piezo_enclave_p,
    output wire piezo_enclave_n
);

    assign oled_scl = 1'b1;
    assign oled_sda = 1'b1;

    // -------------------------------------------------------------------------
    // Clock tree (same as top_pipe_mirror_xor)
    // -------------------------------------------------------------------------
    parameter integer RING_STAGES        = 5;
    parameter integer ENCLAVE_DIV_LOG2   = 7;
    parameter integer WIRE_DIV_LOG2      = 8;

    (* noglobal *) wire [RING_STAGES-1:0] ring_q;
    (* keep, BEL="X4/Y20/SLICEA.K0" *)
    LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[RING_STAGES-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(ring_q[0])
    );
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

    reg [ENCLAVE_DIV_LOG2-1:0] enclave_div_cnt = 0;
    always @(posedge ring_raw) enclave_div_cnt <= enclave_div_cnt + 1'b1;
    wire enclave_clk;
    (* keep *) DCCA dcca_enclave_clk (
        .CLKI(enclave_div_cnt[ENCLAVE_DIV_LOG2-1]), .CE(1'b1), .CLKO(enclave_clk)
    );

    reg [WIRE_DIV_LOG2-1:0] wire_div_cnt = 0;
    always @(posedge enclave_clk) wire_div_cnt <= wire_div_cnt + 1'b1;
    wire wire_clk;
    (* keep *) DCCA dcca_wire_clk (
        .CLKI(wire_div_cnt[WIRE_DIV_LOG2-1]), .CE(1'b1), .CLKO(wire_clk)
    );

    // -------------------------------------------------------------------------
    // 256-bit TX pattern — same as top_pipe_mirror_xor's TX_PATTERN:
    //   "The quick brown fox jumps over t" (32 ASCII chars = 256 bits)
    // LSB of 'T' = bit 0 = first transmitted bit.
    // -------------------------------------------------------------------------
    parameter [255:0] TX_PATTERN =
        256'h74207265766f2073706d756a20786f66206e776f7262206b6369757120656854;
    reg [255:0] pattern_reg = TX_PATTERN;

    // -------------------------------------------------------------------------
    // Slot ownership counter. Each wire_clk advances by 1 slot. Even slots =
    // enclave (FPGA drives pattern bit), odd slots = host (FPGA drives 1 to
    // simulate bridge). Pattern shifts after every PAIR of slots (= host→
    // enclave transition).
    //   slot_parity: 0 = enclave, 1 = host
    // -------------------------------------------------------------------------
    reg slot_parity = 1'b0;
    reg wire_out_reg = 1'b0;

    always @(posedge wire_clk) begin
        slot_parity <= ~slot_parity;
        if (slot_parity == 1'b1) begin
            // We just finished host slot — about to start enclave. Shift pattern
            // for the upcoming enclave bit.
            pattern_reg <= {pattern_reg[0], pattern_reg[255:1]};
        end
        // Output for the NEW slot (parity AFTER toggle = the slot we're
        // entering at this posedge wire_clk).
        // Wait — we just toggled. The toggled value IS the slot we just entered.
        // Use the post-toggle value.
        if (~slot_parity == 1'b0) begin  // post-toggle == 0 → enclave
            wire_out_reg <= pattern_reg[0];
        end else begin                    // post-toggle == 1 → host
            wire_out_reg <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Wire I/O — FPGA owns the wire continuously
    // -------------------------------------------------------------------------
    wire wire_in_sync_unused;
    wire_io u_wire (
        .clk(enclave_clk),
        .reset_n(1'b1),
        .drive_en(1'b1),
        .wire_out(wire_out_reg),
        .wire_in(wire_in_sync_unused),
        .pad(pipe_pad)
    );

    // LED: solid ON (this bitstream is always transmitting)
    always @(posedge wire_clk) led <= 1'b1;

    // Piezo: drive the pattern bit (= every other slot) so audible activity
    // matches the pattern data, not the slot alternation. wire_out toggles
    // every wire_clk creating a 5.8 kHz tone; piezo gated to enclave half
    // shows pattern variation as amplitude modulation.
    assign piezo_enclave_p =  slot_parity == 1'b0 ? wire_out_reg : 1'b0;
    assign piezo_enclave_n =  slot_parity == 1'b0 ? ~wire_out_reg : 1'b0;

endmodule

`default_nettype wire
