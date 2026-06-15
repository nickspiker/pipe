// =============================================================================
// oled_text_renderer.v — anti-aliased Merriweather text → 8-bit greyscale fb
// =============================================================================
//
// Reusable text renderer extracted from top_pipe_oled.v. Walks N_LINES ×
// MAX_CHARS_PER_LINE bytes of ASCII string input, looks up each character
// in the glyph atlas (anti-aliased Merriweather raster at build time via
// tools/oled-bake-atlas), and blits the alpha pixels into a 128×64 byte-
// greyscale framebuffer with max-blend.
//
// Inputs (build-time, via $readmemh):
//   glyph_dims.vh    — `define CELL_W, CELL_H, PAD_LEFT, MAX_ASCENT, NUM_CHARS, FIRST_CHAR
//   glyph_atlas.mem  — NUM_CHARS × CELL_W × CELL_H bytes, row-major within each cell
//   glyph_advance.mem — NUM_CHARS bytes of advance widths
//
// Caller drives:
//   strings_flat[N_LINES*MAX_CHARS_PER_LINE*8-1:0] — the text to render
//                                                    (8'h00 in a slot = end-of-line)
//   re_render_req — pulse to start a fresh full repaint
//
// Outputs:
//   render_done — high when the renderer is idle (last render complete)
//   fb_we / fb_waddr / fb_wdata — framebuffer write port (8-bit greyscale)
//
// Caller arbitrates the framebuffer: while render_done is low, this module
// owns the write port and the OLED pump should read only after render_done
// asserts (or accept that some pixels will be in-flight during repaint).
//
// =============================================================================

`timescale 1ns / 1ps

`include "glyph_dims.vh"

