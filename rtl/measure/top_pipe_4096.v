// =============================================================================
// top_pipe_4096.v — 4096-bit TX burst for sustained-decode validation.
//
// Sends IDLE → SYNC (2 LOW) → 4096 enclave-slot-bits → IDLE. Each enclave
// bit takes 2 wire_clks:
//   sub-phase 0 (host slot): drive HIGH placeholder (Phase 1; bridge drives
//                             here in Phase 2 with the XOR scheme)
//   sub-phase 1 (enclave slot): drive bit N = TX_PATTERN_REF[N & 8'hFF]
//
// 4096 bits = 16 repetitions of the 256-bit pattern. Wire burst length =
// 8192 wire_clks ≈ 730 ms (at observed wire_clk ≈ 89 µs).
//
// Cadence (IDLE_TICKS) bumped to 16384 wire_clks ≈ 1.46 s so the bridge has
// time to issue a fresh 65k-sample capture (~1.05 s) between bursts.
//
// Same I/O port list as top_pipe_counter / top_pipe_mirror_xor so the LPF
// works unchanged.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_pipe_4096 (
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

    parameter integer RING_STAGES        = 5;
    parameter integer ENCLAVE_DIV_LOG2   = 7;
    parameter integer WIRE_DIV_LOG2      = 8;

    (* noglobal *) wire [RING_STAGES-1:0] ring_q;
    (* keep, BEL="X4/Y20/SLICEA.K0" *)
    LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[RING_STAGES-1]), .B(1'b0), .C(1'b0), .D(1'b0),
        .Z(ring_q[0])
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
    // FSM: IDLE → TX(4096 bits) → IDLE
    // -------------------------------------------------------------------------
    parameter integer IDLE_TICKS  = 16384;          // ~1.46 s between bursts
    parameter integer SYNC_TICKS  = 2;
    parameter integer DATA_BITS   = 4096;
    parameter integer BIT_TICKS   = 2;
    parameter integer TX_LEN      = SYNC_TICKS + DATA_BITS * BIT_TICKS;  // = 8194

    parameter [255:0] TX_PATTERN_REF =
        256'h74207265766f2073706d756a20786f66206e776f7262206b6369757120656854;

    reg         tx_active    = 1'b0;
    reg [13:0]  tx_phase     = 14'd0;        // 0..8193
    reg [14:0]  idle_div     = 15'd0;        // 0..16383
    reg         idle_state   = 1'b0;
    reg         wire_out_reg = 1'b1;

    wire [13:0] data_phase   = tx_phase - SYNC_TICKS;  // 0..8191 during data
    wire [11:0] bit_idx      = data_phase[12:1];       // 0..4095
    wire        bit_subphase = data_phase[0];          // 0 = host, 1 = enclave
    wire        pattern_bit  = TX_PATTERN_REF[bit_idx[7:0]];  // cycles every 256 bits

    always @(posedge wire_clk) begin
        idle_state <= ~idle_state;

        if (!tx_active) begin
            if (idle_div == IDLE_TICKS - 1) begin
                idle_div <= 0;
                tx_active <= 1'b1;
                tx_phase <= 0;
            end else begin
                idle_div <= idle_div + 1'b1;
            end
        end else begin
            if (tx_phase == TX_LEN - 1) begin
                tx_active <= 1'b0;
                tx_phase <= 0;
            end else begin
                tx_phase <= tx_phase + 1'b1;
            end
        end
    end

    always @(posedge wire_clk) begin
        if (!tx_active) begin
            wire_out_reg <= idle_state;
        end else if (tx_phase < SYNC_TICKS) begin
            wire_out_reg <= 1'b0;
        end else if (bit_subphase == 1'b0) begin
            wire_out_reg <= 1'b1;        // host slot placeholder
        end else begin
            wire_out_reg <= pattern_bit; // enclave slot data
        end
    end

    wire wire_in_sync_unused;
    wire_io u_wire (
        .clk(enclave_clk),
        .reset_n(1'b1),
        .drive_en(1'b1),
        .wire_out(wire_out_reg),
        .wire_in(wire_in_sync_unused),
        .pad(pipe_pad)
    );

    always @(posedge wire_clk) led <= tx_active;

    assign piezo_enclave_p =  tx_active ?  wire_out_reg : 1'b0;
    assign piezo_enclave_n =  tx_active ? ~wire_out_reg : 1'b0;

endmodule

`default_nettype wire
