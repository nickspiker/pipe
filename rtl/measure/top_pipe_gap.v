// =============================================================================
// top_pipe_gap.v — 4096-slot gap timing-recovery test.
//
// Each burst:
//   IDLE (alternating 1,0,1,0,...)
//   SYNC1   = 4 wire_clks LOW (extended for reliable detection at slow sample
//             rates that the bridge must use to cover the whole burst)
//   GAP     = 4096 wire_clks HIGH (no edges — the "indistinguishable from
//             idle, no clock recovery available" interval)
//   SYNC2   = 4 wire_clks LOW
//   IDLE
//
// Burst length = 4 + 4096 + 4 = 4104 wire_clks ≈ 365 ms at ~89 µs/wire_clk.
// IDLE_TICKS = 65536 wire_clks (~5.8 s) so the bridge has plenty of time to
// issue captures between bursts.
//
// The host verifies the gap by capturing both syncs in a single trace and
// checking that the distance from SYNC1 falling edge to SYNC2 falling edge
// equals exactly (4 + 4096) × wire_clk_period_samples within ±1 wire_clk.
//
// This is the empirical proof that the bridge's clock recovery — locked from
// the IDLE pattern before SYNC1 — stays correct through 4096 wire_clks of
// indistinguishable-from-idle wire state. Patent Claim: 4096-slot gap
// tolerance for the PIPE single-wire line code.
//
// Same I/O port list as top_pipe_counter so the LPF works unchanged.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_pipe_gap (
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
    // FSM: IDLE → SYNC1 → GAP → SYNC2 → IDLE
    // -------------------------------------------------------------------------
    localparam FSM_IDLE  = 3'd0;
    localparam FSM_SYNC1 = 3'd1;
    localparam FSM_GAP   = 3'd2;
    localparam FSM_SYNC2 = 3'd3;

    parameter integer IDLE_TICKS   = 4096;      // ~365 ms between bursts;
                                                // total cycle ~730 ms.
                                                // Host capture (~650 ms at 79 µs/sample)
                                                // catches the burst ~85% of the time.
    parameter integer SYNC1_TICKS  = 8;         // 8 wire_clks ≈ 9 samples → robust
    parameter integer GAP_TICKS    = 4096;
    parameter integer SYNC2_TICKS  = 8;

    reg [2:0]   fsm          = FSM_IDLE;
    reg [15:0]  idle_div     = 16'd0;
    reg [11:0]  gap_phase    = 12'd0;          // 0..4095
    reg [2:0]   sync_phase   = 3'd0;           // 0..3
    reg         idle_state   = 1'b0;
    reg         wire_out_reg = 1'b1;

    always @(posedge wire_clk) begin
        idle_state <= ~idle_state;

        case (fsm)
            FSM_IDLE: begin
                if (idle_div == IDLE_TICKS - 1) begin
                    idle_div <= 0;
                    fsm <= FSM_SYNC1;
                    sync_phase <= 0;
                end else begin
                    idle_div <= idle_div + 1'b1;
                end
            end
            FSM_SYNC1: begin
                if (sync_phase == SYNC1_TICKS - 1) begin
                    fsm <= FSM_GAP;
                    gap_phase <= 0;
                end else begin
                    sync_phase <= sync_phase + 1'b1;
                end
            end
            FSM_GAP: begin
                if (gap_phase == GAP_TICKS - 1) begin
                    fsm <= FSM_SYNC2;
                    sync_phase <= 0;
                end else begin
                    gap_phase <= gap_phase + 1'b1;
                end
            end
            FSM_SYNC2: begin
                if (sync_phase == SYNC2_TICKS - 1) begin
                    fsm <= FSM_IDLE;
                end else begin
                    sync_phase <= sync_phase + 1'b1;
                end
            end
            default: fsm <= FSM_IDLE;
        endcase
    end

    always @(posedge wire_clk) begin
        case (fsm)
            FSM_IDLE:  wire_out_reg <= idle_state;
            FSM_SYNC1: wire_out_reg <= 1'b0;     // 4 wire_clks LOW
            FSM_GAP:   wire_out_reg <= 1'b1;     // 4096 wire_clks HIGH (no edges)
            FSM_SYNC2: wire_out_reg <= 1'b0;     // 4 wire_clks LOW
            default:   wire_out_reg <= idle_state;
        endcase
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

    // Status LED: lit during the active burst (SYNC1, GAP, or SYNC2).
    always @(posedge wire_clk) led <= (fsm != FSM_IDLE);

    // Piezo: drive during the two syncs only (audible "click click" per burst).
    assign piezo_enclave_p =  ((fsm == FSM_SYNC1) || (fsm == FSM_SYNC2)) ?  wire_out_reg : 1'b0;
    assign piezo_enclave_n =  ((fsm == FSM_SYNC1) || (fsm == FSM_SYNC2)) ? ~wire_out_reg : 1'b0;

endmodule

`default_nettype wire
