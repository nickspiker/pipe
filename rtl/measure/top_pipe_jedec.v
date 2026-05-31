// =============================================================================
// top_pipe_jedec.v — SPI flash JEDEC ID readout diagnostic
// =============================================================================
//
// Drives spi_master.v with the JEDEC_ID command (0x9F), captures the 3 returned
// bytes (manufacturer, memory type, capacity), and displays them on the OLED.
// Tells us definitively whether the SPI master can communicate with the GD25Q32
// flash chip post-configuration.
//
// Expected result: C8 40 16 (GigaDevice GD25Q32 = 4 MB SPI flash).
//
// If we get FF FF FF: MISO is reading the wrong pin or USRMCLK isn't clocking.
// If we get 00 00 00: MISO is pulled low / flash not responding to CS.
// If we get C8 40 16: SPI master works, problem is elsewhere in otp_persistent.
//
// OLED layout (mode 0, only mode supported):
//   Line 0:  "FLASH JEDEC ID"
//   Line 1:  "READ:    XX XX XX"
//   Line 2:  "EXPECT:  C8 40 16"
//   Line 3:  "MATCH: YES"  or  "MATCH: NO"
//
// Auto-runs JEDEC read every ~1 second (LED toggles on each read for liveness).
// Re-uses the same module port signature as top_pipe_meal_diag so the existing
// pipe_meal.lpf constraints file fits.
// =============================================================================

