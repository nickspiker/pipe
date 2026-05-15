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
    input  wire [1:0]                                  mode,
    input  wire [255:0]                                ira,
    input  wire [2:0]                                  chip_state,
    input  wire [4:0]                                  ring_health_cnt,
    input  wire [8*SLOT_BITS-1:0]                      slot_flat,
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
    // =========================================================================
    wire [STR_LEN*8-1:0] strings_hex;
    genvar gh;
    generate
        for (gh = 0; gh < 64; gh = gh + 1) begin : hex_chars
            localparam integer LINE = gh / 16;
            localparam integer COL  = gh % 16;
            localparam integer SLOT = LINE * MAX_CHARS_PER_LINE + COL;
            wire [3:0] nib = ira[255 - 4*gh -: 4];
            assign strings_hex[SLOT*8 +: 8] = (nib < 4'd10)
                ? (8'h30 + {4'b0, nib})
                : (8'h41 + {4'b0, nib} - 8'd10);
        end
        for (gh = 0; gh < STR_LEN; gh = gh + 1) begin : pad_hex
            if (((gh % MAX_CHARS_PER_LINE) >= 16) || (gh / MAX_CHARS_PER_LINE) >= 4) begin
                assign strings_hex[gh*8 +: 8] = 8'h00;
            end
        end
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
    // Mode mux
    // =========================================================================
    assign strings_flat = (mode == 2'd1) ? strings_hex
                       : (mode == 2'd2) ? strings_otp
                       :                   strings_status;

endmodule
