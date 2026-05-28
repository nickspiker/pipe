// =============================================================================
// top_pipe_counter.v — Minimal counter transmitter for wire-listening pipeline
// validation. Drops mirror-XOR protocol entirely. FPGA owns the wire
// continuously and drives a known pattern that the bridge can listen to and
// decode.
//
// Wire encoding (matches the example in the user's spec):
//   IDLE: alternating 1, 0, 1, 0, ... per wire_clk cycle. Continuous "clock".
//   TRANSMISSION (once per second):
//     2 wire_clks of LOW (sync prefix; breaks the idle alternation),
//     followed by 32 data bits LSB-first. Each data bit takes 2 wire_clks:
//       sub-phase 0: drive HIGH (= "host slot" position in the old protocol)
//       sub-phase 1: drive bit value (= "enclave slot" position)
//   After last bit: return to IDLE alternation. Counter increments.
//
// Bridge listens via existing wire_trace / SM2 sampler. Host decodes the
// 32-bit counter and confirms it increments once per second.
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
    // Counter transmitter FSM — PATTERN MODE
    //   Every "second" (= IDLE_TICKS wire_clks), transmits a 32-bit count value.
    //   The count payload is filled with pattern data: the low byte cycles
    //   through the 32 ASCII chars of "The quick brown fox jumps over t",
    //   so consecutive transmissions reveal the FPGA's known reference pattern.
    //   Counter advances per TX. Bridge confirms decoded count low-bytes ==
    //   "T", "h", "e", " ", "q", "u", ... in order.
    // -------------------------------------------------------------------------
    parameter integer IDLE_TICKS  = 11600;  // 1 second between TX (1 Hz tick)
    parameter integer SYNC_TICKS  = 2;
    parameter integer DATA_BITS   = 32;
    parameter integer BIT_TICKS   = 2;
    parameter integer TX_LEN      = SYNC_TICKS + DATA_BITS * BIT_TICKS;  // = 66

    // 256-bit pattern source. byte_idx is the position in the pattern (0..31).
    // Pattern is "The quick brown fox jumps over t" — same as top_pipe_mirror_xor.
    parameter [255:0] TX_PATTERN_REF =
        256'h74207265766f2073706d756a20786f66206e776f7262206b6369757120656854;
    reg [4:0]   byte_idx     = 5'd0;  // 0..31, cycles through pattern bytes
    reg [13:0]  idle_div     = 14'd0;
    reg         tx_active    = 1'b0;
    reg [9:0]   tx_phase     = 10'd0;
    reg [31:0]  tx_shift     = 32'd0;
    reg         idle_state   = 1'b0;     // alternates per wire_clk during idle
    reg         wire_out_reg = 1'b1;

    // Extract pattern byte at position byte_idx (each byte = 8 bits of TX_PATTERN_REF).
    wire [7:0] pattern_byte = TX_PATTERN_REF[8 * byte_idx +: 8];

    // Phase counter and idle state alternation
    always @(posedge wire_clk) begin
        idle_state <= ~idle_state;

        if (!tx_active) begin
            if (idle_div == IDLE_TICKS - 1) begin
                idle_div <= 0;
                tx_active <= 1'b1;
                tx_phase <= 0;
                // TX payload: high 24 bits = byte_idx as a marker (zero-padded),
                // low 8 bits = the actual pattern byte. Lets us verify both:
                //   - bit-exact byte match against expected pattern
                //   - byte index increments monotonically
                tx_shift <= {24'h0, pattern_byte};
                byte_idx <= byte_idx + 1'b1;  // wraps mod 32 (5-bit reg)
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

    // -------------------------------------------------------------------------
    // Wire output decision per wire_clk
    // -------------------------------------------------------------------------
    //   IDLE (tx_active = 0): wire_out = idle_state (alternates 1, 0, 1, 0, ...)
    //   TX sync (tx_phase < SYNC_TICKS): wire_out = 0
    //   TX data: for each pair of wire_clks within a bit:
    //     sub-phase 0 (= "host slot"): wire_out = 1
    //     sub-phase 1 (= "enclave slot"): wire_out = tx_shift[bit_idx]
    // -------------------------------------------------------------------------
    wire [9:0]  data_phase   = tx_phase - SYNC_TICKS;  // 0..63
    wire [4:0]  bit_idx      = data_phase[5:1];        // 0..31
    wire        bit_subphase = data_phase[0];           // 0 = host, 1 = enclave

    always @(posedge wire_clk) begin
        if (!tx_active) begin
            wire_out_reg <= idle_state;
        end else if (tx_phase < SYNC_TICKS) begin
            wire_out_reg <= 1'b0;
        end else if (bit_subphase == 1'b0) begin
            wire_out_reg <= 1'b1;
        end else begin
            wire_out_reg <= tx_shift[bit_idx];
        end
    end

    // -------------------------------------------------------------------------
    // Wire I/O — FPGA owns the wire (drive_en always 1)
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

    // -------------------------------------------------------------------------
    // Status LED: lights solid when tx_active (= 5.7 ms once per second).
    // Flashes briefly visible at human timescale.
    // -------------------------------------------------------------------------
    always @(posedge wire_clk) led <= tx_active;

    // -------------------------------------------------------------------------
    // Piezo H-bridge: only sounds during TX. Idle = silent (both pins LOW = 0V
    // across piezo). Driving wire_out_reg here would play the IDLE alternation
    // as a continuous ~11.6 kHz tone — annoying, hides the click of TX bursts.
    // During TX, drive piezo with wire_out_reg so each transmission is audible
    // as a brief click pattern (~5.7 ms long).
    // -------------------------------------------------------------------------
    assign piezo_enclave_p =  tx_active ?  wire_out_reg : 1'b0;
    assign piezo_enclave_n =  tx_active ? ~wire_out_reg : 1'b0;

endmodule

`default_nettype wire
