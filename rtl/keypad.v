// =============================================================================
// keypad.v — Dozenal 18-key keypad scanner (3-phase, bidirectional)
// =============================================================================
//
// Implements the scanner described in KEYPAD.md for the PIPE dozenal keypad:
// 4×4 active-low matrix (rows p27/p28/p44/p51 × cols p49/p63/p62/p56) plus
// the Multiply special key (p62 to GND) plus three ad-hoc keys (Divide,
// Decimal, Negate) on dedicated pin pairs.
//
// All 11 pins routed through ECP5 BB (bidirectional buffer) primitives.
// Yosys's tri-state inference via `assign pin = drive ? 1'b0 : 1'bz` is
// flagged as "limited support" and doesn't reliably produce IOBUFs on
// ECP5 — explicit BB instantiation is the safe path.
//
// Scan phases (8 total, ~40 µs each at 25 MHz, full scan ≈ 330 µs):
//   phase 0  — all pins tristate; read p62. p62 low → Multiply pressed
//   phase 1  — drive p27 LOW (row 0), read p49/p63/p62/p56
//   phase 2  — drive p28 LOW (row 1)
//   phase 3  — drive p44 LOW (row 2)
//   phase 4  — drive p51 LOW (row 3)
//   phase 5  — drive p58 LOW, read p63 → Divide
//   phase 6  — drive p57 LOW, read p44 → Decimal
//   phase 7  — drive p50 LOW, read p62 → Negate
//
// Multiply masking: during phases 1-4, if multiply_held was latched from
// phase 0, any "press" on column p62 (col 2) is ignored — Multiply's
// short-to-GND would otherwise produce false matches on Stel/Lun/Ter/Zil.
//
// Output flatten — KEYPAD.md §"o_key encoding":
//
//   0 Stelor  1 Stela   2 Stel    3 Multiply
//   4 Lunor   5 Luna    6 Lun     7 Add
//   8 Teror   9 Tera   10 Ter    (11 unused — Add visual continuation)
//  12 Zilor  13 Zila   14 Zil    15 Enter
//  16 Divide 17 Decimal 18 Negate
//  31 = no key pressed
//
// =============================================================================