`timescale 1ns / 1ps

module top_pipe_jedec (
    input  wire clk,

    // Keypad (unused but pin-constrained)
    inout  wire kp_p27, inout wire kp_p28, inout wire kp_p44, inout wire kp_p51,
    inout  wire kp_p49, inout wire kp_p63, inout wire kp_p62, inout wire kp_p56,
    inout  wire kp_p50, inout wire kp_p57, inout wire kp_p58,

    output wire oled_scl,
    output wire oled_sda,
    output reg  led,
    output reg  ext_led,

    output wire flash_cs_n,
    output wire flash_mosi,
    input  wire flash_miso,

    inout  wire pipe_pad
);

    // Tristate everything we don't need
    assign kp_p27 = 1'bz; assign kp_p28 = 1'bz; assign kp_p44 = 1'bz;
    assign kp_p51 = 1'bz; assign kp_p49 = 1'bz; assign kp_p63 = 1'bz;
    assign kp_p62 = 1'bz; assign kp_p56 = 1'bz; assign kp_p50 = 1'bz;
    assign kp_p57 = 1'bz; assign kp_p58 = 1'bz;

    // Tristate pipe_pad via BB primitive
    BB pipe_pad_bb (
        .I(1'b0),
        .T(1'b1),
        .O(),
        .B(pipe_pad)
    );

    // =========================================================================
    // POR reset synchroniser
    // =========================================================================
    reg [15:0] por_cnt = 16'b0;
    reg        reset_n = 1'b0;
    always @(posedge clk) begin
        if (!&por_cnt) por_cnt <= por_cnt + 16'd1;
        reset_n <= &por_cnt;
    end

    // =========================================================================
    // SPI master + JEDEC ID FSM
    // =========================================================================
    reg          spi_cmd_start;
    reg  [2:0]   spi_cmd_op;
    reg  [23:0]  spi_cmd_addr;
    reg  [8:0]   spi_cmd_byte_count;
    reg  [7:0]   spi_cmd_wdata;
    wire         spi_cmd_busy;
    wire         spi_cmd_done;
    wire [7:0]   spi_rdata;
    wire         spi_rdata_valid;
    wire         spi_flash_sck;

    spi_master u_spi (
        .clk             (clk),
        .reset_n         (reset_n),
        .cmd_start       (spi_cmd_start),
        .cmd_op          (spi_cmd_op),
        .cmd_addr        (spi_cmd_addr),
        .cmd_byte_count  (spi_cmd_byte_count),
        .wdata           (spi_cmd_wdata),
        .cmd_busy        (spi_cmd_busy),
        .cmd_done        (spi_cmd_done),
        .rdata           (spi_rdata),
        .rdata_valid     (spi_rdata_valid),
        .flash_cs_n      (flash_cs_n),
        .flash_sck       (spi_flash_sck),
        .flash_mosi      (flash_mosi),
        .flash_miso      (flash_miso)
    );

    // JEDEC capture: collect 3 bytes from rdata_valid pulses.
    reg [7:0] jedec_b0, jedec_b1, jedec_b2;
    reg [1:0] jedec_idx;
    reg       jedec_ready;
    reg       cycle_active;
    reg [24:0] retry_cnt;          // ~25 MHz / 2^25 ≈ 0.75 s rerun

    localparam [2:0] CMD_JEDEC = 3'd5;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            spi_cmd_start      <= 1'b0;
            spi_cmd_op         <= 3'd0;
            spi_cmd_addr       <= 24'b0;
            spi_cmd_byte_count <= 9'd0;
            spi_cmd_wdata      <= 8'b0;
            jedec_b0           <= 8'h00;
            jedec_b1           <= 8'h00;
            jedec_b2           <= 8'h00;
            jedec_idx          <= 2'd0;
            jedec_ready        <= 1'b0;
            cycle_active       <= 1'b0;
            retry_cnt          <= 25'b0;
        end else begin
            spi_cmd_start <= 1'b0;

            if (!cycle_active && !spi_cmd_busy) begin
                // launch JEDEC ID, 3-byte read
                spi_cmd_op         <= CMD_JEDEC;
                spi_cmd_byte_count <= 9'd3;
                spi_cmd_start      <= 1'b1;
                jedec_idx          <= 2'd0;
                cycle_active       <= 1'b1;
            end

            // Latch incoming bytes
            if (cycle_active && spi_rdata_valid) begin
                case (jedec_idx)
                    2'd0: jedec_b0 <= spi_rdata;
                    2'd1: jedec_b1 <= spi_rdata;
                    2'd2: jedec_b2 <= spi_rdata;
                    default: ;
                endcase
                if (jedec_idx != 2'd3) jedec_idx <= jedec_idx + 2'd1;
            end

            if (cycle_active && spi_cmd_done) begin
                jedec_ready  <= 1'b1;
                cycle_active <= 1'b0;
                retry_cnt    <= 25'b0;
            end

            // Wait ~0.75 s then re-issue (so a missed read self-corrects)
            if (!cycle_active && jedec_ready) begin
                retry_cnt <= retry_cnt + 25'd1;
                if (&retry_cnt) begin
                    jedec_ready <= 1'b0;
                end
            end
        end
    end

    wire jedec_match = (jedec_b0 == 8'hC8)
                    && (jedec_b1 == 8'h40)
                    && (jedec_b2 == 8'h16);

    // =========================================================================
    // OLED text composition
    // =========================================================================
    localparam integer N_LINES            = 4;
    localparam integer MAX_CHARS_PER_LINE = 24;
    localparam integer STR_LEN            = N_LINES * MAX_CHARS_PER_LINE;
    localparam integer FB_W               = 128;
    localparam integer FB_H               = 64;

    function [7:0] nib2asc(input [3:0] n);
        nib2asc = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h41 + {4'b0, n} - 8'd10);
    endfunction

    reg [STR_LEN*8-1:0] strings_flat;
    integer si;
    always @* begin
        // Fill with SPACE (0x20), NOT NUL. The renderer treats NUL as end-of-line
        // and jumps to the next line, which would silently truncate lines that
        // have gaps mid-content (like "READ:  XX XX XX").
        for (si = 0; si < STR_LEN; si = si + 1) strings_flat[si*8 +: 8] = 8'h20;

        // Line 0: "FLASH JEDEC ID"
        strings_flat[ 0*8 +: 8] = "F"; strings_flat[ 1*8 +: 8] = "L";
        strings_flat[ 2*8 +: 8] = "A"; strings_flat[ 3*8 +: 8] = "S";
        strings_flat[ 4*8 +: 8] = "H"; strings_flat[ 5*8 +: 8] = " ";
        strings_flat[ 6*8 +: 8] = "J"; strings_flat[ 7*8 +: 8] = "E";
        strings_flat[ 8*8 +: 8] = "D"; strings_flat[ 9*8 +: 8] = "E";
        strings_flat[10*8 +: 8] = "C"; strings_flat[11*8 +: 8] = " ";
        strings_flat[12*8 +: 8] = "I"; strings_flat[13*8 +: 8] = "D";

        // Line 1: "READ:    XX XX XX"
        strings_flat[(24+0)*8 +: 8] = "R"; strings_flat[(24+1)*8 +: 8] = "E";
        strings_flat[(24+2)*8 +: 8] = "A"; strings_flat[(24+3)*8 +: 8] = "D";
        strings_flat[(24+4)*8 +: 8] = ":";
        strings_flat[(24+9)*8 +: 8]  = nib2asc(jedec_b0[7:4]);
        strings_flat[(24+10)*8 +: 8] = nib2asc(jedec_b0[3:0]);
        strings_flat[(24+11)*8 +: 8] = " ";
        strings_flat[(24+12)*8 +: 8] = nib2asc(jedec_b1[7:4]);
        strings_flat[(24+13)*8 +: 8] = nib2asc(jedec_b1[3:0]);
        strings_flat[(24+14)*8 +: 8] = " ";
        strings_flat[(24+15)*8 +: 8] = nib2asc(jedec_b2[7:4]);
        strings_flat[(24+16)*8 +: 8] = nib2asc(jedec_b2[3:0]);

        // Line 2: "EXPECT:  C8 40 16"
        strings_flat[(48+0)*8 +: 8] = "E"; strings_flat[(48+1)*8 +: 8] = "X";
        strings_flat[(48+2)*8 +: 8] = "P"; strings_flat[(48+3)*8 +: 8] = "E";
        strings_flat[(48+4)*8 +: 8] = "C"; strings_flat[(48+5)*8 +: 8] = "T";
        strings_flat[(48+6)*8 +: 8] = ":";
        strings_flat[(48+9)*8 +: 8]  = "C"; strings_flat[(48+10)*8 +: 8] = "8";
        strings_flat[(48+11)*8 +: 8] = " ";
        strings_flat[(48+12)*8 +: 8] = "4"; strings_flat[(48+13)*8 +: 8] = "0";
        strings_flat[(48+14)*8 +: 8] = " ";
        strings_flat[(48+15)*8 +: 8] = "1"; strings_flat[(48+16)*8 +: 8] = "6";

        // Line 3: MATCH: YES/NO
        strings_flat[(72+0)*8 +: 8] = "M"; strings_flat[(72+1)*8 +: 8] = "A";
        strings_flat[(72+2)*8 +: 8] = "T"; strings_flat[(72+3)*8 +: 8] = "C";
        strings_flat[(72+4)*8 +: 8] = "H"; strings_flat[(72+5)*8 +: 8] = ":";
        strings_flat[(72+6)*8 +: 8] = " ";
        if (jedec_match) begin
            strings_flat[(72+7)*8 +: 8] = "Y";
            strings_flat[(72+8)*8 +: 8] = "E";
            strings_flat[(72+9)*8 +: 8] = "S";
        end else begin
            strings_flat[(72+7)*8 +: 8] = "N";
            strings_flat[(72+8)*8 +: 8] = "O";
        end
    end

    // =========================================================================
    // OLED renderer + driver + framebuffer
    // =========================================================================
    reg [7:0] fb [0:FB_W*FB_H-1];
    initial begin : fb_init
        integer fbi;
        for (fbi = 0; fbi < FB_W*FB_H; fbi = fbi + 1) fb[fbi] = 8'h00;
    end

    wire        rend_we;
    wire [12:0] rend_waddr;
    wire  [7:0] rend_wdata;
    wire [12:0] oled_raddr;
    reg   [7:0] oled_rdata;

    localparam integer OLED_CLK_DIV = 7;
    reg [2:0] ce_cnt = 3'b0;
    wire ce_at_top = (ce_cnt == OLED_CLK_DIV - 1);
    always @(posedge clk) ce_cnt <= ce_at_top ? 3'b0 : ce_cnt + 3'd1;
    reg ce_pulse = 1'b0;
    always @(posedge clk) ce_pulse <= ce_at_top;

    always @(posedge clk) begin
        if (rend_we) fb[rend_waddr] <= rend_wdata;
    end
    always @(posedge clk) begin
        if (ce_pulse) oled_rdata <= fb[oled_raddr];
    end

    // Re-render trigger: every new JEDEC capture
    reg last_jedec_ready;
    reg re_render_req;
    reg [3:0] re_render_init_cnt;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            re_render_req      <= 1'b0;
            last_jedec_ready   <= 1'b0;
            re_render_init_cnt <= 4'd0;
        end else begin
            re_render_req <= 1'b0;
            if (re_render_init_cnt != 4'd15) begin
                re_render_init_cnt <= re_render_init_cnt + 4'd1;
                if (re_render_init_cnt == 4'd14) re_render_req <= 1'b1;
            end
            if (jedec_ready && !last_jedec_ready) re_render_req <= 1'b1;
            last_jedec_ready <= jedec_ready;
        end
    end

    oled_text_renderer #(
        .FB_W              (FB_W),
        .FB_H              (FB_H),
        .N_LINES           (N_LINES),
        .MAX_CHARS_PER_LINE(MAX_CHARS_PER_LINE)
    ) u_renderer (
        .clk          (clk),
        .reset_n      (reset_n),
        .re_render_req(re_render_req),
        .strings_flat (strings_flat),
        .render_done  (),
        .fb_we        (rend_we),
        .fb_waddr     (rend_waddr),
        .fb_wdata     (rend_wdata)
    );

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

    // =========================================================================
    // LED: blink fast if JEDEC matches, slow if not
    // =========================================================================
    reg [23:0] blink_div = 24'b0;
    always @(posedge clk) blink_div <= blink_div + 24'd1;
    wire blink_fast = blink_div[20];
    wire blink_slow = blink_div[23];

    always @(posedge clk) begin
        if (jedec_match) begin
            led     <= ~blink_fast;
            ext_led <=  blink_fast;
        end else begin
            led     <= ~blink_slow;
            ext_led <=  blink_slow;
        end
    end

endmodule
