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
//   With 4-enclave_clk-per-slot and the 2-FF wire_in synchroniser, mid-slot is
//   safely past bridge's drive settling. Becomes other_last_decoded_data for
//   the next enclave slot's encode.
//
// Handshake detection (Claim 7b):
//   At the same sample point, if wire_in is 1 and data_mode is 0, set
//   data_mode <= 1 permanently (until power-on reset). Bridge initiates by
//   driving its first non-idle bit; the wire transition is what we detect.
//   data_mode latches to 1 forever once seen — no clear, no timeout. Power
//   cycle to return to IDLE for fresh acquisition.
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
    parameter integer RING_STAGES = 5,            // ring-osc stages (production matches DUT bench)
    parameter integer RING_DIV    = 2048,         // mod-N divider on the ring → enclave_clk (matches slotted_oled 8× slowdown)
    parameter [31:0]  TX_PATTERN  = 32'hAAAAAAAA  // FPGA TX bits, LSB-first. Used in DATA mode only (gated by data_mode flag). Default = AAAAAAAA so post-handshake the wire pattern visibly differs from idle (50% transition density vs idle's 100%), making the handshake transition observable from bridge wire stats. IDLE mode (pre-handshake) always sends 0 regardless of this parameter, preserving wire_sync's clean-toggle acquisition target. For full bidirectional data exchange demo, set this to whatever payload the FPGA should transmit; bridge decodes it from its slot-aware position once it tracks data-mode wire pattern (Phase 2c).
)(
    input  wire clk,                              // 25 MHz external crystal (P6)
    output wire oled_scl,
    output wire oled_sda,
    inout  wire pipe_pad,                         // bidirectional wire to the bridge (E16)
    output reg  led
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
    // Ring oscillator → mod-N divider → enclave_clk. BEL-pinned (same as
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

    localparam integer DIV_HALF = (RING_DIV >> 1);
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
    // Slot-phase / slot-owner machinery — unchanged from slotted_oled.
    //   slot_phase: 0..3 per enclave_clk → 4-enclave_clk per slot
    //   slot_owner: 0 = enclave (FPGA drives), 1 = host (bridge drives, FPGA tristates)
    // -------------------------------------------------------------------------
    reg [1:0]  slot_phase = 2'd0;
    reg        slot_owner = 1'b0;
    always @(posedge enclave_clk) begin
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
    reg [31:0] fpga_tx_reg = TX_PATTERN;
    reg        data_mode = 1'b0;                  // Claim 7b: 0 = IDLE (force own_data=0), 1 = DATA (use fpga_tx_reg[0])
    wire       effective_fpga_tx_bit = data_mode ? fpga_tx_reg[0] : 1'b0;
    reg        bridge_last_decoded = 1'b0;        // sampled mid-host-slot; idle host = 0
    reg        prev_slot_owner = 1'b0;

    wire wire_in_sync;                            // wire_in from wire_io's 2-FF synchroniser
    wire enclave_drive_value = 1'b1 ^ effective_fpga_tx_bit ^ bridge_last_decoded;
    wire wire_drive_en = ~slot_owner;

    always @(posedge enclave_clk) begin
        prev_slot_owner <= slot_owner;
        // host slot mid-sample → latch bridge's drive value as our decoded bit
        // AND check Claim 7b handshake: bridge driving 1 in idle = data-mode kick-off
        if (slot_owner == 1'b1 && slot_phase == 2'd2) begin
            bridge_last_decoded <= wire_in_sync;
            if (wire_in_sync == 1'b1 && data_mode == 1'b0) begin
                data_mode <= 1'b1;
            end
        end
        // host→enclave transition → consume next TX bit (rotate right). Rotation
        // happens regardless of data_mode so pattern phase stays time-anchored;
        // effective_fpga_tx_bit gating decides whether the rotated bit reaches
        // the wire or gets masked to 0 (idle).
        if (prev_slot_owner == 1'b1 && slot_owner == 1'b0) begin
            fpga_tx_reg <= {fpga_tx_reg[0], fpga_tx_reg[31:1]};
        end
    end

    // -------------------------------------------------------------------------
    // data_mode → clk-domain LED override. data_mode lives on enclave_clk; the
    // LED FSM (geiger_cnt block) lives on the 25 MHz clk domain. Cross with a
    // 3-stage synchroniser, then override the LED to solid ON when data_mode_q
    // is high. The geiger-pattern blink in IDLE mode → solid ON in DATA mode
    // is the visual confirmation that handshake fired.
    // -------------------------------------------------------------------------
    reg [2:0] data_mode_sync = 3'b0;
    always @(posedge clk) data_mode_sync <= {data_mode_sync[1:0], data_mode};
    wire data_mode_q = data_mode_sync[2];

    wire_io u_wire (
        .clk(enclave_clk),
        .reset_n(1'b1),
        .drive_en(wire_drive_en),
        .wire_out(enclave_drive_value),
        .wire_in(wire_in_sync),
        .pad(pipe_pad)
    );

    // -------------------------------------------------------------------------
    // Frequency counter (genlocked) — unchanged from random.
    // -------------------------------------------------------------------------
    reg         frame_pulse = 1'b0;
    reg  [31:0] freq_hz     = 32'd0;
    reg         freq_valid  = 1'b0;

    reg meas_toggle = 1'b0;
    always @(posedge enclave_clk) meas_toggle <= ~meas_toggle;
    reg [2:0] toggle_sync = 3'b0;
    always @(posedge clk) toggle_sync <= {toggle_sync[1:0], meas_toggle};
    wire meas_edge = toggle_sync[2] ^ toggle_sync[1];

    localparam integer FREQ_MAGIC = 100;
    reg [23:0] edge_cnt = 24'd0;
    always @(posedge clk) begin
        freq_valid <= 1'b0;
        if (frame_pulse) begin
            freq_hz    <= edge_cnt * FREQ_MAGIC;
            edge_cnt   <= meas_edge ? 24'd1 : 24'd0;
            freq_valid <= 1'b1;
        end else if (meas_edge) begin
            edge_cnt <= edge_cnt + 24'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Binary → BCD.
    // -------------------------------------------------------------------------
    localparam integer BCD_DIGITS = 8;
    localparam integer BIN_W      = 24;
    wire [BCD_DIGITS*4-1:0] bcd;
    wire                    bcd_done;
    bin_to_bcd #(
        .BIN_W      (BIN_W),
        .BCD_DIGITS (BCD_DIGITS)
    ) b2b (
        .clk     (clk),
        .reset_n (1'b1),
        .start   (freq_valid),
        .bin     (freq_hz[BIN_W-1:0]),
        .bcd     (bcd),
        .done    (bcd_done)
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
    localparam integer LINE2_DIGIT_BASE = LINE2_BASE + 5;
    localparam integer LINE2_DYN_LEN    = 9;

    initial begin
        for (si = 0; si < STR_LEN; si = si + 1) strings[si] = 8'h00;
        strings[ 0] = "P"; strings[ 1] = "I"; strings[ 2] = "P"; strings[ 3] = "E";
        strings[24] = "M"; strings[25] = "I"; strings[26] = "R"; strings[27] = "R";
        strings[28] = "O"; strings[29] = "R"; strings[30] = "-"; strings[31] = "X";
        strings[32] = "O"; strings[33] = "R";
        strings[LINE2_BASE + 0] = "C";
        strings[LINE2_BASE + 1] = "L";
        strings[LINE2_BASE + 2] = "K";
        strings[LINE2_BASE + 3] = ":";
        strings[LINE2_BASE + 4] = " ";
        strings[LINE2_BASE + 5] = "0";
        strings[LINE2_BASE + 6] = ",";
        strings[LINE2_BASE + 7] = "0";
        strings[LINE2_BASE + 8] = "0";
        strings[LINE2_BASE + 9] = "0";
        strings[LINE2_BASE +10] = ",";
        strings[LINE2_BASE +11] = "0";
        strings[LINE2_BASE +12] = "0";
        strings[LINE2_BASE +13] = "0";
        strings[LINE2_BASE +14] = " ";
        strings[LINE2_BASE +15] = "H";
        strings[LINE2_BASE +16] = "z";
    end

    reg [3:0] digit_write_idx = 4'd0;
    reg       seen_nonzero    = 1'b0;
    reg       re_render_req   = 1'b0;

    reg [3:0] sel_digit;
    reg       sel_is_comma;
    reg       sel_is_digit;
    reg       sel_is_last;
    always @* begin
        sel_is_comma = 1'b0;
        sel_is_digit = 1'b0;
        sel_is_last  = 1'b0;
        sel_digit    = 4'd0;
        case (digit_write_idx)
            4'd1: begin sel_is_digit = 1'b1; sel_digit = bcd[27:24]; end
            4'd2: sel_is_comma = 1'b1;
            4'd3: begin sel_is_digit = 1'b1; sel_digit = bcd[23:20]; end
            4'd4: begin sel_is_digit = 1'b1; sel_digit = bcd[19:16]; end
            4'd5: begin sel_is_digit = 1'b1; sel_digit = bcd[15:12]; end
            4'd6: sel_is_comma = 1'b1;
            4'd7: begin sel_is_digit = 1'b1; sel_digit = bcd[11:8]; end
            4'd8: begin sel_is_digit = 1'b1; sel_digit = bcd[7:4]; end
            4'd9: begin sel_is_digit = 1'b1; sel_digit = bcd[3:0]; sel_is_last = 1'b1; end
            default: ;
        endcase
    end

    wire show_digit = sel_is_digit && (seen_nonzero || sel_digit != 4'd0 || sel_is_last);
    wire [7:0] sel_char = sel_is_comma ? (seen_nonzero ? 8'h2C : 8'h20)
                       : show_digit   ? (8'h30 + {4'b0, sel_digit})
                                       : 8'h20;

    always @(posedge clk) begin
        re_render_req <= 1'b0;
        if (bcd_done) begin
            digit_write_idx <= 4'd1;
            seen_nonzero    <= 1'b0;
        end else if (digit_write_idx != 4'd0) begin
            strings[LINE2_DIGIT_BASE + (digit_write_idx - 1)] <= sel_char;
            if (show_digit) seen_nonzero <= 1'b1;
            if (digit_write_idx == LINE2_DYN_LEN[3:0]) begin
                digit_write_idx <= 4'd0;
                re_render_req   <= 1'b1;
            end else begin
                digit_write_idx <= digit_write_idx + 4'd1;
            end
        end
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
    localparam integer LINE2_FB_END   = 48 * FB_W - 1;

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
                if (line_idx == NUM_LINES - 1 || (partial_mode && line_idx == 2'd2)) begin
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