module oled_text_renderer #(
    parameter integer FB_W               = 128,
    parameter integer FB_H               = 64,
    parameter integer N_LINES            = 4,
    parameter integer MAX_CHARS_PER_LINE = 24
) (
    input  wire                                       clk,
    input  wire                                       reset_n,
    input  wire                                       re_render_req,
    input  wire [N_LINES*MAX_CHARS_PER_LINE*8-1:0]    strings_flat,

    output wire                                       render_done,
    output reg                                        fb_we,
    output reg  [12:0]                                fb_waddr,
    output reg   [7:0]                                fb_wdata
);

    // -------------------------------------------------------------------------
    // Atlas constants from glyph_dims.vh
    // -------------------------------------------------------------------------
    localparam integer CELL_W      = `GLYPH_CELL_W;
    localparam integer CELL_H      = `GLYPH_CELL_H;
    localparam integer PAD_LEFT    = `GLYPH_PAD_LEFT;
    localparam integer MAX_ASCENT  = `GLYPH_MAX_ASCENT;
    localparam integer NUM_CHARS   = `GLYPH_NUM_CHARS;
    localparam [7:0]   FIRST_CHAR  = `GLYPH_FIRST_CHAR;

    localparam integer CELL_SIZE   = CELL_W * CELL_H;
    localparam integer ATLAS_SIZE  = NUM_CHARS * CELL_SIZE;
    localparam integer STR_LEN     = N_LINES * MAX_CHARS_PER_LINE;

    // -------------------------------------------------------------------------
    // Glyph atlas + per-glyph advance ROMs (loaded from .mem files at synth time)
    // -------------------------------------------------------------------------
    reg [7:0] atlas [0:ATLAS_SIZE - 1];
    initial $readmemh("glyph_atlas.mem", atlas);

    reg [7:0] advance_w [0:NUM_CHARS - 1];
    initial $readmemh("glyph_advance.mem", advance_w);

    // -------------------------------------------------------------------------
    // Unpack strings_flat into a byte-addressable array view.
    // -------------------------------------------------------------------------
    wire [7:0] strings [0:STR_LEN - 1];
    genvar gs;
    generate
        for (gs = 0; gs < STR_LEN; gs = gs + 1) begin : unpack_strings
            assign strings[gs] = strings_flat[gs*8 +: 8];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Per-line baselines (in framebuffer rows). 4-line layout on 64-row OLED:
    // ascent ~11 above baseline, descent ~4 below → 16px per line.
    // -------------------------------------------------------------------------
    function [6:0] line_baseline(input [1:0] ln);
        case (ln)
            2'd0: line_baseline = 7'd11;
            2'd1: line_baseline = 7'd27;
            2'd2: line_baseline = 7'd43;
            2'd3: line_baseline = 7'd59;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Renderer FSM.
    //   R_BOOT     — wait a few cycles for $readmemh to settle
    //   R_CLEAR    — walk framebuffer writing 0 to every cell
    //   R_LOAD     — fetch next char from strings[]
    //   R_LATCH    — wait one cycle for atlas/advance reads to settle
    //   R_PX_READ  — read one atlas pixel
    //   R_PX_WRITE — write framebuffer with max-blend (we just overwrite for now)
    //   R_ADV      — advance px_i / px_j / char cursor
    //   R_NEXT_LN  — finished current line, advance to next or done
    //   R_DONE     — idle until re_render_req fires
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

    reg  [3:0]  rstate;
    reg  [4:0]  boot_cnt;
    reg  [12:0] clear_addr;
    localparam [12:0] CLEAR_END = FB_W * FB_H - 1;

    reg  [1:0]  line_idx;
    reg  [4:0]  char_in_line;
    reg  [6:0]  cursor_x;
    reg  [7:0]  char_ascii;
    reg  [6:0]  glyph_idx;
    reg  [3:0]  px_i;            // 0..CELL_W-1
    reg  [3:0]  px_j;            // 0..CELL_H-1

    wire signed [8:0] dst_x = $signed({2'b00, cursor_x}) - $signed({2'b00, PAD_LEFT[6:0]}) + $signed({5'b0, px_i});
    wire signed [8:0] dst_y = $signed({2'b00, line_baseline(line_idx)}) - $signed({2'b00, MAX_ASCENT[6:0]}) + $signed({5'b0, px_j});

    wire dst_in_range = (dst_x >= 0) && (dst_x < FB_W) && (dst_y >= 0) && (dst_y < FB_H);

    wire [14:0] atlas_addr = {glyph_idx, px_j[3:0], px_i[3:0]};
    reg  [7:0]  atlas_pix;
    always @(posedge clk) atlas_pix <= atlas[atlas_addr];

    assign render_done = (rstate == R_DONE);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rstate       <= R_BOOT;
            boot_cnt     <= 5'b0;
            clear_addr   <= 13'b0;
            line_idx     <= 2'b0;
            char_in_line <= 5'b0;
            cursor_x     <= 7'b0;
            char_ascii   <= 8'b0;
            glyph_idx    <= 7'b0;
            px_i         <= 4'b0;
            px_j         <= 4'b0;
            fb_we        <= 1'b0;
            fb_waddr     <= 13'b0;
            fb_wdata     <= 8'b0;
        end else begin
            fb_we <= 1'b0;

            case (rstate)
                R_BOOT: begin
                    boot_cnt <= boot_cnt + 5'd1;
                    if (&boot_cnt) begin
                        clear_addr <= 13'd0;
                        rstate     <= R_CLEAR;
                    end
                end

                R_CLEAR: begin
                    fb_we    <= 1'b1;
                    fb_waddr <= clear_addr;
                    fb_wdata <= 8'h00;
                    if (clear_addr == CLEAR_END) begin
                        line_idx     <= 2'd0;
                        char_in_line <= 5'b0;
                        cursor_x     <= 7'b0;
                        rstate       <= R_LOAD;
                    end else begin
                        clear_addr <= clear_addr + 13'd1;
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
                        px_i      <= 4'b0;
                        px_j      <= 4'b0;
                        rstate    <= R_PX_READ;
                    end
                end

                R_PX_READ: begin
                    // atlas_pix updates one cycle after atlas_addr is set —
                    // we wait thru this state once per pixel for the read
                    // to settle.
                    rstate <= R_PX_WRITE;
                end

                R_PX_WRITE: begin
                    if (atlas_pix != 8'h00 && dst_in_range) begin
                        fb_waddr <= dst_y[6:0] * FB_W + dst_x[7:0];
                        fb_wdata <= atlas_pix;
                        fb_we    <= 1'b1;
                    end
                    rstate <= R_ADV;
                end

                R_ADV: begin
                    if (px_i == CELL_W - 1) begin
                        px_i <= 4'b0;
                        if (px_j == CELL_H - 1) begin
                            // Finished this glyph — advance cursor + next char.
                            cursor_x     <= cursor_x + advance_w[glyph_idx];
                            char_in_line <= char_in_line + 5'd1;
                            if (char_in_line == MAX_CHARS_PER_LINE - 1) begin
                                rstate <= R_NEXT_LN;
                            end else begin
                                rstate <= R_LOAD;
                            end
                            px_j <= 4'b0;
                        end else begin
                            px_j   <= px_j + 4'd1;
                            rstate <= R_PX_READ;
                        end
                    end else begin
                        px_i   <= px_i + 4'd1;
                        rstate <= R_PX_READ;
                    end
                end

                R_NEXT_LN: begin
                    if (line_idx == N_LINES - 1) begin
                        rstate <= R_DONE;
                    end else begin
                        line_idx     <= line_idx + 2'd1;
                        char_in_line <= 5'b0;
                        cursor_x     <= 7'b0;
                        rstate       <= R_LOAD;
                    end
                end

                R_DONE: begin
                    if (re_render_req) begin
                        clear_addr <= 13'd0;
                        rstate     <= R_CLEAR;
                    end
                end

                default: rstate <= R_DONE;
            endcase
        end
    end

endmodule
