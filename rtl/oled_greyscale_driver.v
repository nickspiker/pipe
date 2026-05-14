// =============================================================================
// oled_greyscale_driver.v — reusable 128×64 8bpp framebuffer → SSD1306 OLED
// =============================================================================
//
// Drives a 128×64 SSD1306 I²C OLED from a caller-supplied 1024-byte framebuffer
// (8 pages × 128 columns, one byte per pixel-column-of-a-page-row).
//
// Each byte in the framebuffer is interpreted as an 8-bit greyscale value
// (0 = black, 255 = full intensity). The driver renders by reading the byte
// 8 times per OLED page-column-write and comparing against an LFSR-driven
// dither each time, producing 8 dithered bits stacked into the page byte.
// All 8 vertical pixels in a page share the same source byte but are dithered
// independently, so a uniform-grey input produces a uniform-greyish band.
//
// Caller's framebuffer indexing convention:
//   addr [9:7] = page index (0..7, top to bottom on OLED)
//   addr [6:0] = column     (0..127, left to right)
//
// OLED FSM modeled on the proven pattern in top_pipe_oled.v (Phase 2A bringup).
// =============================================================================

`timescale 1ns / 1ps

module oled_greyscale_driver #(
    parameter integer CLK_DIV     = 7,    // 25 MHz / 7 → ~3.5 MHz CE → ~28 kHz SCL
    parameter integer BUSFREE_LEN = 10    // bits in busfree counter (2^10 cycles between transactions)
)(
    input  wire        clk,
    output wire        oled_scl,
    output wire        oled_sda,
    output reg         frame_pulse,       // 1-cycle pulse once per full screen refresh (page 7 → 0 wrap)

    // Framebuffer read interface — 8192-byte 8bpp greyscale fb.
    // Each byte = one pixel's 0..255 greyscale value, dithered to 1-bit OLED.
    // NOTE: fb_raddr is COMBINATIONAL (continuous assign), not a registered
    // output, because yosys was optimizing away the gather_cnt connection
    // when it was registered. Combinational forces yosys to keep all bits.
    output wire [12:0] fb_raddr,          // {page[2:0], gather_cnt[2:0], col[6:0]}
    input  wire [7:0]  fb_rdata           // greyscale value at addr
);

    // -------------------------------------------------------------------------
    // CE divider — produces a 1-cycle pulse every CLK_DIV cycles
    // -------------------------------------------------------------------------
    reg [$clog2(CLK_DIV)-1:0] ce_cnt = 0;
    wire at_top = (ce_cnt == CLK_DIV - 1);
    always @(posedge clk) ce_cnt <= at_top ? 0 : ce_cnt + 1;
    reg ce = 0;
    always @(posedge clk) ce <= at_top;

    // -------------------------------------------------------------------------
    // I²C bus driver
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // SSD1306 init sequence (proven from top_pipe_oled.v)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // LFSR dither — 32-bit Galois, period 2^32-1
    // -------------------------------------------------------------------------
    reg [31:0] lfsr = 32'hCAFE_BABE;
    always @(posedge clk)
        lfsr <= {lfsr[0], lfsr[31:1]} ^ ({32{lfsr[0]}} & 32'h80200003);
    wire [7:0] dither = lfsr[7:0];

    // -------------------------------------------------------------------------
    // OLED pump FSM — replicates top_pipe_oled.v pattern
    // -------------------------------------------------------------------------
    localparam [2:0]
        ST_RESET    = 3'd0, ST_SEND   = 3'd1, ST_WAIT  = 3'd2,
        ST_NEXT     = 3'd3, ST_BUSFREE= 3'd4, ST_GATHER= 3'd5;

    localparam [1:0]
        PH_INIT     = 2'd0, PH_PAGE_CMD = 2'd1, PH_PAGE_DATA = 2'd2;

    reg [2:0]              state       = ST_RESET;
    reg [1:0]              phase       = PH_INIT;
    reg [19:0]             reset_cnt   = 0;
    reg [BUSFREE_LEN-1:0]  busfree_cnt = 0;
    reg [4:0]              cmd_idx     = 0;
    reg [2:0]              page        = 0;
    reg [6:0]              col         = 0;
    reg [7:0]              px_byte     = 0;
    reg [3:0]              gather_cnt  = 0;

    // Frame-boundary detector (page 7 → 0 wrap)
    reg page_was_zero = 1'b1;
    always @(posedge clk) begin
        frame_pulse <= 1'b0;
        if (ce) begin
            if ((page == 3'd0) && !page_was_zero) frame_pulse <= 1'b1;
            page_was_zero <= (page == 3'd0);
        end
    end

    // fb_raddr is COMBINATIONAL — drive directly from the current page/gather_cnt/col.
    // This avoids a yosys optimization bug where a registered fb_raddr had
    // gather_cnt[2:0] zeroed out, breaking the per-vertical-pixel addressing.
    assign fb_raddr = {page, gather_cnt[2:0], col};

    always @(posedge clk) if (ce) begin
        i2c_start <= 0;

        case (state)
            ST_RESET: begin
                reset_cnt <= reset_cnt + 1;
                if (&reset_cnt) begin
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
                // 8bpp greyscale with LFSR dither — reads 8 fb bytes
                // (one per vertical pixel in this OLED column-page) and
                // dithers each into one bit of px_byte.
                gather_cnt <= gather_cnt + 1;
                if (gather_cnt >= 4'd1) begin
                    px_byte <= {(fb_rdata > dither), px_byte[7:1]};
                end
                if (gather_cnt == 4'd8) begin
                    gather_cnt <= 0;
                    state      <= ST_SEND;
                end
            end
        endcase
    end

endmodule
