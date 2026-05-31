// =============================================================================
// top_pipe_counter.v — Counter transmitter + RX window for wire-listening +
// bidirectional validation. FPGA drives idle alternation continuously; once
// per IDLE_TICKS, sends a sync prefix + 32-bit payload, then tristates for an
// RX window. Bridge listens and may drive during the RX window. FPGA's next
// TX payload echoes the byte sampled during the previous RX window in the
// upper bits, so the host can verify bridge→FPGA round-trip in a single
// capture.
//
// Wire encoding:
//   IDLE: alternating 1, 0, 1, 0, ... per wire_clk cycle. Continuous "clock".
//   TRANSMISSION (every IDLE_TICKS wire_clks):
//     SYNC: 2 wire_clks LOW (breaks idle alternation).
//     DATA: 32 bits LSB-first. Each bit takes 2 wire_clks:
//       sub-phase 0: drive HIGH (= "host slot" position in mirror-XOR)
//       sub-phase 1: drive bit value (= "enclave slot")
//     RX:   RX_TICKS wire_clks tristated. Sample wire_in once per 2 wire_clks
//           (RX_TICKS/2 bits = 8 bits). Bridge may drive during this window.
//   After RX: return to IDLE alternation.
//
// TX payload layout (32 bits, LSB-first on wire):
//   bits [7:0]:   pattern_byte (FPGA's known reference pattern)
//   bits [15:8]:  8'h00 (separator — preserves regex compatibility when last_rx
//                  is also zero)
//   bits [23:16]: last_rx_byte (FPGA's echo of what bridge drove last RX)
//   bits [28:24]: byte_idx (pattern position 0..31)
//   bits [31:29]: 3'b0 (padding)
//
// Bridge round-trip: bridge drives a known byte sequence during each RX
// window. Next TX's last_rx_byte field should match what the bridge drove.
//
// Same I/O port list as top_pipe_mirror_xor so the LPF works unchanged.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module top_pipe_counter (
    input  wire clk,                          // 25 MHz external crystal (P6) — unused but kept for LPF
    output wire oled_scl,                     // unused
    output wire oled_sda,                     // unused
    inout  wire pipe_pad,                     // the wire (E16)
    output reg  led,                          // status LED
    output wire piezo_enclave_p,              // piezo in-phase  (M4)
    output wire piezo_enclave_n               // piezo anti-phase (N4)
);

    // -------------------------------------------------------------------------
    // OLED + unused outputs tied off (LPF needs all pins present)
    // -------------------------------------------------------------------------
    assign oled_scl = 1'b1;
    assign oled_sda = 1'b1;

    // -------------------------------------------------------------------------
    // Ring oscillator → cascaded divider chain (same as top_pipe_mirror_xor)
    // -------------------------------------------------------------------------
    parameter integer RING_STAGES        = 5;
    parameter integer ENCLAVE_DIV_LOG2   = 7;   // ring / 128 ≈ 2.98 MHz
    parameter integer WIRE_DIV_LOG2      = 8;   // enclave / 256 ≈ 11.6 kHz

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

    // Stage 1: ring_raw → enclave_clk
    reg [ENCLAVE_DIV_LOG2-1:0] enclave_div_cnt = 0;
    always @(posedge ring_raw) enclave_div_cnt <= enclave_div_cnt + 1'b1;
    wire enclave_clk;
    (* keep *) DCCA dcca_enclave_clk (
        .CLKI(enclave_div_cnt[ENCLAVE_DIV_LOG2-1]), .CE(1'b1), .CLKO(enclave_clk)
    );

    // Stage 2: enclave_clk → wire_clk
    reg [WIRE_DIV_LOG2-1:0] wire_div_cnt = 0;
    always @(posedge enclave_clk) wire_div_cnt <= wire_div_cnt + 1'b1;
    wire wire_clk;
    (* keep *) DCCA dcca_wire_clk (
        .CLKI(wire_div_cnt[WIRE_DIV_LOG2-1]), .CE(1'b1), .CLKO(wire_clk)
    );

    // -------------------------------------------------------------------------
    // FSM: IDLE → TX → RX → IDLE
    // -------------------------------------------------------------------------
    localparam FSM_IDLE = 2'd0;
    localparam FSM_TX   = 2'd1;
    localparam FSM_RX   = 2'd2;

    parameter integer IDLE_TICKS  = 256;    // ~22 ms between TX (high cadence)
    parameter integer SYNC_TICKS  = 2;
    parameter integer DATA_BITS   = 32;
    parameter integer BIT_TICKS   = 2;
    parameter integer TX_LEN      = SYNC_TICKS + DATA_BITS * BIT_TICKS;  // = 66
    parameter integer RX_TICKS    = 16;     // 8 bits × 2 wire_clks per bit

    parameter [255:0] TX_PATTERN_REF =
        256'h74207265766f2073706d756a20786f66206e776f7262206b6369757120656854;

    reg [1:0]   fsm          = FSM_IDLE;
    reg [4:0]   byte_idx     = 5'd0;
    reg [13:0]  idle_div     = 14'd0;
    reg [9:0]   tx_phase     = 10'd0;
    reg [4:0]   rx_phase     = 5'd0;
    reg [31:0]  tx_shift     = 32'd0;
    reg [7:0]   rx_byte_reg  = 8'd0;
    reg [7:0]   last_rx_byte = 8'd0;
    reg         idle_state   = 1'b0;
    reg         wire_out_reg = 1'b1;

    // wire_in_sync: 2-FF-synchronized pad input in enclave_clk domain.
    // Sampled in wire_clk (= enclave_clk / 256), so already-stable values are
    // sampled — no further CDC needed.
    wire wire_in_sync;

    // Extract pattern byte at position byte_idx
    wire [7:0] pattern_byte = TX_PATTERN_REF[8 * byte_idx +: 8];

    // FSM update + idle alternation
    always @(posedge wire_clk) begin
        idle_state <= ~idle_state;

        case (fsm)
            FSM_IDLE: begin
                if (idle_div == IDLE_TICKS - 1) begin
                    idle_div <= 0;
                    fsm <= FSM_TX;
                    tx_phase <= 0;
                    // Payload format: [3'h0:byte_idx][last_rx_byte][8'h00][pattern_byte]
                    tx_shift <= {3'h0, byte_idx, last_rx_byte, 8'h00, pattern_byte};
                    byte_idx <= byte_idx + 1'b1;
                end else begin
                    idle_div <= idle_div + 1'b1;
                end
            end
            FSM_TX: begin
                if (tx_phase == TX_LEN - 1) begin
                    fsm <= FSM_RX;
                    rx_phase <= 0;
                    rx_byte_reg <= 8'd0;
                end else begin
                    tx_phase <= tx_phase + 1'b1;
                end
            end
            FSM_RX: begin
                // Sample once per 2 wire_clks (on odd phase, matches BIT_TICKS).
                if (rx_phase[0] == 1'b1) begin
                    rx_byte_reg <= {rx_byte_reg[6:0], wire_in_sync};
                end
                if (rx_phase == RX_TICKS - 1) begin
                    fsm <= FSM_IDLE;
                    // Final sample becomes last_rx_byte
                    last_rx_byte <= {rx_byte_reg[6:0], wire_in_sync};
                end else begin
                    rx_phase <= rx_phase + 1'b1;
                end
            end
            default: fsm <= FSM_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Wire output per FSM state
    //   IDLE: wire_out = idle_state (alternates)
    //   TX sync (tx_phase < SYNC_TICKS): wire_out = 0
    //   TX data:
    //     sub-phase 0 (= "host slot"): wire_out = 1
    //     sub-phase 1 (= "enclave slot"): wire_out = tx_shift[bit_idx]
    //   RX: don't care (drive_en = 0)
    // -------------------------------------------------------------------------
    wire [9:0]  data_phase   = tx_phase - SYNC_TICKS;
    wire [4:0]  bit_idx      = data_phase[5:1];
    wire        bit_subphase = data_phase[0];

    always @(posedge wire_clk) begin
        case (fsm)
            FSM_IDLE: wire_out_reg <= idle_state;
            FSM_TX: begin
                if (tx_phase < SYNC_TICKS) begin
                    wire_out_reg <= 1'b0;
                end else if (bit_subphase == 1'b0) begin
                    wire_out_reg <= 1'b1;
                end else begin
                    wire_out_reg <= tx_shift[bit_idx];
                end
            end
            FSM_RX: wire_out_reg <= 1'b0;  // tristated; pad value comes from bridge or float
            default: wire_out_reg <= idle_state;
        endcase
    end

    // -------------------------------------------------------------------------
    // Wire I/O — FPGA tristates only during FSM_RX
    // -------------------------------------------------------------------------
    wire_io u_wire (
        .clk(enclave_clk),
        .reset_n(1'b1),
        .drive_en(fsm != FSM_RX),
        .wire_out(wire_out_reg),
        .wire_in(wire_in_sync),
        .pad(pipe_pad)
    );

    // -------------------------------------------------------------------------
    // Status LED: lit during TX or RX (active phases).
    // -------------------------------------------------------------------------
    always @(posedge wire_clk) led <= (fsm != FSM_IDLE);

    // -------------------------------------------------------------------------
    // Piezo H-bridge: drives during TX only. Silent during IDLE + RX.
    // -------------------------------------------------------------------------
    assign piezo_enclave_p =  (fsm == FSM_TX) ?  wire_out_reg : 1'b0;
    assign piezo_enclave_n =  (fsm == FSM_TX) ? ~wire_out_reg : 1'b0;

endmodule

`default_nettype wire
