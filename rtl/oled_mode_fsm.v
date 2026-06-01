// =============================================================================
// oled_mode_fsm.v — screen selector for the OLED text renderer
// =============================================================================
//
// Combinational mux that drives the 4-line × 24-char strings_flat input of
// oled_text_renderer.v from a mode index plus the current chip state.
//
// Screen layouts:
//
//   MODE 0 — STATUS
//     Line 0:  "PIPE STATUS"
//     Line 1:  state name ("VIRGIN" / "FUCKED" / "DEGRADED-2" / "DEGRADED-1" /
//              "HEALTHY")
//     Line 2:  "rings: N/16"  (N = ring_health_cnt)
//     Line 3:  (blank)
//
//   MODE 1 — IRA HEX
//     Lines 0-3: ira[255..0] as 64 hex chars (16 per line, MSB nibble top-left)
//
//   MODE 2 — OTP SLOTS
//     Line 0:  "P0 A:XXXX B:YYYY"   (pair 0: leading 4 hex of A and B slots)
//     Line 1:  "P1 A:XXXX B:YYYY"
//     Line 2:  "P2 A:XXXX B:YYYY"
//     Line 3:  "P3 A:XXXX B:YYYY"
//
//   MODE 3 — reserved (currently displays mode 0)
//
// Caller drives mode via the keypad (top maps Zil/Zila/Zilor → modes 0/1/2).
//
// =============================================================================

