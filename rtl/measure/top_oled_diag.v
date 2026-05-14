// =============================================================================
// top_oled_diag.v — OLED diagnostic, no renderer, no ira logic
// =============================================================================
// Pre-loads the framebuffer with a known test pattern (vertical gradient:
// each row's brightness = y * 4) and pumps it to the SSD1306. If the gradient
// renders as smooth top-to-bottom (dark top, bright bottom, no banding), the
// renderer→fb→OLED wiring is sound. If horizontal banding appears in the
// gradient, the bug is in the OLED-side path (driver, BRAM inference, or
// fb addressing).
// =============================================================================

`timescale 1ns / 1ps

module top_oled_diag (
    input  wire clk,
    output wire oled_scl,
    output wire oled_sda,
    output reg  led
);

    localparam integer FB_W = 128;
    localparam integer FB_H = 64;

    reg [7:0] fb [0:FB_W*FB_H-1];

    integer fbi, ix, iy;
    initial begin
        for (fbi = 0; fbi < FB_W*FB_H; fbi = fbi + 1) begin
            iy = fbi / FB_W;
            ix = fbi % FB_W;
            // Within each 8-pixel-tall OLED page, each of the 8 rows gets a
            // DISTINCT brightness based on the row position within the page
            // (iy mod 8). All 8 pages display the same internal pattern.
            // Driver dither uses (fb_rdata > dither), so:
            //   row 0 (val 0)   → P=0/256       → pure black
            //   row 7 (val 224) → P=224/256     → very bright
            // To get "fully white" row 7, use 8'hFF (= P=255/256, "almost white").
            fb[fbi] = iy[2:0] == 3'd7 ? 8'hFF : {iy[2:0], 5'b00000};
        end
    end

    wire [12:0] oled_raddr;
    reg   [7:0] oled_rdata;

    // CE divider matching oled_greyscale_driver's CLK_DIV=7. The driver's
    // gather FSM advances per-CE (every 7 clk cycles), so fb_raddr only
    // changes per-CE. If the framebuffer read updates every clk, fb_rdata
    // races ahead and the driver captures the WRONG byte at each CE pulse
    // (off-by-one wrap of bytes 0..7 → 1..7,0 → bit positions mirror-
    // reflected around bit 4). Gating fb read with CE matches the driver's
    // timing expectation.
    localparam integer CLK_DIV = 7;
    reg [2:0] ce_cnt = 3'b0;
    wire ce_at_top = (ce_cnt == CLK_DIV - 1);
    always @(posedge clk) ce_cnt <= ce_at_top ? 3'b0 : ce_cnt + 3'd1;
    reg ce_pulse = 1'b0;
    always @(posedge clk) ce_pulse <= ce_at_top;

    always @(posedge clk) begin
        if (ce_pulse) oled_rdata <= fb[oled_raddr];
    end

    oled_greyscale_driver #(
        .CLK_DIV    (7),
        .BUSFREE_LEN(10)
    ) u_oled (
        .clk        (clk),
        .oled_scl   (oled_scl),
        .oled_sda   (oled_sda),
        .frame_pulse(),
        .fb_raddr   (oled_raddr),
        .fb_rdata   (oled_rdata)
    );

    // Heartbeat LED so we can confirm the bitstream loaded.
    reg [23:0] blink;
    always @(posedge clk) begin
        blink <= blink + 24'd1;
        led   <= blink[22];
    end

endmodule
