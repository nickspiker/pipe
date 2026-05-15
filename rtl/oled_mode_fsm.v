// =============================================================================
// oled_mode_fsm.v — screen selector for the OLED text renderer
// =============================================================================
//
// Combinational mux that drives the 4-line × 24-char strings_flat input of
// oled_text_renderer.v from a mode index plus the current chip state. Each
// screen has its own 768-bit literal-text composition; the mode signal
// selects which one to expose.
//
// Screen layouts (V1):
//
//   MODE 0 — IRA HEX
//     Line 0:  ira[255..192] as 16 hex chars
//     Line 1:  ira[191..128] as 16 hex chars
//     Line 2:  ira[127..64]  as 16 hex chars
//     Line 3:  ira[63..0]    as 16 hex chars
//
//   MODE 1 — STATUS
//     Line 0:  "PIPE STATUS"
//     Line 1:  state name ("VIRGIN" / "FUCKED" / "DEGRADED-2" / "DEGRADED-1" /
//              "HEALTHY")
//     Line 2:  "rings: N/16"  (N = ring_health_cnt)
//     Line 3:  (blank — reserved for future ceremony progress)
//
// Caller drives mode via the keypad / button — typically one button cycles
// through modes 0..N_MODES-1 wrapping.
//
// =============================================================================

