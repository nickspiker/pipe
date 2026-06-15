// =============================================================================
// bin_to_bcd.v — binary to packed BCD via shift-and-add-3 (Double Dabble)
// =============================================================================
//
// Pulse `start` with `bin` valid. After BIN_W clock cycles, `done` pulses for one cycle and `bcd` holds the result — `BCD_DIGITS` nibbles, MSD in the top nibble. Subsequent starts overwrite. Asynchronous reset clears.
//
// At default BIN_W=24 / BCD_DIGITS=8: supports binary inputs up to 16,777,215 → 8-digit decimal output. For our freq counter (max ~10 MHz × 0.2 s = 2 M edges, × MAGIC=5 = 10 MHz Hz value) this is plenty.
// =============================================================================

`timescale 1ns / 1ps

module bin_to_bcd #(
    parameter integer BIN_W      = 24,
    parameter integer BCD_DIGITS = 8
)(
    input  wire                       clk,
    input  wire                       reset_n,
    input  wire                       start,
    input  wire [BIN_W-1:0]           bin,
    output reg  [BCD_DIGITS*4-1:0]    bcd,
    output reg                        done
);

    localparam integer BCD_W = BCD_DIGITS * 4;

    reg [BIN_W-1:0] shifter;
    reg [BCD_W-1:0] bcd_accum;
    reg [$clog2(BIN_W+1)-1:0] step;
    reg busy;

    // Combinational +3 adjust on each BCD digit.
    reg [BCD_W-1:0] bcd_adjusted;
    integer i;
    always @* begin
        bcd_adjusted = bcd_accum;
        for (i = 0; i < BCD_DIGITS; i = i + 1) begin
            if (bcd_adjusted[i*4 +: 4] >= 4'd5)
                bcd_adjusted[i*4 +: 4] = bcd_adjusted[i*4 +: 4] + 4'd3;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            shifter   <= 0;
            bcd_accum <= 0;
            step      <= 0;
            busy      <= 1'b0;
            done      <= 1'b0;
            bcd       <= 0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                shifter   <= bin;
                bcd_accum <= 0;
                step      <= 0;
                busy      <= 1'b1;
            end else if (busy) begin
                if (step == BIN_W) begin
                    bcd  <= bcd_accum;
                    done <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    // Shift left thru {bcd_adjusted, shifter}.
                    {bcd_accum, shifter} <= {bcd_adjusted, shifter} << 1;
                    step <= step + 1;
                end
            end
        end
    end

endmodule
