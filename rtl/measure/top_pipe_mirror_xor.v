// =============================================================================
// top_pipe_mirror_xor.v — full Claim 12 mirror-XOR + Claim 7b handshake
// =============================================================================
// Implements Claim 12's mirror-XOR encoding rule with a Claim 7b handshake
// gate on top: the FPGA stays in IDLE (sends own_data = 0) until it sees the
// bridge drive its first 1 bit on the wire, then transitions to DATA mode and
// begins shifting TX_PATTERN per slot. This decouples acquisition (bridge's
// CDR locks on clean idle toggle, no data interference) from data exchange
// (both sides shift their TX patterns once handshake fires).
//
// Mirror-XOR encoding rule (both sides):
//     wire_value = OWN_IDLE XOR own_data XOR other_last_decoded_data
//
// With enclave_idle = 1 (Claim 12), own_data = effective_fpga_tx_bit, and
// other_last_decoded_data = wire value sampled at mid-host-slot.
//
// FPGA encode (enclave slot drive value):
//     wire_out = 1'b1 ^ effective_fpga_tx_bit ^ bridge_last_decoded
//     effective_fpga_tx_bit = data_mode ? fpga_tx_reg[0] : 1'b0
//   → 1 = drive HIGH; 0 = release (pulldown wins, wire goes LOW)
//   → drive_en = (slot_owner == 0). During host slots, drive_en = 0 (tristate).
//
// FPGA decode (sample bridge during host slot):
//   At slot_phase==2 (mid-host-slot), latch wire_in into bridge_last_decoded.
//   With 4-wire_clk-per-slot and the 2-FF wire_in synchroniser, mid-slot is
//   safely past bridge's drive settling. Becomes other_last_decoded_data for
//   the next enclave slot's encode.
//
// Handshake detection (Claim 7b):
//   At the same sample point, if wire_in is 1 and data_mode is 0, set
//   data_mode <= 1. Bridge initiates by driving its first non-idle bit; the
//   wire transition is what we detect.
//
// Data-mode auto-clear:
//   data_mode resets back to 0 after IDLE_CLEAR_SLOTS consecutive host slots
//   in which bridge_last_decoded sampled 0 (= bridge has gone silent for that
//   long). For random uniform data, P(64 consecutive 0s) ≈ 2⁻⁶⁴ ≈ never, so
//   real data traffic never triggers. Only a truly silent bridge (handshake
//   ended, or transient pause longer than the threshold) returns FPGA to
//   IDLE. Counter resets on any observed 1, so even sparse 1s in data hold
//   data_mode high. The auto-clear is what makes back-to-back wire_mirror
//   tests work without a reprogram — the protocol's idle envelope per Claim
//   7a naturally provides the reset condition.
//
// TX bit advance: fpga_tx_reg rotates right by 1 on every host→enclave
// transition (slot_owner 1→0), so each enclave slot encodes the next LSB-first
// bit of TX_PATTERN. Pattern repeats every 32 cycles. Rotation happens
// regardless of data_mode so the pattern position stays aligned with elapsed
// time; data_mode just gates whether the bit is XORed in or not.
//
// LED state indicator:
//   data_mode == 0: TRNG-modulated geiger-counter blink (random flicker, see
//                   geiger_cnt block) → "wire is alive, idle".
//   data_mode == 1: solid ON → "handshake detected, data flowing".
//
// Idle pattern (data_mode=0, bridge silent): wire_out = 1^0^0 = 1 (HIGH)
// during enclave, bridge LOW during host → clean alternating toggle = 100%
// transition density per Claim 12's idle guarantee. CDR's natural acquisition
// target.
//
// Post-handshake pattern (data_mode=1, both sides shifting AAAAAAAA):
//   Wire = L H H H L H H H ... (25% LOW, 75% HIGH, 50% transition density).
//   Bridge CDR may lose lock here — that's expected for this MVP slice; full
//   data-mode-aware CDR is a follow-up (Phase 2c). What matters here is the
//   handshake transition itself is observable from the bridge side as a step
//   change in wire stats (edge density, period).
//
// Default TX_PATTERN = AAAAAAAA so the visual post-handshake change is
// distinct from idle. wire_sync test against TX_PATTERN=AAAAAAAA still passes:
// bridge silent means bridge_last_decoded stays 0, handshake never fires, FPGA
// stays in IDLE driving 0 (TX_PATTERN never gets used).
//
// Slot rate / OLED / pin map / ring osc layout: unchanged from
// top_pipe_slotted_oled.v (slot ~23 µs ≈ 44 kHz toggle, RING_DIV=2048).
// =============================================================================

`timescale 1ns / 1ps
`include "glyph_dims.vh"

