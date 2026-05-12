// =============================================================================
// top_pipe_oled.v — OLED bring-up for PIPE
// =============================================================================
// Phase 1: prove out the I2C + framebuffer + TRNG-dithered pump using a
// known-good test pattern. We display three horizontal grey bands (0x40,
// 0x80, 0xC0) on top half and a slow-counting checkerboard on the bottom
// half. Once verified, the framebuffer write logic gets swapped for real
// PIPE state (challenge / output / efuse status).
//
// Clock: external 25 MHz on P6 (same as the dev board's main oscillator).
// PIPE's ring-osc enclave_clk is irrelevant here — OLED + I2C run only on
// the fast clock. Future phases will cross PIPE signals into this domain
// through 2-FF synchronizers.
//
// Layout (128×64, 8bpp framebuffer dithered to 1bpp via TRNG):
//   Rows  0–20: dark grey band  (0x40 dithered)
//   Rows 21–41: mid  grey band  (0x80)
//   Rows 42–62: light grey band (0xC0)
//   Row     63: animated 1px scan line (pure white sweeping across)
// =============================================================================

`timescale 1ns / 1ps

module top_pipe_oled #(
    parameter integer CLK_DIV = 7   // 25 MHz / 7 = ~3.57 MHz CE → I2C SCL ≈ 28 kHz
)(
    input  wire clk,                // 25 MHz external crystal (P6)
    output wire oled_scl,
    output wire oled_sda,
    output reg  led                 // T6 — heartbeat
);

    // -------------------------------------------------------------------------
    // TRNG (29 ring oscillators + temporal XOR + rotation mix, same as pin_id)
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
    // Heartbeat LED — flickers at TRNG rate so we can see the FPGA is alive
    // before the OLED finishes initialising.
    // -------------------------------------------------------------------------
    reg [22:0] hb_cnt = 0;
    always @(posedge clk) begin
        hb_cnt <= hb_cnt + 1;
        if (&hb_cnt) led <= ~led;
    end

    // -------------------------------------------------------------------------
    // 8bpp framebuffer (8192 bytes, 128×64). Static — loaded from the .mem file produced by tools/oled-bake at build time. No runtime writes for Phase 2A; dynamic content comes in Phase 2B once the renderer is wired up.
    // -------------------------------------------------------------------------
    reg [7:0] fb [0:8191];
    initial $readmemh("oled_text.mem", fb);

    // -------------------------------------------------------------------------
    // CE — divides clk down so the OLED FSM ticks at ~3.5 MHz
    // -------------------------------------------------------------------------
    reg [$clog2(CLK_DIV)-1:0] cnt = 0;
    wire at_top = (cnt == CLK_DIV - 1);
    always @(posedge clk) cnt <= at_top ? 0 : cnt + 1;
    reg ce = 0;
    always @(posedge clk) ce <= at_top;

    // -------------------------------------------------------------------------
    // I2C driver
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
    // SSD1306 init sequence (same 25 bytes as top_pin_id)
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
    // OLED pump FSM
    // -------------------------------------------------------------------------
    localparam [2:0]
        ST_RESET   = 3'd0, ST_SEND    = 3'd1, ST_WAIT  = 3'd2,
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

    reg [7:0] fb_dout = 0;

    always @(posedge clk) if (ce) begin
        fb_dout <= fb[{page, gather_cnt[2:0], col}];
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
                            if (cmd_idx == 0)         begin i2c_data <= I2C_ADDR;            i2c_send_stop <= 0; end
                            else if (cmd_idx == 1)    begin i2c_data <= CMD_PREFIX;          i2c_send_stop <= 0; end
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

            // Gather 8 rows for one OLED page-column byte.
            // gc=0: address driven; fb_dout valid at gc=1.
            // gc=1..8: dither fb_dout >= TRNG threshold, shift into px_byte.
            ST_GATHER: begin
                gather_cnt <= gather_cnt + 1;
                if (gather_cnt >= 4'd1) begin
                    px_byte <= {(fb_dout >= trng_out), px_byte[7:1]};
                end
                if (gather_cnt == 4'd8) begin
                    gather_cnt <= 0;
                    state      <= ST_SEND;
                end
            end
        endcase
    end

endmodule