`timescale 1ns / 1ps

module oled_mode_fsm #(
    parameter integer N_LINES            = 4,
    parameter integer MAX_CHARS_PER_LINE = 24,
    parameter integer SLOT_BITS          = 256
) (
    input  wire [2:0]                                  mode,
    input  wire [255:0]                                ira,
    input  wire [2:0]                                  chip_state,
    input  wire [4:0]                                  ring_health_cnt,
    input  wire [8*SLOT_BITS-1:0]                      slot_flat,
    // Diagnostic surface for MODE 3 (HEALTH DETAIL)
    input  wire [15:0]                                 ring_rct_fail,
    input  wire [15:0]                                 ring_apt_fail,
    input  wire [111:0]                                ring_level_fail,  // 7 bits per ring
    // L3 observability — MODE 4 (WAIRUA HEX) + MODE 5 (L3 STATUS)
    input  wire [255:0]                                wairua,
    input  wire [4:0]                                  l3_state,
    input  wire [63:0]                                 l3_session_counter,
    input  wire [63:0]                                 l3_drop_counter,
    input  wire [31:0]                                 l3_h_req_finger,
    input  wire [31:0]                                 l3_h_resp_finger,
    input  wire                                        l3_last_mode_perm,
    input  wire                                        l3_last_was_query,
    input  wire                                        l3_session_valid,
    output wire [N_LINES*MAX_CHARS_PER_LINE*8-1:0]    strings_flat
);

    localparam integer STR_LEN = N_LINES * MAX_CHARS_PER_LINE;

    // -------------------------------------------------------------------------
    // Helper: 4-bit nibble → ASCII hex char ('0'..'9', 'A'..'F').
    // -------------------------------------------------------------------------
    function [7:0] nibble_to_ascii(input [3:0] n);
        nibble_to_ascii = (n < 4'd10) ? (8'h30 + {4'b0, n})
                                       : (8'h41 + {4'b0, n} - 8'd10);
    endfunction

    // =========================================================================
    // MODE 0 — STATUS text
    // =========================================================================
    reg [STR_LEN*8-1:0] strings_status;
    integer si;
    always @* begin
        for (si = 0; si < STR_LEN; si = si + 1)
            strings_status[si*8 +: 8] = 8'h00;

        // Line 0: "PIPE STATUS"
        strings_status[ 0*8 +: 8] = "P"; strings_status[ 1*8 +: 8] = "I";
        strings_status[ 2*8 +: 8] = "P"; strings_status[ 3*8 +: 8] = "E";
        strings_status[ 4*8 +: 8] = " ";
        strings_status[ 5*8 +: 8] = "S"; strings_status[ 6*8 +: 8] = "T";
        strings_status[ 7*8 +: 8] = "A"; strings_status[ 8*8 +: 8] = "T";
        strings_status[ 9*8 +: 8] = "U"; strings_status[10*8 +: 8] = "S";

        // Line 1 (slot 24..47): state name
        case (chip_state)
            3'd0: begin
                strings_status[(24+0)*8 +: 8] = "V"; strings_status[(24+1)*8 +: 8] = "I";
                strings_status[(24+2)*8 +: 8] = "R"; strings_status[(24+3)*8 +: 8] = "G";
                strings_status[(24+4)*8 +: 8] = "I"; strings_status[(24+5)*8 +: 8] = "N";
            end
            3'd1: begin
                strings_status[(24+0)*8 +: 8] = "F"; strings_status[(24+1)*8 +: 8] = "U";
                strings_status[(24+2)*8 +: 8] = "C"; strings_status[(24+3)*8 +: 8] = "K";
                strings_status[(24+4)*8 +: 8] = "E"; strings_status[(24+5)*8 +: 8] = "D";
            end
            3'd2: begin
                strings_status[(24+0)*8 +: 8] = "D"; strings_status[(24+1)*8 +: 8] = "E";
                strings_status[(24+2)*8 +: 8] = "G"; strings_status[(24+3)*8 +: 8] = "R";
                strings_status[(24+4)*8 +: 8] = "A"; strings_status[(24+5)*8 +: 8] = "D";
                strings_status[(24+6)*8 +: 8] = "E"; strings_status[(24+7)*8 +: 8] = "D";
                strings_status[(24+8)*8 +: 8] = "-"; strings_status[(24+9)*8 +: 8] = "2";
            end
            3'd3: begin
                strings_status[(24+0)*8 +: 8] = "D"; strings_status[(24+1)*8 +: 8] = "E";
                strings_status[(24+2)*8 +: 8] = "G"; strings_status[(24+3)*8 +: 8] = "R";
                strings_status[(24+4)*8 +: 8] = "A"; strings_status[(24+5)*8 +: 8] = "D";
                strings_status[(24+6)*8 +: 8] = "E"; strings_status[(24+7)*8 +: 8] = "D";
                strings_status[(24+8)*8 +: 8] = "-"; strings_status[(24+9)*8 +: 8] = "1";
            end
            3'd4: begin
                strings_status[(24+0)*8 +: 8] = "H"; strings_status[(24+1)*8 +: 8] = "E";
                strings_status[(24+2)*8 +: 8] = "A"; strings_status[(24+3)*8 +: 8] = "L";
                strings_status[(24+4)*8 +: 8] = "T"; strings_status[(24+5)*8 +: 8] = "H";
                strings_status[(24+6)*8 +: 8] = "Y";
            end
            default: begin
                strings_status[(24+0)*8 +: 8] = "?"; strings_status[(24+1)*8 +: 8] = "?";
                strings_status[(24+2)*8 +: 8] = "?";
            end
        endcase

        // Line 2 (slot 48..71): "rings: N/16"
        strings_status[(48+0)*8 +: 8] = "r"; strings_status[(48+1)*8 +: 8] = "i";
        strings_status[(48+2)*8 +: 8] = "n"; strings_status[(48+3)*8 +: 8] = "g";
        strings_status[(48+4)*8 +: 8] = "s"; strings_status[(48+5)*8 +: 8] = ":";
        strings_status[(48+6)*8 +: 8] = " ";
        if (ring_health_cnt >= 5'd10) begin
            strings_status[(48+7)*8 +: 8] = "1";
            strings_status[(48+8)*8 +: 8] = 8'h30 + {4'b0, ring_health_cnt[3:0] - 4'd10};
            strings_status[(48+9)*8 +: 8] = "/"; strings_status[(48+10)*8 +: 8] = "1";
            strings_status[(48+11)*8 +: 8] = "6";
        end else begin
            strings_status[(48+7)*8 +: 8] = 8'h30 + {4'b0, ring_health_cnt[3:0]};
            strings_status[(48+8)*8 +: 8] = "/"; strings_status[(48+9)*8 +: 8] = "1";
            strings_status[(48+10)*8 +: 8] = "6";
        end
    end

    // =========================================================================
    // MODE 1 — IRA HEX (64 nibbles in 4 rows of 16)
    //
    // Procedural always-block construction (same pattern as MODE 0 and MODE 2)
    // instead of a `generate for` loop with a variable bit slice. The
    // generate-loop form (`ira[255 - 4*gh -: 4]` with gh as a genvar)
    // produced consistent zeros in the high 28 bits of the displayed output
    // even when the underlying signal was correctly populated — a yosys
    // elaboration quirk in this particular construct. The procedural form
    // does the equivalent computation at the same combinational depth and
    // round-trips correctly.
    // =========================================================================
    // Helper function: 4-bit nibble → ASCII hex char.
    function [7:0] nib_to_ascii;
        input [3:0] n;
        nib_to_ascii = (n < 4'd10) ? (8'h30 + {4'b0, n})
                                    : (8'h41 + {4'b0, n} - 8'd10);
    endfunction

    // Render 16 nibbles of a 64-bit slot-piece into 16 ASCII chars (LSB nib
    // at top-left, MSB nib at bottom-right — same MSB-first display).
    // Mode 1 displays slot[0] (256 bits) split across 4 OLED lines × 16 chars.
    wire [STR_LEN*8-1:0] strings_hex;

    assign strings_hex[ 0*8 +: 8] = nib_to_ascii(slot_flat[255:252]);
    assign strings_hex[ 1*8 +: 8] = nib_to_ascii(slot_flat[251:248]);
    assign strings_hex[ 2*8 +: 8] = nib_to_ascii(slot_flat[247:244]);
    assign strings_hex[ 3*8 +: 8] = nib_to_ascii(slot_flat[243:240]);
    assign strings_hex[ 4*8 +: 8] = nib_to_ascii(slot_flat[239:236]);
    assign strings_hex[ 5*8 +: 8] = nib_to_ascii(slot_flat[235:232]);
    assign strings_hex[ 6*8 +: 8] = nib_to_ascii(slot_flat[231:228]);
    assign strings_hex[ 7*8 +: 8] = nib_to_ascii(slot_flat[227:224]);
    assign strings_hex[ 8*8 +: 8] = nib_to_ascii(slot_flat[223:220]);
    assign strings_hex[ 9*8 +: 8] = nib_to_ascii(slot_flat[219:216]);
    assign strings_hex[10*8 +: 8] = nib_to_ascii(slot_flat[215:212]);
    assign strings_hex[11*8 +: 8] = nib_to_ascii(slot_flat[211:208]);
    assign strings_hex[12*8 +: 8] = nib_to_ascii(slot_flat[207:204]);
    assign strings_hex[13*8 +: 8] = nib_to_ascii(slot_flat[203:200]);
    assign strings_hex[14*8 +: 8] = nib_to_ascii(slot_flat[199:196]);
    assign strings_hex[15*8 +: 8] = nib_to_ascii(slot_flat[195:192]);
    // Line 0 padding (chars 16-23) — NUL so renderer wraps to next line.
    genvar gpad0;
    generate
        for (gpad0 = 16; gpad0 < 24; gpad0 = gpad0 + 1)
            assign strings_hex[gpad0*8 +: 8] = 8'h00;
    endgenerate

    // Line 1: slot_flat[191:128]
    assign strings_hex[(24+ 0)*8 +: 8] = nib_to_ascii(slot_flat[191:188]);
    assign strings_hex[(24+ 1)*8 +: 8] = nib_to_ascii(slot_flat[187:184]);
    assign strings_hex[(24+ 2)*8 +: 8] = nib_to_ascii(slot_flat[183:180]);
    assign strings_hex[(24+ 3)*8 +: 8] = nib_to_ascii(slot_flat[179:176]);
    assign strings_hex[(24+ 4)*8 +: 8] = nib_to_ascii(slot_flat[175:172]);
    assign strings_hex[(24+ 5)*8 +: 8] = nib_to_ascii(slot_flat[171:168]);
    assign strings_hex[(24+ 6)*8 +: 8] = nib_to_ascii(slot_flat[167:164]);
    assign strings_hex[(24+ 7)*8 +: 8] = nib_to_ascii(slot_flat[163:160]);
    assign strings_hex[(24+ 8)*8 +: 8] = nib_to_ascii(slot_flat[159:156]);
    assign strings_hex[(24+ 9)*8 +: 8] = nib_to_ascii(slot_flat[155:152]);
    assign strings_hex[(24+10)*8 +: 8] = nib_to_ascii(slot_flat[151:148]);
    assign strings_hex[(24+11)*8 +: 8] = nib_to_ascii(slot_flat[147:144]);
    assign strings_hex[(24+12)*8 +: 8] = nib_to_ascii(slot_flat[143:140]);
    assign strings_hex[(24+13)*8 +: 8] = nib_to_ascii(slot_flat[139:136]);
    assign strings_hex[(24+14)*8 +: 8] = nib_to_ascii(slot_flat[135:132]);
    assign strings_hex[(24+15)*8 +: 8] = nib_to_ascii(slot_flat[131:128]);
    genvar gpad1;
    generate
        for (gpad1 = 16; gpad1 < 24; gpad1 = gpad1 + 1)
            assign strings_hex[(24+gpad1)*8 +: 8] = 8'h00;
    endgenerate

    // Line 2: slot_flat[127:64]
    assign strings_hex[(48+ 0)*8 +: 8] = nib_to_ascii(slot_flat[127:124]);
    assign strings_hex[(48+ 1)*8 +: 8] = nib_to_ascii(slot_flat[123:120]);
    assign strings_hex[(48+ 2)*8 +: 8] = nib_to_ascii(slot_flat[119:116]);
    assign strings_hex[(48+ 3)*8 +: 8] = nib_to_ascii(slot_flat[115:112]);
    assign strings_hex[(48+ 4)*8 +: 8] = nib_to_ascii(slot_flat[111:108]);
    assign strings_hex[(48+ 5)*8 +: 8] = nib_to_ascii(slot_flat[107:104]);
    assign strings_hex[(48+ 6)*8 +: 8] = nib_to_ascii(slot_flat[103:100]);
    assign strings_hex[(48+ 7)*8 +: 8] = nib_to_ascii(slot_flat[ 99: 96]);
    assign strings_hex[(48+ 8)*8 +: 8] = nib_to_ascii(slot_flat[ 95: 92]);
    assign strings_hex[(48+ 9)*8 +: 8] = nib_to_ascii(slot_flat[ 91: 88]);
    assign strings_hex[(48+10)*8 +: 8] = nib_to_ascii(slot_flat[ 87: 84]);
    assign strings_hex[(48+11)*8 +: 8] = nib_to_ascii(slot_flat[ 83: 80]);
    assign strings_hex[(48+12)*8 +: 8] = nib_to_ascii(slot_flat[ 79: 76]);
    assign strings_hex[(48+13)*8 +: 8] = nib_to_ascii(slot_flat[ 75: 72]);
    assign strings_hex[(48+14)*8 +: 8] = nib_to_ascii(slot_flat[ 71: 68]);
    assign strings_hex[(48+15)*8 +: 8] = nib_to_ascii(slot_flat[ 67: 64]);
    genvar gpad2;
    generate
        for (gpad2 = 16; gpad2 < 24; gpad2 = gpad2 + 1)
            assign strings_hex[(48+gpad2)*8 +: 8] = 8'h00;
    endgenerate

    // Line 3: slot_flat[63:0]
    assign strings_hex[(72+ 0)*8 +: 8] = nib_to_ascii(slot_flat[ 63: 60]);
    assign strings_hex[(72+ 1)*8 +: 8] = nib_to_ascii(slot_flat[ 59: 56]);
    assign strings_hex[(72+ 2)*8 +: 8] = nib_to_ascii(slot_flat[ 55: 52]);
    assign strings_hex[(72+ 3)*8 +: 8] = nib_to_ascii(slot_flat[ 51: 48]);
    assign strings_hex[(72+ 4)*8 +: 8] = nib_to_ascii(slot_flat[ 47: 44]);
    assign strings_hex[(72+ 5)*8 +: 8] = nib_to_ascii(slot_flat[ 43: 40]);
    assign strings_hex[(72+ 6)*8 +: 8] = nib_to_ascii(slot_flat[ 39: 36]);
    assign strings_hex[(72+ 7)*8 +: 8] = nib_to_ascii(slot_flat[ 35: 32]);
    assign strings_hex[(72+ 8)*8 +: 8] = nib_to_ascii(slot_flat[ 31: 28]);
    assign strings_hex[(72+ 9)*8 +: 8] = nib_to_ascii(slot_flat[ 27: 24]);
    assign strings_hex[(72+10)*8 +: 8] = nib_to_ascii(slot_flat[ 23: 20]);
    assign strings_hex[(72+11)*8 +: 8] = nib_to_ascii(slot_flat[ 19: 16]);
    assign strings_hex[(72+12)*8 +: 8] = nib_to_ascii(slot_flat[ 15: 12]);
    assign strings_hex[(72+13)*8 +: 8] = nib_to_ascii(slot_flat[ 11:  8]);
    assign strings_hex[(72+14)*8 +: 8] = nib_to_ascii(slot_flat[  7:  4]);
    assign strings_hex[(72+15)*8 +: 8] = nib_to_ascii(slot_flat[  3:  0]);
    genvar gpad3;
    generate
        for (gpad3 = 16; gpad3 < 24; gpad3 = gpad3 + 1)
            assign strings_hex[(72+gpad3)*8 +: 8] = 8'h00;
    endgenerate

    // =========================================================================
    // MODE 2 — OTP SLOTS — "Pk A:XXXX B:YYYY" per pair
    //   Pair k uses slot[k] for A and slot[k+4] for B.
    //   Show top 16 bits (4 hex chars) of each.
    // =========================================================================
    reg [STR_LEN*8-1:0] strings_otp;
    integer ki, ji;
    reg [3:0] otp_nib_a, otp_nib_b;
    always @* begin
        for (ji = 0; ji < STR_LEN; ji = ji + 1)
            strings_otp[ji*8 +: 8] = 8'h00;

        for (ki = 0; ki < 4; ki = ki + 1) begin
            // "Pk " prefix
            strings_otp[(ki*MAX_CHARS_PER_LINE + 0)*8 +: 8] = "P";
            strings_otp[(ki*MAX_CHARS_PER_LINE + 1)*8 +: 8] = 8'h30 + ki[7:0];
            strings_otp[(ki*MAX_CHARS_PER_LINE + 2)*8 +: 8] = " ";

            // "A:"
            strings_otp[(ki*MAX_CHARS_PER_LINE + 3)*8 +: 8] = "A";
            strings_otp[(ki*MAX_CHARS_PER_LINE + 4)*8 +: 8] = ":";

            // 4 hex chars from top of slot k (bits 255..240 of that slot)
            for (ji = 0; ji < 4; ji = ji + 1) begin
                otp_nib_a = slot_flat[(ki*SLOT_BITS + (SLOT_BITS - 4) - ji*4) +: 4];
                strings_otp[(ki*MAX_CHARS_PER_LINE + 5 + ji)*8 +: 8] =
                    (otp_nib_a < 4'd10) ? (8'h30 + {4'b0, otp_nib_a})
                                         : (8'h41 + {4'b0, otp_nib_a} - 8'd10);
            end

            // " B:"
            strings_otp[(ki*MAX_CHARS_PER_LINE + 9)*8 +: 8] = " ";
            strings_otp[(ki*MAX_CHARS_PER_LINE + 10)*8 +: 8] = "B";
            strings_otp[(ki*MAX_CHARS_PER_LINE + 11)*8 +: 8] = ":";

            // 4 hex chars from top of slot (k+4)
            for (ji = 0; ji < 4; ji = ji + 1) begin
                otp_nib_b = slot_flat[((ki+4)*SLOT_BITS + (SLOT_BITS - 4) - ji*4) +: 4];
                strings_otp[(ki*MAX_CHARS_PER_LINE + 12 + ji)*8 +: 8] =
                    (otp_nib_b < 4'd10) ? (8'h30 + {4'b0, otp_nib_b})
                                         : (8'h41 + {4'b0, otp_nib_b} - 8'd10);
            end
            // bytes 16..23 of this line stay as 0 (end-of-line)
        end
    end

    // =========================================================================
    // MODE 3 — RING HEALTH DETAIL
    //   4 rings per line, 4 lines = all 16 rings. Format per ring is "Ri:X"
    //   (4 chars) with a single space separator, leaving room to breathe so
    //   variable-width glyphs don't overlap into each other.
    //
    //     Line 0: R0:X R1:X R2:X R3:X     (19 chars)
    //     Line 1: R4:X R5:X R6:X R7:X
    //     Line 2: R8:X R9:X RA:X RB:X
    //     Line 3: RC:X RD:X RE:X RF:X
    //
    //   X encodes failing tests:
    //     0 = healthy   8 = RCT (sample stuck)
    //     4 = APT (biased)   2 = LVL (iter-GF(2) periodicity)
    //     combos OR together: A = RCT+LVL, C = RCT+APT, E = all three, etc.
    //   (Ring health count moves to MODE 0 STATUS screen.)
    // =========================================================================
    reg [STR_LEN*8-1:0] strings_health;
    reg [3:0]           rh_code;
    reg                 rh_lvl_any;
    integer hi, hj, hk;
    always @* begin
        for (hi = 0; hi < STR_LEN; hi = hi + 1)
            strings_health[hi*8 +: 8] = 8'h00;

        for (hi = 0; hi < 16; hi = hi + 1) begin
            hj = hi >> 2;                         // line index 0..3
            hk = hj * MAX_CHARS_PER_LINE + (hi & 5'd3) * 5;

            rh_lvl_any = |ring_level_fail[hi*7 +: 7];
            rh_code = {ring_rct_fail[hi], ring_apt_fail[hi], rh_lvl_any, 1'b0};

            // "Rh" — ring index as single hex digit (0..9, A..F)
            strings_health[(hk + 0)*8 +: 8] = "R";
            if (hi < 10)
                strings_health[(hk + 1)*8 +: 8] = 8'h30 + hi[7:0];
            else
                strings_health[(hk + 1)*8 +: 8] = 8'h41 + hi[7:0] - 8'd10;

            strings_health[(hk + 2)*8 +: 8] = ":";

            // Failure code as hex char
            strings_health[(hk + 3)*8 +: 8] = (rh_code < 4'd10)
                ? (8'h30 + {4'b0, rh_code})
                : (8'h41 + {4'b0, rh_code} - 8'd10);

            // Explicit space separator (NOT NUL — the renderer treats NUL as
            // end-of-line and aborts the rest of the line).
            if ((hi & 5'd3) != 5'd3)
                strings_health[(hk + 4)*8 +: 8] = " ";
        end
    end

    // =========================================================================
    // MODE 4 — WAIRUA HEX (session secret, 64 nibbles in 4 rows of 16)
    //
    // Same layout shape as MODE 1 (IRA HEX) but indexes the live `wairua`
    // session-secret register sourced from l3_session_fsm.wairua_disp. Goes to
    // all-zero on power-up; refreshes on each fresh-session Message A.
    // =========================================================================
    wire [STR_LEN*8-1:0] strings_wairua;

    // Line 0: wairua[255:192]
    assign strings_wairua[ 0*8 +: 8] = nib_to_ascii(wairua[255:252]);
    assign strings_wairua[ 1*8 +: 8] = nib_to_ascii(wairua[251:248]);
    assign strings_wairua[ 2*8 +: 8] = nib_to_ascii(wairua[247:244]);
    assign strings_wairua[ 3*8 +: 8] = nib_to_ascii(wairua[243:240]);
    assign strings_wairua[ 4*8 +: 8] = nib_to_ascii(wairua[239:236]);
    assign strings_wairua[ 5*8 +: 8] = nib_to_ascii(wairua[235:232]);
    assign strings_wairua[ 6*8 +: 8] = nib_to_ascii(wairua[231:228]);
    assign strings_wairua[ 7*8 +: 8] = nib_to_ascii(wairua[227:224]);
    assign strings_wairua[ 8*8 +: 8] = nib_to_ascii(wairua[223:220]);
    assign strings_wairua[ 9*8 +: 8] = nib_to_ascii(wairua[219:216]);
    assign strings_wairua[10*8 +: 8] = nib_to_ascii(wairua[215:212]);
    assign strings_wairua[11*8 +: 8] = nib_to_ascii(wairua[211:208]);
    assign strings_wairua[12*8 +: 8] = nib_to_ascii(wairua[207:204]);
    assign strings_wairua[13*8 +: 8] = nib_to_ascii(wairua[203:200]);
    assign strings_wairua[14*8 +: 8] = nib_to_ascii(wairua[199:196]);
    assign strings_wairua[15*8 +: 8] = nib_to_ascii(wairua[195:192]);
    genvar gwpad0;
    generate
        for (gwpad0 = 16; gwpad0 < 24; gwpad0 = gwpad0 + 1)
            assign strings_wairua[gwpad0*8 +: 8] = 8'h00;
    endgenerate

    // Line 1: wairua[191:128]
    assign strings_wairua[(24+ 0)*8 +: 8] = nib_to_ascii(wairua[191:188]);
    assign strings_wairua[(24+ 1)*8 +: 8] = nib_to_ascii(wairua[187:184]);
    assign strings_wairua[(24+ 2)*8 +: 8] = nib_to_ascii(wairua[183:180]);
    assign strings_wairua[(24+ 3)*8 +: 8] = nib_to_ascii(wairua[179:176]);
    assign strings_wairua[(24+ 4)*8 +: 8] = nib_to_ascii(wairua[175:172]);
    assign strings_wairua[(24+ 5)*8 +: 8] = nib_to_ascii(wairua[171:168]);
    assign strings_wairua[(24+ 6)*8 +: 8] = nib_to_ascii(wairua[167:164]);
    assign strings_wairua[(24+ 7)*8 +: 8] = nib_to_ascii(wairua[163:160]);
    assign strings_wairua[(24+ 8)*8 +: 8] = nib_to_ascii(wairua[159:156]);
    assign strings_wairua[(24+ 9)*8 +: 8] = nib_to_ascii(wairua[155:152]);
    assign strings_wairua[(24+10)*8 +: 8] = nib_to_ascii(wairua[151:148]);
    assign strings_wairua[(24+11)*8 +: 8] = nib_to_ascii(wairua[147:144]);
    assign strings_wairua[(24+12)*8 +: 8] = nib_to_ascii(wairua[143:140]);
    assign strings_wairua[(24+13)*8 +: 8] = nib_to_ascii(wairua[139:136]);
    assign strings_wairua[(24+14)*8 +: 8] = nib_to_ascii(wairua[135:132]);
    assign strings_wairua[(24+15)*8 +: 8] = nib_to_ascii(wairua[131:128]);
    genvar gwpad1;
    generate
        for (gwpad1 = 16; gwpad1 < 24; gwpad1 = gwpad1 + 1)
            assign strings_wairua[(24+gwpad1)*8 +: 8] = 8'h00;
    endgenerate

    // Line 2: wairua[127:64]
    assign strings_wairua[(48+ 0)*8 +: 8] = nib_to_ascii(wairua[127:124]);
    assign strings_wairua[(48+ 1)*8 +: 8] = nib_to_ascii(wairua[123:120]);
    assign strings_wairua[(48+ 2)*8 +: 8] = nib_to_ascii(wairua[119:116]);
    assign strings_wairua[(48+ 3)*8 +: 8] = nib_to_ascii(wairua[115:112]);
    assign strings_wairua[(48+ 4)*8 +: 8] = nib_to_ascii(wairua[111:108]);
    assign strings_wairua[(48+ 5)*8 +: 8] = nib_to_ascii(wairua[107:104]);
    assign strings_wairua[(48+ 6)*8 +: 8] = nib_to_ascii(wairua[103:100]);
    assign strings_wairua[(48+ 7)*8 +: 8] = nib_to_ascii(wairua[ 99: 96]);
    assign strings_wairua[(48+ 8)*8 +: 8] = nib_to_ascii(wairua[ 95: 92]);
    assign strings_wairua[(48+ 9)*8 +: 8] = nib_to_ascii(wairua[ 91: 88]);
    assign strings_wairua[(48+10)*8 +: 8] = nib_to_ascii(wairua[ 87: 84]);
    assign strings_wairua[(48+11)*8 +: 8] = nib_to_ascii(wairua[ 83: 80]);
    assign strings_wairua[(48+12)*8 +: 8] = nib_to_ascii(wairua[ 79: 76]);
    assign strings_wairua[(48+13)*8 +: 8] = nib_to_ascii(wairua[ 75: 72]);
    assign strings_wairua[(48+14)*8 +: 8] = nib_to_ascii(wairua[ 71: 68]);
    assign strings_wairua[(48+15)*8 +: 8] = nib_to_ascii(wairua[ 67: 64]);
    genvar gwpad2;
    generate
        for (gwpad2 = 16; gwpad2 < 24; gwpad2 = gwpad2 + 1)
            assign strings_wairua[(48+gwpad2)*8 +: 8] = 8'h00;
    endgenerate

    // Line 3: wairua[63:0]
    assign strings_wairua[(72+ 0)*8 +: 8] = nib_to_ascii(wairua[ 63: 60]);
    assign strings_wairua[(72+ 1)*8 +: 8] = nib_to_ascii(wairua[ 59: 56]);
    assign strings_wairua[(72+ 2)*8 +: 8] = nib_to_ascii(wairua[ 55: 52]);
    assign strings_wairua[(72+ 3)*8 +: 8] = nib_to_ascii(wairua[ 51: 48]);
    assign strings_wairua[(72+ 4)*8 +: 8] = nib_to_ascii(wairua[ 47: 44]);
    assign strings_wairua[(72+ 5)*8 +: 8] = nib_to_ascii(wairua[ 43: 40]);
    assign strings_wairua[(72+ 6)*8 +: 8] = nib_to_ascii(wairua[ 39: 36]);
    assign strings_wairua[(72+ 7)*8 +: 8] = nib_to_ascii(wairua[ 35: 32]);
    assign strings_wairua[(72+ 8)*8 +: 8] = nib_to_ascii(wairua[ 31: 28]);
    assign strings_wairua[(72+ 9)*8 +: 8] = nib_to_ascii(wairua[ 27: 24]);
    assign strings_wairua[(72+10)*8 +: 8] = nib_to_ascii(wairua[ 23: 20]);
    assign strings_wairua[(72+11)*8 +: 8] = nib_to_ascii(wairua[ 19: 16]);
    assign strings_wairua[(72+12)*8 +: 8] = nib_to_ascii(wairua[ 15: 12]);
    assign strings_wairua[(72+13)*8 +: 8] = nib_to_ascii(wairua[ 11:  8]);
    assign strings_wairua[(72+14)*8 +: 8] = nib_to_ascii(wairua[  7:  4]);
    assign strings_wairua[(72+15)*8 +: 8] = nib_to_ascii(wairua[  3:  0]);
    genvar gwpad3;
    generate
        for (gwpad3 = 16; gwpad3 < 24; gwpad3 = gwpad3 + 1)
            assign strings_wairua[(72+gwpad3)*8 +: 8] = 8'h00;
    endgenerate

    // =========================================================================
    // MODE 5 — L3 STATUS panel
    //
    //   Line 0: "L3 ST=NN  M:S|P Q:Y|N V:V|-"
    //   Line 1: "SES <session_counter[31:0] hex>"
    //   Line 2: "DRP <drop_counter[31:0] hex>"
    //   Line 3: "<h_req_finger 8hex> <h_resp_finger 8hex>"
    //
    // State number is 2-digit decimal (l3_state fits in 5 bits → max 31).
    // M=last_mode_perm: S=SESSION, P=PERMANENT
    // Q=last_was_query: Y/N
    // V=session_valid: V (valid) / - (not yet)
    // =========================================================================
    reg [STR_LEN*8-1:0] strings_l3;
    integer li;
    always @* begin
        for (li = 0; li < STR_LEN; li = li + 1)
            strings_l3[li*8 +: 8] = 8'h00;

        // Line 0: "L3 ST=DD  M:c Q:c V:c"
        strings_l3[ 0*8 +: 8] = "L"; strings_l3[ 1*8 +: 8] = "3";
        strings_l3[ 2*8 +: 8] = " ";
        strings_l3[ 3*8 +: 8] = "S"; strings_l3[ 4*8 +: 8] = "T";
        strings_l3[ 5*8 +: 8] = "=";
        // 2-digit decimal (max 31)
        strings_l3[ 6*8 +: 8] = (l3_state >= 5'd10) ? 8'h30 + ((l3_state >= 5'd20) ? 8'd2 : 8'd1)
                                                   : 8'h30;
        strings_l3[ 7*8 +: 8] = 8'h30 + ((l3_state >= 5'd20) ? (l3_state - 5'd20)
                                       : (l3_state >= 5'd10) ? (l3_state - 5'd10)
                                       :                       l3_state);
        strings_l3[ 8*8 +: 8] = " "; strings_l3[ 9*8 +: 8] = " ";
        strings_l3[10*8 +: 8] = "M"; strings_l3[11*8 +: 8] = ":";
        strings_l3[12*8 +: 8] = l3_last_mode_perm ? "P" : "S";
        strings_l3[13*8 +: 8] = " ";
        strings_l3[14*8 +: 8] = "Q"; strings_l3[15*8 +: 8] = ":";
        strings_l3[16*8 +: 8] = l3_last_was_query ? "Y" : "N";
        strings_l3[17*8 +: 8] = " ";
        strings_l3[18*8 +: 8] = "V"; strings_l3[19*8 +: 8] = ":";
        strings_l3[20*8 +: 8] = l3_session_valid ? "V" : "-";

        // Line 1: "SES " + low 32 bits of session_counter as 8 hex
        strings_l3[(24+ 0)*8 +: 8] = "S";
        strings_l3[(24+ 1)*8 +: 8] = "E";
        strings_l3[(24+ 2)*8 +: 8] = "S";
        strings_l3[(24+ 3)*8 +: 8] = " ";
        strings_l3[(24+ 4)*8 +: 8] = nib_to_ascii(l3_session_counter[31:28]);
        strings_l3[(24+ 5)*8 +: 8] = nib_to_ascii(l3_session_counter[27:24]);
        strings_l3[(24+ 6)*8 +: 8] = nib_to_ascii(l3_session_counter[23:20]);
        strings_l3[(24+ 7)*8 +: 8] = nib_to_ascii(l3_session_counter[19:16]);
        strings_l3[(24+ 8)*8 +: 8] = nib_to_ascii(l3_session_counter[15:12]);
        strings_l3[(24+ 9)*8 +: 8] = nib_to_ascii(l3_session_counter[11: 8]);
        strings_l3[(24+10)*8 +: 8] = nib_to_ascii(l3_session_counter[ 7: 4]);
        strings_l3[(24+11)*8 +: 8] = nib_to_ascii(l3_session_counter[ 3: 0]);

        // Line 2: "DRP " + low 32 bits of drop_counter as 8 hex
        strings_l3[(48+ 0)*8 +: 8] = "D";
        strings_l3[(48+ 1)*8 +: 8] = "R";
        strings_l3[(48+ 2)*8 +: 8] = "P";
        strings_l3[(48+ 3)*8 +: 8] = " ";
        strings_l3[(48+ 4)*8 +: 8] = nib_to_ascii(l3_drop_counter[31:28]);
        strings_l3[(48+ 5)*8 +: 8] = nib_to_ascii(l3_drop_counter[27:24]);
        strings_l3[(48+ 6)*8 +: 8] = nib_to_ascii(l3_drop_counter[23:20]);
        strings_l3[(48+ 7)*8 +: 8] = nib_to_ascii(l3_drop_counter[19:16]);
        strings_l3[(48+ 8)*8 +: 8] = nib_to_ascii(l3_drop_counter[15:12]);
        strings_l3[(48+ 9)*8 +: 8] = nib_to_ascii(l3_drop_counter[11: 8]);
        strings_l3[(48+10)*8 +: 8] = nib_to_ascii(l3_drop_counter[ 7: 4]);
        strings_l3[(48+11)*8 +: 8] = nib_to_ascii(l3_drop_counter[ 3: 0]);

        // Line 3: "<h_req_finger 8hex> <h_resp_finger 8hex>"
        strings_l3[(72+ 0)*8 +: 8] = nib_to_ascii(l3_h_req_finger[31:28]);
        strings_l3[(72+ 1)*8 +: 8] = nib_to_ascii(l3_h_req_finger[27:24]);
        strings_l3[(72+ 2)*8 +: 8] = nib_to_ascii(l3_h_req_finger[23:20]);
        strings_l3[(72+ 3)*8 +: 8] = nib_to_ascii(l3_h_req_finger[19:16]);
        strings_l3[(72+ 4)*8 +: 8] = nib_to_ascii(l3_h_req_finger[15:12]);
        strings_l3[(72+ 5)*8 +: 8] = nib_to_ascii(l3_h_req_finger[11: 8]);
        strings_l3[(72+ 6)*8 +: 8] = nib_to_ascii(l3_h_req_finger[ 7: 4]);
        strings_l3[(72+ 7)*8 +: 8] = nib_to_ascii(l3_h_req_finger[ 3: 0]);
        strings_l3[(72+ 8)*8 +: 8] = " ";
        strings_l3[(72+ 9)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[31:28]);
        strings_l3[(72+10)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[27:24]);
        strings_l3[(72+11)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[23:20]);
        strings_l3[(72+12)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[19:16]);
        strings_l3[(72+13)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[15:12]);
        strings_l3[(72+14)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[11: 8]);
        strings_l3[(72+15)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[ 7: 4]);
        strings_l3[(72+16)*8 +: 8] = nib_to_ascii(l3_h_resp_finger[ 3: 0]);
    end

    // =========================================================================
    // Mode mux
    // =========================================================================
    assign strings_flat = (mode == 3'd1) ? strings_hex
                       : (mode == 3'd2) ? strings_otp
                       : (mode == 3'd3) ? strings_health
                       : (mode == 3'd4) ? strings_wairua
                       : (mode == 3'd5) ? strings_l3
                       :                   strings_status;

endmodule