module top_pipe_mirror_xor #(
    parameter integer CLK_DIV     = 7,            // 25 MHz / 7 → ~3.5 MHz CE → ~28 kHz SCL
    parameter integer RING_STAGES = 5,            // ring-osc stages (production matches DUT bench): 1 XOR + 4 buffers. Drives BOTH the blake-clock divider and (downstream of that) the enclave-clock divider — cascaded power-of-2 dividers, no comparators.
    parameter integer ENCLAVE_DIV_LOG2 = 7,       // First-stage divider: ring_raw → enclave_clk = ring / 2^N. Measured on silicon: ring_raw ≈ 381 MHz → enclave_clk ≈ 2.98 MHz at /128. Target range 1-5 MHz: fast enough for BLAKE3 (Phase D Fmax 125 MHz — 40× margin) and any in-enclave compute, slow enough that the 25 MHz crystal-clocked 3-FF synchronisers in the OLED frequency counter (and any other clk-domain crossing) sample cleanly (~8.4× oversample). Pure binary-counter bit-tap (no comparator/subtractor).
    parameter integer WIRE_DIV_LOG2 = 8,          // Second-stage divider: enclave_clk → wire_clk = enclave / 2^N. Measured: 2.98 MHz / 256 = 11.6 kHz (within the 10-40 kHz target range). Slot rate (wire_clk/4) ≈ 2.9 kHz, slot ≈ 345 µs. Independent counter from the enclave divider.
    parameter [255:0] TX_PATTERN  = 256'h74207265766f2073706d756a20786f66206e776f7262206b6369757120656854  // FPGA TX bits, LSB-first. Source string "The quick brown fox jumps over t" (32 ASCII chars = 256 bits). Byte 0 'T' (G#54) lives in bits [7:0], so the first bit on the wire is the LSB of 'T' (0). Used in DATA mode only (gated by data_mode flag). 256-bit non-repeating-within-32 pattern lets the bridge verify bit-exact decode across all 256 rotations: a successful 256/256 match proves Claims 7+12 at the hardware-demo level. IDLE mode (pre-handshake) always sends 0 regardless of this parameter.
)(
    input  wire clk,                              // 25 MHz external crystal (P6)
    output wire oled_scl,
    output wire oled_sda,
    inout  wire pipe_pad,                         // bidirectional wire to the bridge (E16)
    output reg  led,
    // FPGA's own enclave TX mirror as an H-bridge pair driving a single piezo
    // (piezo between the two pins, not piezo-to-GND): doubles the swing across the
    // piezo from 3.3 V to 6.6 V peak-to-peak. Continuously holds the latched enclave
    // value thru host slots ("interpolate" = no audio gap between enclave updates,
    // just a stair-step at the FPGA-cycle rate).
    output wire piezo_enclave_p,                  // in-phase   (p42, M4)
    output wire piezo_enclave_n                   // anti-phase (p46, N4)
);

    localparam integer CELL_W      = `GLYPH_CELL_W;
    localparam integer CELL_H      = `GLYPH_CELL_H;
    localparam integer PAD_LEFT    = `GLYPH_PAD_LEFT;
    localparam integer MAX_ASCENT  = `GLYPH_MAX_ASCENT;
    localparam integer NUM_CHARS   = `GLYPH_NUM_CHARS;
    localparam [7:0]   FIRST_CHAR  = `GLYPH_FIRST_CHAR;

    localparam integer FB_W = 128;
    localparam integer FB_H = 64;

    localparam integer MAX_CHARS_PER_LINE = 24;
    localparam integer NUM_LINES = 4;
    localparam integer STR_LEN = NUM_LINES * MAX_CHARS_PER_LINE;

    // -------------------------------------------------------------------------
    // TRNG (29 ring oscillators) — same pattern as top_pin_id.
    // -------------------------------------------------------------------------
    wire [28:0] ro_out;
    genvar gi;
    generate
        for (gi = 0; gi < 29; gi = gi + 1) begin : ro_gen
            (* keep, syn_keep="true" *) wire fb_ro;
            (* keep *) LUT4 #(.INIT(16'h0100)) ro (
                .A(fb_ro), .B(1'b0), .C(1'b0), .D(1'b1), .Z(fb_ro)
            );
            assign ro_out[gi] = fb_ro;
        end
    endgenerate

    reg [28:0] ro_prev = 0;
    always @(posedge clk) ro_prev <= ro_out;
    wire [28:0] jitter = ro_out ^ ro_prev;

    wire [28:0] mixed;
    generate
        for (gi = 0; gi < 29; gi = gi + 1) begin : mix_gen
            assign mixed[gi] = jitter[gi] ^ jitter[(gi + 7) % 29] ^ jitter[(gi + 13) % 29];
        end
    endgenerate

    wire [7:0] trng_out = mixed[7:0] ^ mixed[15:8] ^ mixed[23:16] ^ {3'b0, mixed[28:24]};

    // -------------------------------------------------------------------------
    // Geiger-counter LED — canonical pattern from rtl/top_pin_id.v and
    // rtl/measure/top_dut_bench.v.
    // -------------------------------------------------------------------------
    reg [14:0] geiger_cnt = 0;
    always @(posedge clk) begin
        geiger_cnt <= geiger_cnt + 1;
        if (data_mode_q) begin
            // DATA mode (post-handshake): solid ON. Overrides geiger pattern.
            led <= 1'b1;
        end else if (&geiger_cnt) begin
            if (led && trng_out < 8'd8)            // OFF→ON: ~3% per sample
                led <= 1'b0;
            else if (!led && trng_out < 8'd100)    // ON→OFF: ~39% per sample
                led <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Ring oscillator → mod-N divider → wire_clk. BEL-pinned (same as
    // random/toggle) for build-to-build frequency consistency.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Two cascaded power-of-2 dividers, pure binary bit-tap (no comparator /
    // no subtractor — saves LUTs vs. a mod-N counter). Each counter free-runs
    // on its input clock; the top bit toggles at input/2^width, which IS the
    // output clock. Each output goes thru a DCCA buffer so it can drive
    // multiple FFs cleanly per Phase D's "ring fanout needs DCCA" lesson.
    //
    //   stage 1: ring_raw → enclave_clk      (= ring / 2^ENCLAVE_DIV_LOG2 → ~5.7 MHz)
    //   stage 2: enclave_clk → wire_clk   (= blake / 2^WIRE_DIV_LOG2 → ~22 kHz)
    //
    // Independence: stage 2 counter is clocked by enclave_clk, not by ring_raw.
    // No comparator, no reset, just a free-running counter whose MSB is the
    // output. Stages are cascaded for the protocol clock but enclave_clk is
    // independently usable (when BLAKE3 lands it'll clock off enclave_clk
    // directly without touching the enclave divider).
    // -------------------------------------------------------------------------
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
    // Slot-phase / slot-owner machinery — unchanged from slotted_oled.
    //   slot_phase: 0..3 per wire_clk → 4-wire_clk per slot
    //   slot_owner: 0 = enclave (FPGA drives), 1 = host (bridge drives, FPGA tristates)
    // -------------------------------------------------------------------------
    reg [1:0]  slot_phase = 2'd0;
    reg        slot_owner = 1'b0;
    always @(posedge wire_clk) begin
        slot_phase <= slot_phase + 1'b1;
        if (slot_phase == 2'd3) begin
            slot_owner <= ~slot_owner;
        end
    end

    // -------------------------------------------------------------------------
    // Claim 12 mirror-XOR codec.
    //
    // ENCODE: enclave_drive_value = OWN_IDLE_FPGA(=1) ^ fpga_tx_bit ^ bridge_last_decoded
    //   - Drive HIGH when value = 1, release (pulldown LOW) when value = 0.
    //   - drive_en = (slot_owner == 0) → only drive in enclave slot.
    //
    // DECODE: at slot_phase==2 during slot_owner==1 (mid-host-slot), latch
    //   wire_in into bridge_last_decoded. Used by the next enclave-slot encode.
    //
    // TX advance: fpga_tx_reg rotates right on every slot_owner 1→0 transition
    //   (host→enclave boundary) so a fresh LSB drives each enclave slot.
    //   Repeats TX_PATTERN indefinitely.
    //
    // Initial state matters for the very first enclave slot: bridge_last_decoded
    // starts at 0 (idle host-side convention). fpga_tx_reg starts at TX_PATTERN
    // so the LSB of TX_PATTERN drives slot 0. Wire pattern at startup with
    // bridge silent + TX_PATTERN=AAAAAAAA: enclave_drive[0] = 1^0^0 = 1 HIGH;
    // host slot 0 LOW (bridge silent); enclave_drive[1] uses TX bit 1 = 1, so
    // 1^1^0 = 0 LOW (release). Bridge sees HIGH-LOW-LOW-LOW-HIGH-LOW-LOW-LOW...
    // = a 4-slot-periodic edge pattern. cascade=1 (n=2 unfold) locks naturally.
    // -------------------------------------------------------------------------
    // Auto-clear threshold: how many consecutive bridge-silent host slots before
    // FPGA returns to IDLE. 4096 slots × ~23 µs = ~94 ms; longer than any current
    // test run, so a single handshake holds DATA mode for the entire run. Real
    // protocol traffic with mixed 0/1 bits keeps the counter mostly reset, so the
    // 94 ms ceiling only matters when the bridge has truly gone silent (handshake
    // complete or transmission ended). Power-of-2 sized counter ($clog2(4096)=12).
    localparam integer IDLE_CLEAR_SLOTS = 4096;
    localparam integer IDLE_CLEAR_W     = $clog2(IDLE_CLEAR_SLOTS);

    reg [255:0]             fpga_tx_reg = TX_PATTERN;
    reg                     data_mode = 1'b0;     // Claim 7b: 0 = IDLE (force own_data=0), 1 = DATA (use fpga_tx_reg[0])
    wire                    effective_fpga_tx_bit = data_mode ? fpga_tx_reg[0] : 1'b0;
    reg                     bridge_last_decoded = 1'b0;        // sampled mid-host-slot; idle host = 0
    reg                     prev_slot_owner = 1'b0;
    reg [IDLE_CLEAR_W-1:0]  silent_slot_cnt = 0;  // consecutive host slots with bridge_last_decoded=0

    wire wire_in_sync;                            // wire_in from wire_io's 2-FF synchroniser
    wire enclave_drive_value = 1'b1 ^ effective_fpga_tx_bit ^ bridge_last_decoded;
    wire wire_drive_en = ~slot_owner;

    // FPGA enclave-TX piezo H-bridge. Latch enclave_drive_value during enclave slots
    // and HOLD it thru the following host slot (= continuous "interpolate"; no audio
    // gap between enclave updates, just a stair-step at the FPGA-cycle rate). The two
    // output pins are anti-phase so the piezo (wired BETWEEN p42 M4 and p46 N4, NOT
    // pin-to-GND) sees 2× the swing — 6.6 V peak-to-peak instead of 3.3 V. LPF sets
    // DRIVE=4 (the lowest LVCMOS33 value; ECP5 LVCMOS33 doesn't go below — for ~2 mA
    // add a series resistor with the piezo). At slow-rate slot ~230 µs the toggle is
    // up to ~2.2 kHz, well in the audible range.
    reg piezo_value = 1'b0;
    always @(posedge wire_clk) begin
        if (slot_owner == 1'b0) begin
            piezo_value <= enclave_drive_value;
        end
    end
    assign piezo_enclave_p =  piezo_value;
    assign piezo_enclave_n = ~piezo_value;

    always @(posedge wire_clk) begin
        prev_slot_owner <= slot_owner;
        // host slot mid-sample → latch bridge's drive value as our decoded bit
        // AND check Claim 7b handshake / auto-clear conditions:
        //   bridge sent 1  → kick into DATA mode (or stay), reset silent count
        //   bridge sent 0  → increment silent count; if it saturates, drop to IDLE
        if (slot_owner == 1'b1 && slot_phase == 2'd2) begin
            bridge_last_decoded <= wire_in_sync;
            if (wire_in_sync == 1'b1) begin
                data_mode       <= 1'b1;
                silent_slot_cnt <= 0;
            end else begin
                if (silent_slot_cnt == IDLE_CLEAR_SLOTS - 1) begin
                    data_mode       <= 1'b0;
                    silent_slot_cnt <= 0;
                end else begin
                    silent_slot_cnt <= silent_slot_cnt + 1'b1;
                end
            end
        end
        // host→enclave transition → consume next TX bit (rotate right). Rotation
        // happens regardless of data_mode so pattern phase stays time-anchored;
        // effective_fpga_tx_bit gating decides whether the rotated bit reaches
        // the wire or gets masked to 0 (idle).
        if (prev_slot_owner == 1'b1 && slot_owner == 1'b0) begin
            fpga_tx_reg <= {fpga_tx_reg[0], fpga_tx_reg[255:1]};
        end
    end

    // -------------------------------------------------------------------------
    // data_mode → clk-domain LED override. data_mode lives on wire_clk; the
    // LED FSM (geiger_cnt block) lives on the 25 MHz clk domain. Cross with a
    // 3-stage synchroniser, then override the LED to solid ON when data_mode_q
    // is high. The geiger-pattern blink in IDLE mode → solid ON in DATA mode
    // is the visual confirmation that handshake fired.
    // -------------------------------------------------------------------------
    reg [2:0] data_mode_sync = 3'b0;
    always @(posedge clk) data_mode_sync <= {data_mode_sync[1:0], data_mode};
    wire data_mode_q = data_mode_sync[2];

    wire_io u_wire (
        .clk(wire_clk),
        .reset_n(1'b1),
        .drive_en(wire_drive_en),
        .wire_out(enclave_drive_value),
        .wire_in(wire_in_sync),
        .pad(pipe_pad)
    );

    // -------------------------------------------------------------------------
    // Frequency counters — TWO parallel: wire_clk (line 2) + enclave_clk (line 3).
    // Same genlocked pattern as random/slotted_oled, but cloned for enclave_clk so the
    // OLED shows both rate-divider taps. Each toggles a register on its own clock,
    // 3-FF synchronises into clk domain, counts the synced edges between frame_pulses,
    // multiplies by FREQ_MAGIC, BCDs the result, then a digit-write FSM streams the
    // digits into the strings array for its assigned line.
    // -------------------------------------------------------------------------
    reg         frame_pulse = 1'b0;

    // Enclave-clk counter
    reg  [31:0] freq_hz_wire  = 32'd0;
    reg         freq_valid_wire = 1'b0;
    reg meas_toggle_wire = 1'b0;
    always @(posedge wire_clk) meas_toggle_wire <= ~meas_toggle_wire;
    reg [2:0] toggle_sync_wire = 3'b0;
    always @(posedge clk) toggle_sync_wire <= {toggle_sync_wire[1:0], meas_toggle_wire};
    wire meas_edge_wire = toggle_sync_wire[2] ^ toggle_sync_wire[1];

    // Blake-clk counter (~5.7 MHz — same divider into clk domain works because
    // 25 MHz crystal > 2 × 5.7 MHz, Nyquist OK; 3-FF synchroniser handles the
    // metastability margin).
    reg  [31:0] freq_hz_en  = 32'd0;
    reg         freq_valid_en = 1'b0;
    reg meas_toggle_en = 1'b0;
    always @(posedge enclave_clk) meas_toggle_en <= ~meas_toggle_en;
    reg [2:0] toggle_sync_en = 3'b0;
    always @(posedge clk) toggle_sync_en <= {toggle_sync_en[1:0], meas_toggle_en};
    wire meas_edge_en = toggle_sync_en[2] ^ toggle_sync_en[1];

    localparam integer FREQ_MAGIC = 100;
    reg [23:0] edge_cnt_wire = 24'd0;
    reg [23:0] edge_cnt_en = 24'd0;
    always @(posedge clk) begin
        freq_valid_wire <= 1'b0;
        freq_valid_en <= 1'b0;
        if (frame_pulse) begin
            freq_hz_wire    <= edge_cnt_wire * FREQ_MAGIC;
            edge_cnt_wire   <= meas_edge_wire ? 24'd1 : 24'd0;
            freq_valid_wire <= 1'b1;
            freq_hz_en    <= edge_cnt_en * FREQ_MAGIC;
            edge_cnt_en   <= meas_edge_en ? 24'd1 : 24'd0;
            freq_valid_en <= 1'b1;
        end else begin
            if (meas_edge_wire) edge_cnt_wire <= edge_cnt_wire + 24'd1;
            if (meas_edge_en) edge_cnt_en <= edge_cnt_en + 24'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Binary → BCD — one per counter.
    // -------------------------------------------------------------------------
    localparam integer BCD_DIGITS = 8;
    localparam integer BIN_W      = 24;
    wire [BCD_DIGITS*4-1:0] bcd_wire;
    wire                    bcd_done_wire;
    bin_to_bcd #(.BIN_W(BIN_W), .BCD_DIGITS(BCD_DIGITS)) b2b_wire (
        .clk(clk), .reset_n(1'b1),
        .start(freq_valid_wire), .bin(freq_hz_wire[BIN_W-1:0]),
        .bcd(bcd_wire), .done(bcd_done_wire)
    );
    wire [BCD_DIGITS*4-1:0] bcd_en;
    wire                    bcd_done_en;
    bin_to_bcd #(.BIN_W(BIN_W), .BCD_DIGITS(BCD_DIGITS)) b2b_en (
        .clk(clk), .reset_n(1'b1),
        .start(freq_valid_en), .bin(freq_hz_en[BIN_W-1:0]),
        .bcd(bcd_en), .done(bcd_done_en)
    );

    // -------------------------------------------------------------------------
    // Framebuffer + glyph atlas + string register array — identical to random.
    // -------------------------------------------------------------------------
    reg [7:0] fb [0:FB_W * FB_H - 1];
    integer init_i;
    initial for (init_i = 0; init_i < FB_W * FB_H; init_i = init_i + 1) fb[init_i] = 8'h00;

    reg         fb_we = 0;
    reg [12:0]  fb_waddr = 0;
    reg [7:0]   fb_wdata = 0;
    reg [12:0]  fb_raddr = 0;
    reg [7:0]   fb_rdata = 0;

    always @(posedge clk) begin
        if (fb_we) fb[fb_waddr] <= fb_wdata;
        fb_rdata <= fb[fb_raddr];
    end

    localparam integer CELL_SIZE = CELL_W * CELL_H;
    localparam integer ATLAS_SIZE = NUM_CHARS * CELL_SIZE;

    reg [7:0] atlas [0:ATLAS_SIZE - 1];
    initial $readmemh("glyph_atlas.mem", atlas);

    reg [7:0] advance_w [0:NUM_CHARS - 1];
    initial $readmemh("glyph_advance.mem", advance_w);

    reg [7:0] strings [0:STR_LEN - 1];
    integer si;

    localparam integer LINE2_BASE       = 2 * MAX_CHARS_PER_LINE;
    localparam integer LINE2_DIGIT_BASE = LINE2_BASE + 4;
    localparam integer LINE2_DYN_LEN    = 9;
    localparam integer LINE3_BASE       = 3 * MAX_CHARS_PER_LINE;
    localparam integer LINE3_DIGIT_BASE = LINE3_BASE + 4;
    localparam integer LINE3_DYN_LEN    = 9;

    initial begin
        for (si = 0; si < STR_LEN; si = si + 1) strings[si] = 8'h00;
        strings[ 0] = "P"; strings[ 1] = "I"; strings[ 2] = "P"; strings[ 3] = "E";
        strings[24] = "M"; strings[25] = "I"; strings[26] = "R"; strings[27] = "R";
        strings[28] = "O"; strings[29] = "R"; strings[30] = "-"; strings[31] = "X";
        strings[32] = "O"; strings[33] = "R";
        // Line 2: "WI: X,XXX,XXX Hz" — wire_clk (protocol/slot timing, 10-40 kHz target)
        strings[LINE2_BASE + 0] = "W";
        strings[LINE2_BASE + 1] = "I";
        strings[LINE2_BASE + 2] = ":";
        strings[LINE2_BASE + 3] = " ";
        strings[LINE2_BASE + 4] = "0";
        strings[LINE2_BASE + 5] = ",";
        strings[LINE2_BASE + 6] = "0";
        strings[LINE2_BASE + 7] = "0";
        strings[LINE2_BASE + 8] = "0";
        strings[LINE2_BASE + 9] = ",";
        strings[LINE2_BASE +10] = "0";
        strings[LINE2_BASE +11] = "0";
        strings[LINE2_BASE +12] = "0";
        strings[LINE2_BASE +13] = " ";
        strings[LINE2_BASE +14] = "H";
        strings[LINE2_BASE +15] = "z";
        // Line 3: "EN: X,XXX,XXX Hz" — enclave_clk (= ring / 2^ENCLAVE_DIV_LOG2, 1-5 MHz internal compute / future BLAKE3 src)
        strings[LINE3_BASE + 0] = "E";
        strings[LINE3_BASE + 1] = "N";
        strings[LINE3_BASE + 2] = ":";
        strings[LINE3_BASE + 3] = " ";
        strings[LINE3_BASE + 4] = "0";
        strings[LINE3_BASE + 5] = ",";
        strings[LINE3_BASE + 6] = "0";
        strings[LINE3_BASE + 7] = "0";
        strings[LINE3_BASE + 8] = "0";
        strings[LINE3_BASE + 9] = ",";
        strings[LINE3_BASE +10] = "0";
        strings[LINE3_BASE +11] = "0";
        strings[LINE3_BASE +12] = "0";
        strings[LINE3_BASE +13] = " ";
        strings[LINE3_BASE +14] = "H";
        strings[LINE3_BASE +15] = "z";
    end

    // -------------------------------------------------------------------------
    // Digit-write FSMs — one per line. Each independently streams 9 chars
    // (4 digits, comma, 3 digits, comma, last digit) from its BCD into its
    // line's strings[] cells. re_render_req fires when EITHER finishes (a
    // single OR — the renderer will get the latest of both).
    // -------------------------------------------------------------------------
    reg       re_render_req   = 1'b0;

    // -------------------------------------------------------------------------
    // Inline per-FSM digit-char selection (no function — function call from two
    // FSMs was apparently being collapsed to one shared resource by synthesis,
    // leaving the second line's display showing 0).
    // -------------------------------------------------------------------------
    reg [3:0] digit_write_idx_wire = 4'd0;
    reg       seen_nonzero_wire    = 1'b0;
    reg [3:0] digit_write_idx_en = 4'd0;
    reg       seen_nonzero_en    = 1'b0;

    // Wire-line digit selection
    reg [3:0] d_wire;
    reg       is_comma_wire, is_digit_wire, is_last_wire;
    always @* begin
        is_comma_wire = 1'b0; is_digit_wire = 1'b0; is_last_wire = 1'b0; d_wire = 4'd0;
        case (digit_write_idx_wire)
            4'd1: begin is_digit_wire = 1'b1; d_wire = bcd_wire[27:24]; end
            4'd2: is_comma_wire = 1'b1;
            4'd3: begin is_digit_wire = 1'b1; d_wire = bcd_wire[23:20]; end
            4'd4: begin is_digit_wire = 1'b1; d_wire = bcd_wire[19:16]; end
            4'd5: begin is_digit_wire = 1'b1; d_wire = bcd_wire[15:12]; end
            4'd6: is_comma_wire = 1'b1;
            4'd7: begin is_digit_wire = 1'b1; d_wire = bcd_wire[11:8]; end
            4'd8: begin is_digit_wire = 1'b1; d_wire = bcd_wire[7:4]; end
            4'd9: begin is_digit_wire = 1'b1; d_wire = bcd_wire[3:0]; is_last_wire = 1'b1; end
            default: ;
        endcase
    end
    wire show_digit_wire = is_digit_wire && (seen_nonzero_wire || d_wire != 4'd0 || is_last_wire);
    wire [7:0] sel_char_wire = is_comma_wire ? (seen_nonzero_wire ? 8'h2C : 8'h20)
                            : show_digit_wire ? (8'h30 + {4'b0, d_wire})
                                              : 8'h20;

    // Enclave-line digit selection — INLINED, completely separate logic
    reg [3:0] d_en;
    reg       is_comma_en, is_digit_en, is_last_en;
    always @* begin
        is_comma_en = 1'b0; is_digit_en = 1'b0; is_last_en = 1'b0; d_en = 4'd0;
        case (digit_write_idx_en)
            4'd1: begin is_digit_en = 1'b1; d_en = bcd_en[27:24]; end
            4'd2: is_comma_en = 1'b1;
            4'd3: begin is_digit_en = 1'b1; d_en = bcd_en[23:20]; end
            4'd4: begin is_digit_en = 1'b1; d_en = bcd_en[19:16]; end
            4'd5: begin is_digit_en = 1'b1; d_en = bcd_en[15:12]; end
            4'd6: is_comma_en = 1'b1;
            4'd7: begin is_digit_en = 1'b1; d_en = bcd_en[11:8]; end
            4'd8: begin is_digit_en = 1'b1; d_en = bcd_en[7:4]; end
            4'd9: begin is_digit_en = 1'b1; d_en = bcd_en[3:0]; is_last_en = 1'b1; end
            default: ;
        endcase
    end
    wire show_digit_en = is_digit_en && (seen_nonzero_en || d_en != 4'd0 || is_last_en);
    wire [7:0] sel_char_en = is_comma_en ? (seen_nonzero_en ? 8'h2C : 8'h20)
                          : show_digit_en ? (8'h30 + {4'b0, d_en})
                                          : 8'h20;

    always @(posedge clk) begin
        if (bcd_done_wire) begin
            digit_write_idx_wire <= 4'd1;
            seen_nonzero_wire    <= 1'b0;
        end else if (digit_write_idx_wire != 4'd0) begin
            strings[LINE2_DIGIT_BASE + (digit_write_idx_wire - 1)] <= sel_char_wire;
            if (show_digit_wire) seen_nonzero_wire <= 1'b1;
            if (digit_write_idx_wire == LINE2_DYN_LEN[3:0]) begin
                digit_write_idx_wire <= 4'd0;
            end else begin
                digit_write_idx_wire <= digit_write_idx_wire + 4'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (bcd_done_en) begin
            digit_write_idx_en <= 4'd1;
            seen_nonzero_en    <= 1'b0;
        end else if (digit_write_idx_en != 4'd0) begin
            strings[LINE3_DIGIT_BASE + (digit_write_idx_en - 1)] <= sel_char_en;
            if (show_digit_en) seen_nonzero_en <= 1'b1;
            if (digit_write_idx_en == LINE3_DYN_LEN[3:0]) begin
                digit_write_idx_en <= 4'd0;
            end else begin
                digit_write_idx_en <= digit_write_idx_en + 4'd1;
            end
        end
    end

    always @(posedge clk) begin
        re_render_req <= 1'b0;
        if (digit_write_idx_wire == LINE2_DYN_LEN[3:0] || digit_write_idx_en == LINE3_DYN_LEN[3:0])
            re_render_req <= 1'b1;
    end

    function [6:0] line_baseline(input [1:0] ln);
        case (ln)
            2'd0: line_baseline = 7'd11;
            2'd1: line_baseline = 7'd27;
            2'd2: line_baseline = 7'd43;
            2'd3: line_baseline = 7'd59;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Renderer FSM — identical to random.
    // -------------------------------------------------------------------------
    localparam [3:0]
        R_BOOT     = 4'd0,
        R_CLEAR    = 4'd1,
        R_LOAD     = 4'd2,
        R_LATCH    = 4'd3,
        R_PX_READ  = 4'd4,
        R_PX_WRITE = 4'd5,
        R_ADV      = 4'd6,
        R_NEXT_LN  = 4'd7,
        R_DONE     = 4'd8;

    reg [3:0]  rstate     = R_BOOT;
    reg [4:0]  boot_cnt   = 0;
    reg [12:0] clear_addr = 0;
    reg [12:0] clear_end  = FB_W * FB_H - 1;
    reg        partial_mode = 1'b0;

    localparam integer LINE2_FB_START = 32 * FB_W;
    // Cover both dynamic lines (2 + 3) — clear bottom half on partial re-render.
    localparam integer LINE2_FB_END   = 64 * FB_W - 1;

    reg [1:0]  line_idx     = 0;
    reg [4:0]  char_in_line = 0;
    reg [6:0]  cursor_x     = 0;
    reg [7:0]  char_ascii   = 0;
    reg [6:0]  glyph_idx    = 0;
    reg [3:0]  px_i = 0;
    reg [3:0]  px_j = 0;

    wire signed [8:0] dst_x = $signed({2'b00, cursor_x}) - $signed({2'b00, PAD_LEFT[6:0]}) + $signed({5'b0, px_i});
    wire signed [8:0] dst_y = $signed({2'b00, line_baseline(line_idx)}) - $signed({2'b00, MAX_ASCENT[6:0]}) + $signed({5'b0, px_j});

    wire dst_in_range = (dst_x >= 0) && (dst_x < FB_W) && (dst_y >= 0) && (dst_y < FB_H);

    wire [14:0] atlas_addr = {glyph_idx, px_j[3:0], px_i[3:0]};
    reg  [7:0]  atlas_pix = 0;
    always @(posedge clk) atlas_pix <= atlas[atlas_addr];

    wire render_done = (rstate == R_DONE);

    always @(posedge clk) begin
        fb_we <= 1'b0;

        case (rstate)
            R_BOOT: begin
                boot_cnt <= boot_cnt + 1;
                if (&boot_cnt) begin
                    partial_mode <= 1'b0;
                    clear_addr   <= 13'd0;
                    clear_end    <= FB_W * FB_H - 1;
                    rstate       <= R_CLEAR;
                end
            end

            R_CLEAR: begin
                fb_we    <= 1'b1;
                fb_waddr <= clear_addr;
                fb_wdata <= 8'h00;
                if (clear_addr == clear_end) begin
                    line_idx     <= partial_mode ? 2'd2 : 2'd0;
                    char_in_line <= 0;
                    cursor_x     <= 0;
                    rstate       <= R_LOAD;
                end else begin
                    clear_addr <= clear_addr + 1;
                end
            end

            R_LOAD: begin
                char_ascii <= strings[line_idx * MAX_CHARS_PER_LINE + char_in_line];
                rstate     <= R_LATCH;
            end

            R_LATCH: begin
                if (char_ascii == 8'h00) begin
                    rstate <= R_NEXT_LN;
                end else begin
                    glyph_idx <= char_ascii - FIRST_CHAR;
                    px_i      <= 0;
                    px_j      <= 0;
                    rstate    <= R_PX_READ;
                end
            end

            R_PX_READ: begin
                rstate <= R_PX_WRITE;
            end

            R_PX_WRITE: begin
                if (atlas_pix != 0 && dst_in_range) begin
                    fb_waddr <= dst_y[6:0] * FB_W + dst_x[7:0];
                    fb_wdata <= atlas_pix;
                    fb_we    <= 1'b1;
                end
                rstate <= R_ADV;
            end

            R_ADV: begin
                if (px_i == CELL_W - 1) begin
                    px_i <= 0;
                    if (px_j == CELL_H - 1) begin
                        cursor_x     <= cursor_x + advance_w[glyph_idx];
                        char_in_line <= char_in_line + 1;
                        if (char_in_line == MAX_CHARS_PER_LINE - 1) begin
                            rstate <= R_NEXT_LN;
                        end else begin
                            rstate <= R_LOAD;
                        end
                        px_j <= 0;
                    end else begin
                        px_j   <= px_j + 1;
                        rstate <= R_PX_READ;
                    end
                end else begin
                    px_i   <= px_i + 1;
                    rstate <= R_PX_READ;
                end
            end

            R_NEXT_LN: begin
                // Always render to last line (NUM_LINES-1 = 3). partial_mode skips
                // the title lines 0+1 (= clears at line 2 start) but still walks
                // thru 2 → 3 → done. Previously stopped at line 2 in partial,
                // which is why the EN frequency on line 3 never rendered.
                if (line_idx == NUM_LINES - 1) begin
                    rstate <= R_DONE;
                end else begin
                    line_idx     <= line_idx + 1;
                    char_in_line <= 0;
                    cursor_x     <= 0;
                    rstate       <= R_LOAD;
                end
            end

            R_DONE: begin
                if (re_render_req) begin
                    partial_mode <= 1'b1;
                    clear_addr   <= LINE2_FB_START[12:0];
                    clear_end    <= LINE2_FB_END[12:0];
                    rstate       <= R_CLEAR;
                end
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // CE divider + I2C driver + SSD1306 init + OLED pump FSM — all identical
    // to random.
    // -------------------------------------------------------------------------
    reg [$clog2(CLK_DIV)-1:0] cnt = 0;
    wire at_top = (cnt == CLK_DIV - 1);
    always @(posedge clk) cnt <= at_top ? 0 : cnt + 1;
    reg ce = 0;
    always @(posedge clk) ce <= at_top;

    reg  [7:0] i2c_data;
    reg        i2c_start;
    reg        i2c_send_stop;
    wire       i2c_busy;

    ssd1306_i2c #(.CLK_DIV(CLK_DIV)) i2c (
        .clk(clk), .rst(1'b0),
        .data(i2c_data),
        .start(i2c_start),
        .send_start(1'b0),
        .send_stop(i2c_send_stop),
        .busy(i2c_busy),
        .scl(oled_scl), .sda(oled_sda)
    );

    localparam I2C_ADDR    = 8'h78;
    localparam CMD_PREFIX  = 8'h00;
    localparam DATA_PREFIX = 8'h40;
    localparam INIT_LEN    = 25;

    reg [7:0] init_cmds [0:INIT_LEN-1];
    initial begin
        init_cmds[ 0] = 8'hAE; init_cmds[ 1] = 8'hD5; init_cmds[ 2] = 8'h80;
        init_cmds[ 3] = 8'hA8; init_cmds[ 4] = 8'h3F; init_cmds[ 5] = 8'hD3;
        init_cmds[ 6] = 8'h00; init_cmds[ 7] = 8'h40; init_cmds[ 8] = 8'h8D;
        init_cmds[ 9] = 8'h14; init_cmds[10] = 8'hAD; init_cmds[11] = 8'h8B;
        init_cmds[12] = 8'hA1; init_cmds[13] = 8'hC8; init_cmds[14] = 8'hDA;
        init_cmds[15] = 8'h12; init_cmds[16] = 8'h81; init_cmds[17] = 8'hCF;
        init_cmds[18] = 8'hD9; init_cmds[19] = 8'hF1; init_cmds[20] = 8'hDB;
        init_cmds[21] = 8'h40; init_cmds[22] = 8'hA4; init_cmds[23] = 8'hA6;
        init_cmds[24] = 8'hAF;
    end

    localparam [2:0]
        ST_RESET   = 3'd0, ST_SEND   = 3'd1, ST_WAIT  = 3'd2,
        ST_NEXT    = 3'd3, ST_BUSFREE = 3'd4, ST_GATHER = 3'd5;

    localparam [1:0]
        PH_INIT      = 2'd0, PH_PAGE_CMD = 2'd1, PH_PAGE_DATA = 2'd2;

    reg [2:0]  state       = ST_RESET;
    reg [1:0]  phase       = PH_INIT;
    reg [19:0] reset_cnt   = 0;
    reg [9:0]  busfree_cnt = 0;
    reg [4:0]  cmd_idx     = 0;
    reg [2:0]  page        = 0;
    reg [6:0]  col         = 0;
    reg [7:0]  px_byte     = 0;
    reg [3:0]  gather_cnt  = 0;

    reg page_was_zero = 1'b1;
    always @(posedge clk) begin
        frame_pulse <= 1'b0;
        if (ce) begin
            if ((page == 3'd0) && !page_was_zero) frame_pulse <= 1'b1;
            page_was_zero <= (page == 3'd0);
        end
    end

    always @(posedge clk) if (ce) begin
        fb_raddr  <= {page, gather_cnt[2:0], col};
        i2c_start <= 0;

        case (state)
            ST_RESET: begin
                reset_cnt <= reset_cnt + 1;
                if (&reset_cnt && render_done) begin
                    phase   <= PH_INIT;
                    cmd_idx <= 0;
                    page    <= 0;
                    col     <= 0;
                    state   <= ST_SEND;
                end
            end

            ST_SEND: begin
                if (!i2c_busy) begin
                    case (phase)
                        PH_INIT: begin
                            if (cmd_idx == 0)         begin i2c_data <= I2C_ADDR;             i2c_send_stop <= 0; end
                            else if (cmd_idx == 1)    begin i2c_data <= CMD_PREFIX;           i2c_send_stop <= 0; end
                            else                      begin i2c_data <= init_cmds[cmd_idx-2]; i2c_send_stop <= (cmd_idx == INIT_LEN + 1); end
                        end
                        PH_PAGE_CMD: begin
                            case (cmd_idx[2:0])
                                3'd0: begin i2c_data <= I2C_ADDR;             i2c_send_stop <= 0; end
                                3'd1: begin i2c_data <= CMD_PREFIX;           i2c_send_stop <= 0; end
                                3'd2: begin i2c_data <= 8'hB0 | {5'd0, page}; i2c_send_stop <= 0; end
                                3'd3: begin i2c_data <= 8'h02;                i2c_send_stop <= 0; end
                                3'd4: begin i2c_data <= 8'h10;                i2c_send_stop <= 1; end
                                default: ;
                            endcase
                        end
                        PH_PAGE_DATA: begin
                            if (cmd_idx == 0)         begin i2c_data <= I2C_ADDR;    i2c_send_stop <= 0; end
                            else if (cmd_idx == 1)    begin i2c_data <= DATA_PREFIX; i2c_send_stop <= 0; end
                            else                      begin i2c_data <= px_byte;     i2c_send_stop <= (col == 7'd127); end
                        end
                    endcase
                    i2c_start <= 1;
                    state     <= ST_WAIT;
                end
            end

            ST_WAIT: begin
                if (i2c_busy) state <= ST_NEXT;
            end

            ST_NEXT: begin
                if (!i2c_busy) begin
                    case (phase)
                        PH_INIT: begin
                            if (cmd_idx == INIT_LEN + 1) begin
                                phase   <= PH_PAGE_CMD;
                                cmd_idx <= 0;
                                page    <= 0;
                                state   <= ST_BUSFREE;
                            end else begin
                                cmd_idx <= cmd_idx + 1;
                                state   <= ST_SEND;
                            end
                        end
                        PH_PAGE_CMD: begin
                            if (cmd_idx == 4) begin
                                phase      <= PH_PAGE_DATA;
                                cmd_idx    <= 0;
                                col        <= 0;
                                gather_cnt <= 0;
                                state      <= ST_BUSFREE;
                            end else begin
                                cmd_idx <= cmd_idx + 1;
                                state   <= ST_SEND;
                            end
                        end
                        PH_PAGE_DATA: begin
                            if (cmd_idx < 2) begin
                                cmd_idx <= cmd_idx + 1;
                                if (cmd_idx == 1) begin
                                    gather_cnt <= 0;
                                    state      <= ST_GATHER;
                                end else begin
                                    state <= ST_SEND;
                                end
                            end else if (col == 7'd127) begin
                                phase   <= PH_PAGE_CMD;
                                cmd_idx <= 0;
                                page    <= (page == 3'd7) ? 3'd0 : page + 1;
                                state   <= ST_BUSFREE;
                            end else begin
                                col        <= col + 1;
                                gather_cnt <= 0;
                                state      <= ST_GATHER;
                            end
                        end
                    endcase
                end
            end

            ST_BUSFREE: begin
                busfree_cnt <= busfree_cnt + 1;
                if (&busfree_cnt) begin
                    busfree_cnt <= 0;
                    state       <= ST_SEND;
                end
            end

            ST_GATHER: begin
                gather_cnt <= gather_cnt + 1;
                if (gather_cnt >= 4'd1) begin
                    px_byte <= {(fb_rdata >= trng_out), px_byte[7:1]};
                end
                if (gather_cnt == 4'd8) begin
                    gather_cnt <= 0;
                    state      <= ST_SEND;
                end
            end
        endcase
    end

endmodule