`timescale 1ns / 1ps

module oled_mode_fsm #(
    parameter integer N_LINES            = 4,
    parameter integer MAX_CHARS_PER_LINE = 24
) (
    input  wire [0:0]                                  mode,           // 0=ira hex, 1=status
    input  wire [255:0]                                ira,
    input  wire [2:0]                                  chip_state,
    input  wire [4:0]                                  ring_health_cnt, // 0..16
    output wire [N_LINES*MAX_CHARS_PER_LINE*8-1:0]    strings_flat
);

    localparam integer STR_LEN = N_LINES * MAX_CHARS_PER_LINE;

    // -------------------------------------------------------------------------
    // MODE 0 — ira hex. 64 nibbles → 64 ASCII chars in 4 rows of 16.
    // -------------------------------------------------------------------------
    wire [STR_LEN*8-1:0] strings_hex;
    genvar gh;
    generate
        for (gh = 0; gh < 64; gh = gh + 1) begin : hex_chars
            localparam integer LINE = gh / 16;
            localparam integer COL  = gh % 16;
            localparam integer SLOT = LINE * MAX_CHARS_PER_LINE + COL;
            wire [3:0] nib = ira[255 - 4*gh -: 4];
            assign strings_hex[SLOT*8 +: 8] = (nib < 4'd10)
                ? (8'h30 + {4'b0, nib})              // '0'..'9'
                : (8'h41 + {4'b0, nib} - 8'd10);     // 'A'..'F'
        end
        for (gh = 0; gh < STR_LEN; gh = gh + 1) begin : pad_hex
            if (((gh % MAX_CHARS_PER_LINE) >= 16) || (gh / MAX_CHARS_PER_LINE) >= 4) begin
                assign strings_hex[gh*8 +: 8] = 8'h00;
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // MODE 1 — status text. Per-character writes (combinational always block)
    // mux the text by chip_state. Anything not explicitly set defaults to 0
    // (= end-of-line marker for the renderer).
    // -------------------------------------------------------------------------
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

        // Line 1 (slots 24..47): state name
        case (chip_state)
            3'd0: begin // VIRGIN
                strings_status[(24+0)*8 +: 8] = "V"; strings_status[(24+1)*8 +: 8] = "I";
                strings_status[(24+2)*8 +: 8] = "R"; strings_status[(24+3)*8 +: 8] = "G";
                strings_status[(24+4)*8 +: 8] = "I"; strings_status[(24+5)*8 +: 8] = "N";
            end
            3'd1: begin // FUCKED
                strings_status[(24+0)*8 +: 8] = "F"; strings_status[(24+1)*8 +: 8] = "U";
                strings_status[(24+2)*8 +: 8] = "C"; strings_status[(24+3)*8 +: 8] = "K";
                strings_status[(24+4)*8 +: 8] = "E"; strings_status[(24+5)*8 +: 8] = "D";
            end
            3'd2: begin // DEGRADED-2
                strings_status[(24+0)*8 +: 8] = "D"; strings_status[(24+1)*8 +: 8] = "E";
                strings_status[(24+2)*8 +: 8] = "G"; strings_status[(24+3)*8 +: 8] = "R";
                strings_status[(24+4)*8 +: 8] = "A"; strings_status[(24+5)*8 +: 8] = "D";
                strings_status[(24+6)*8 +: 8] = "E"; strings_status[(24+7)*8 +: 8] = "D";
                strings_status[(24+8)*8 +: 8] = "-"; strings_status[(24+9)*8 +: 8] = "2";
            end
            3'd3: begin // DEGRADED-1
                strings_status[(24+0)*8 +: 8] = "D"; strings_status[(24+1)*8 +: 8] = "E";
                strings_status[(24+2)*8 +: 8] = "G"; strings_status[(24+3)*8 +: 8] = "R";
                strings_status[(24+4)*8 +: 8] = "A"; strings_status[(24+5)*8 +: 8] = "D";
                strings_status[(24+6)*8 +: 8] = "E"; strings_status[(24+7)*8 +: 8] = "D";
                strings_status[(24+8)*8 +: 8] = "-"; strings_status[(24+9)*8 +: 8] = "1";
            end
            3'd4: begin // HEALTHY
                strings_status[(24+0)*8 +: 8] = "H"; strings_status[(24+1)*8 +: 8] = "E";
                strings_status[(24+2)*8 +: 8] = "A"; strings_status[(24+3)*8 +: 8] = "L";
                strings_status[(24+4)*8 +: 8] = "T"; strings_status[(24+5)*8 +: 8] = "H";
                strings_status[(24+6)*8 +: 8] = "Y";
            end
            default: begin // "????"
                strings_status[(24+0)*8 +: 8] = "?"; strings_status[(24+1)*8 +: 8] = "?";
                strings_status[(24+2)*8 +: 8] = "?";
            end
        endcase

        // Line 2 (slots 48..71): "rings: N/16"
        strings_status[(48+0)*8 +: 8] = "r"; strings_status[(48+1)*8 +: 8] = "i";
        strings_status[(48+2)*8 +: 8] = "n"; strings_status[(48+3)*8 +: 8] = "g";
        strings_status[(48+4)*8 +: 8] = "s"; strings_status[(48+5)*8 +: 8] = ":";
        strings_status[(48+6)*8 +: 8] = " ";
        // ring_health_cnt: 0..16. Show as 1 or 2 digits.
        if (ring_health_cnt >= 5'd10) begin
            strings_status[(48+7)*8 +: 8] = 8'h30 + {7'b0, ring_health_cnt >= 5'd16, ring_health_cnt[3:0] >= 4'd6, ring_health_cnt >= 5'd10};
            // tens digit (1)
            strings_status[(48+7)*8 +: 8] = "1";
            strings_status[(48+8)*8 +: 8] = 8'h30 + {4'b0, ring_health_cnt[3:0] - 4'd10};
            strings_status[(48+9)*8 +: 8] = "/"; strings_status[(48+10)*8 +: 8] = "1";
            strings_status[(48+11)*8 +: 8] = "6";
        end else begin
            strings_status[(48+7)*8 +: 8] = 8'h30 + {4'b0, ring_health_cnt[3:0]};
            strings_status[(48+8)*8 +: 8] = "/"; strings_status[(48+9)*8 +: 8] = "1";
            strings_status[(48+10)*8 +: 8] = "6";
        end

        // Line 3 (slots 72..95): reserved blank
    end

    // -------------------------------------------------------------------------
    // Mux
    // -------------------------------------------------------------------------
    assign strings_flat = (mode == 1'b0) ? strings_hex : strings_status;

endmodule