`timescale 1ns / 1ps

module keypad (
    input  wire clk,
    input  wire reset_n,

    // Physical pins — all bidirectional, all PULLMODE=UP in the LPF.
    inout  wire p27_row0,
    inout  wire p28_row1,
    inout  wire p44_row2,
    inout  wire p51_row3,
    inout  wire p49_col0,
    inout  wire p63_col1,
    inout  wire p62_col2,
    inout  wire p56_col3,
    inout  wire p50_negate,
    inout  wire p57_decimal,
    inout  wire p58_divide,

    // Outputs
    output reg  [4:0] o_key,         // current pressed key, 5'd31 = none
    output reg        o_key_valid,   // o_key != 31
    output reg        press_pulse,   // 1-cycle pulse on a new press
    output reg        multiply_held, // chord-detect: high while Multiply held
    output reg        shift_held     // chord-detect: high while Decimal (key 17) held
);

    // -------------------------------------------------------------------------
    // Bidirectional buffers — explicit BB primitives. T=1 → input mode (pin
    // floats, pull-up keeps it HIGH unless externally shorted); T=0 → drive
    // I (always 0 here, active-low scan).
    // -------------------------------------------------------------------------
    reg drive_p27, drive_p28, drive_p44, drive_p51;
    reg drive_p50, drive_p57, drive_p58;

    wire in_p27, in_p28, in_p44, in_p51;
    wire in_p49, in_p63, in_p62, in_p56;
    wire in_p50, in_p57, in_p58;

    BB bb_p27 (.I(1'b0), .T(~drive_p27), .O(in_p27), .B(p27_row0));
    BB bb_p28 (.I(1'b0), .T(~drive_p28), .O(in_p28), .B(p28_row1));
    BB bb_p44 (.I(1'b0), .T(~drive_p44), .O(in_p44), .B(p44_row2));
    BB bb_p51 (.I(1'b0), .T(~drive_p51), .O(in_p51), .B(p51_row3));
    BB bb_p50 (.I(1'b0), .T(~drive_p50), .O(in_p50), .B(p50_negate));
    BB bb_p57 (.I(1'b0), .T(~drive_p57), .O(in_p57), .B(p57_decimal));
    BB bb_p58 (.I(1'b0), .T(~drive_p58), .O(in_p58), .B(p58_divide));
    BB bb_p49 (.I(1'b0), .T(1'b1),       .O(in_p49), .B(p49_col0));
    BB bb_p63 (.I(1'b0), .T(1'b1),       .O(in_p63), .B(p63_col1));
    BB bb_p62 (.I(1'b0), .T(1'b1),       .O(in_p62), .B(p62_col2));
    BB bb_p56 (.I(1'b0), .T(1'b1),       .O(in_p56), .B(p56_col3));

    // -------------------------------------------------------------------------
    // Phase counter + settle counter
    // -------------------------------------------------------------------------
    reg [2:0]  phase;
    reg [9:0]  settle_cnt;
    wire       settle_done = &settle_cnt;

    // -------------------------------------------------------------------------
    // Combinational drive selection per phase
    // -------------------------------------------------------------------------
    always @* begin
        drive_p27 = 1'b0;
        drive_p28 = 1'b0;
        drive_p44 = 1'b0;
        drive_p51 = 1'b0;
        drive_p50 = 1'b0;
        drive_p57 = 1'b0;
        drive_p58 = 1'b0;
        case (phase)
            3'd1: drive_p27 = 1'b1;  // row 0
            3'd2: drive_p28 = 1'b1;  // row 1
            3'd3: drive_p44 = 1'b1;  // row 2
            3'd4: drive_p51 = 1'b1;  // row 3
            3'd5: drive_p58 = 1'b1;  // Divide
            3'd6: drive_p57 = 1'b1;  // Decimal
            3'd7: drive_p50 = 1'b1;  // Negate
            default: ;                // phase 0 — all tristate
        endcase
    end

    // -------------------------------------------------------------------------
    // 2-FF synchronizers for all read signals. Pins are asynchronous to clk.
    // -------------------------------------------------------------------------
    reg [10:0] sync1, sync2;
    always @(posedge clk) begin
        sync1 <= {in_p49, in_p63, in_p62, in_p56,    // [10:7] cols
                  in_p27, in_p28, in_p44, in_p51,    // [6:3]  rows
                  in_p50, in_p57, in_p58};            // [2:0]  ad-hoc
        sync2 <= sync1;
    end

    wire s_p49 = sync2[10];
    wire s_p63 = sync2[9];
    wire s_p62 = sync2[8];
    wire s_p56 = sync2[7];
    wire s_p44 = sync2[4];   // [4] not [3] — see concat above

    // -------------------------------------------------------------------------
    // Per-phase captures (latched at settle_done)
    // -------------------------------------------------------------------------
    reg        cap_multiply;        // phase 0: ~p62
    reg [3:0]  cap_row [0:3];       // phases 1-4: {~p56, ~p62, ~p63, ~p49}
    reg        cap_divide;          // phase 5: ~p63
    reg        cap_decimal;         // phase 6: ~p44
    reg        cap_negate;          // phase 7: ~p62

    // -------------------------------------------------------------------------
    // Main FSM: advance phase on settle_done, capture phase's readings.
    // After phase 7 completes, decode + emit press_pulse.
    // -------------------------------------------------------------------------
    reg [4:0] o_key_prev;
    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            phase         <= 3'b0;
            settle_cnt    <= 10'b0;
            cap_multiply  <= 1'b0;
            cap_divide    <= 1'b0;
            cap_decimal   <= 1'b0;
            cap_negate    <= 1'b0;
            for (i = 0; i < 4; i = i + 1) cap_row[i] <= 4'b0;
            o_key         <= 5'd31;
            o_key_valid   <= 1'b0;
            press_pulse   <= 1'b0;
            multiply_held <= 1'b0;
            shift_held    <= 1'b0;
            o_key_prev    <= 5'd31;
        end else begin
            press_pulse <= 1'b0;
            settle_cnt  <= settle_cnt + 10'd1;

            if (settle_done) begin
                case (phase)
                    3'd0: cap_multiply <= ~s_p62;
                    3'd1: cap_row[0]   <= ~{s_p56, s_p62, s_p63, s_p49};
                    3'd2: cap_row[1]   <= ~{s_p56, s_p62, s_p63, s_p49};
                    3'd3: cap_row[2]   <= ~{s_p56, s_p62, s_p63, s_p49};
                    3'd4: cap_row[3]   <= ~{s_p56, s_p62, s_p63, s_p49};
                    3'd5: cap_divide   <= ~s_p63;
                    3'd6: cap_decimal  <= ~s_p44;
                    3'd7: cap_negate   <= ~s_p62;
                endcase

                if (phase == 3'd7) begin
                    if (cap_multiply)                        o_key <= 5'd3;
                    else if (cap_row[0][0])                  o_key <= 5'd0;
                    else if (cap_row[0][1])                  o_key <= 5'd1;
                    else if (cap_row[0][2] && !cap_multiply) o_key <= 5'd2;
                    else if (cap_row[1][0])                  o_key <= 5'd4;
                    else if (cap_row[1][1])                  o_key <= 5'd5;
                    else if (cap_row[1][2] && !cap_multiply) o_key <= 5'd6;
                    else if (cap_row[1][3])                  o_key <= 5'd7;   // Add
                    else if (cap_row[2][0])                  o_key <= 5'd8;
                    else if (cap_row[2][1])                  o_key <= 5'd9;
                    else if (cap_row[2][2] && !cap_multiply) o_key <= 5'd10;
                    else if (cap_row[3][0])                  o_key <= 5'd12;
                    else if (cap_row[3][1])                  o_key <= 5'd13;
                    else if (cap_row[3][2] && !cap_multiply) o_key <= 5'd14;
                    else if (cap_row[3][3])                  o_key <= 5'd15;  // Enter
                    else if (cap_divide)                     o_key <= 5'd16;
                    else if (cap_decimal)                    o_key <= 5'd17;
                    else if (cap_negate)                     o_key <= 5'd18;
                    else                                     o_key <= 5'd31;

                    multiply_held <= cap_multiply;
                    shift_held    <= cap_decimal;

                    phase <= 3'd0;
                end else begin
                    phase <= phase + 3'd1;
                end

                settle_cnt <= 10'b0;
            end

            o_key_prev  <= o_key;
            o_key_valid <= (o_key != 5'd31);
            if (o_key != o_key_prev && o_key != 5'd31)
                press_pulse <= 1'b1;
        end
    end

endmodule
