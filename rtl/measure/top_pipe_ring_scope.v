// =============================================================================
// top_pipe_ring_scope.v — 8-ring entropy scope, button-triggered acquisition
// =============================================================================
//
// Eight ring oscillators (stages 3, 5, 7, 11, 13, 17, 19, 23). Each press of
// the dozenal-keypad Enter key (matrix p51+p56) advances the currently-
// selected ring index (0→1→2→...→7→0) and triggers ONE acquisition for that
// ring: 8192 raw sample bits at 25 MHz sysclock, one bit per OLED pixel,
// filling the entire 128×64 display.
//
// Raw bit mapping: sample bit 0 → 0x00 (black pixel), sample bit 1 → 0xFF
// (white pixel). The greyscale driver's dither passes these through
// unchanged because 0 always loses against the dither threshold and 0xFF
// always wins.
//
// Display: full 128×64 OLED shows the most recently acquired ring's
// raw bit pattern. Previous ring's data is overwritten on next press.
//
// Total acquisition time: 8192 cycles + 256-cycle warmup = ~340 µs at 25 MHz.
//
// Visual interpretation:
//   Uniform random ring → speckle of black/white pixels, no obvious structure
//   Stuck/biased ring   → mostly black or mostly white
//   Locked / patterned  → visible periodic structure (stripes, dots)
//
// Visual feedback: holding Enter blanks the entire OLED to black; releasing
// returns to the last acquired bitmap.
// =============================================================================

`timescale 1ns / 1ps

module top_pipe_ring_scope #(
    parameter integer CLK_DIV = 7
)(
    input  wire clk,           // 25 MHz crystal (P6)
    output wire kp_row,        // dozenal keypad p51 (P14) — driven LOW continuously
    input  wire kp_col,        // dozenal keypad p56 (R13) — Enter (advance + resample)
    input  wire kp_col2,       // dozenal keypad p49 (P12) — Zilor (resample current ring)
    output wire oled_scl,
    output wire oled_sda,
    output reg  led,           // T6 onboard LED — Geiger-style random flicker
    output reg  ext_led        // T2 J4-pin-6 keypad LED — solid ON during XOR mode
);

    // Dozenal keypad: two keys both share row pin p51, both active-low when pressed.
    //   Enter (51+56) → kp_col  → ADVANCE to next ring + acquire
    //   Zilor (49+51) → kp_col2 → RESAMPLE current ring (no advance)
    assign kp_row = 1'b0;
    wire btn  = kp_col;
    wire btn2 = kp_col2;

    localparam integer N_RINGS = 8;
    localparam integer SAMPLES_PER_PIXEL = 256;
    localparam integer COLS = 128;

    // =========================================================================
    // 8 RING OSCILLATORS — inline LUT4 chains with primes 3, 5, 7, 11, 13, 17, 19, 23
    // Each ring has a GATED inverter at stage 0: Z = enable & ~A
    // LUT4 INIT = 16'h4444 implements (B & ~A) with A=feedback, B=enable
    // When enable=0: loop drives constant 0, no oscillation, no switching noise
    // When enable=1: stage 0 inverts, loop oscillates normally
    //
    // Per-ring enable: only the currently-selected ring oscillates, and only
    // while an acquisition is active. All other times all 8 rings are silent.
    // =========================================================================
    wire [N_RINGS-1:0] ring_out;
    wire [N_RINGS-1:0] ring_enable;

    // Ring 0: 3 stages
    (* noglobal *) wire [2:0]  r0_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r0_inv (.A(r0_q[2]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r0_q[0]));
    (* keep *) LUT4 #(.INIT(16'hAAAA)) r0_b1  (.A(r0_q[0]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r0_q[1]));
    (* keep *) LUT4 #(.INIT(16'hAAAA)) r0_b2  (.A(r0_q[1]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r0_q[2]));
    assign ring_out[0] = r0_q[0];

    // Ring 1: 5 stages
    (* noglobal *) wire [4:0]  r1_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r1_inv (.A(r1_q[4]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r1_q[0]));
    genvar g1;
    generate
        for (g1 = 1; g1 < 5; g1 = g1 + 1) begin : r1_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r1_q[g1-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r1_q[g1]));
        end
    endgenerate
    assign ring_out[1] = r1_q[0];

    // Ring 2: 7 stages
    (* noglobal *) wire [6:0]  r2_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r2_inv (.A(r2_q[6]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r2_q[0]));
    genvar g2;
    generate
        for (g2 = 1; g2 < 7; g2 = g2 + 1) begin : r2_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r2_q[g2-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r2_q[g2]));
        end
    endgenerate
    assign ring_out[2] = r2_q[0];

    // Ring 3: 11 stages
    (* noglobal *) wire [10:0] r3_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r3_inv (.A(r3_q[10]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r3_q[0]));
    genvar g3;
    generate
        for (g3 = 1; g3 < 11; g3 = g3 + 1) begin : r3_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r3_q[g3-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r3_q[g3]));
        end
    endgenerate
    assign ring_out[3] = r3_q[0];

    // Ring 4: 13 stages
    (* noglobal *) wire [12:0] r4_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r4_inv (.A(r4_q[12]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r4_q[0]));
    genvar g4;
    generate
        for (g4 = 1; g4 < 13; g4 = g4 + 1) begin : r4_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r4_q[g4-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r4_q[g4]));
        end
    endgenerate
    assign ring_out[4] = r4_q[0];

    // Ring 5: 17 stages
    (* noglobal *) wire [16:0] r5_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r5_inv (.A(r5_q[16]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r5_q[0]));
    genvar g5;
    generate
        for (g5 = 1; g5 < 17; g5 = g5 + 1) begin : r5_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r5_q[g5-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r5_q[g5]));
        end
    endgenerate
    assign ring_out[5] = r5_q[0];

    // Ring 6: 19 stages
    (* noglobal *) wire [18:0] r6_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r6_inv (.A(r6_q[18]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r6_q[0]));
    genvar g6;
    generate
        for (g6 = 1; g6 < 19; g6 = g6 + 1) begin : r6_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r6_q[g6-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r6_q[g6]));
        end
    endgenerate
    assign ring_out[6] = r6_q[0];

    // Ring 7: 23 stages
    (* noglobal *) wire [22:0] r7_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r7_inv (.A(r7_q[22]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r7_q[0]));
    genvar g7;
    generate
        for (g7 = 1; g7 < 23; g7 = g7 + 1) begin : r7_buf
            (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r7_q[g7-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r7_q[g7]));
        end
    endgenerate
    assign ring_out[7] = r7_q[0];

    // =========================================================================
    // SAMPLING FFs — one per ring, latched on clk (25 MHz sysclock)
    // (* keep *) preserves the setup-violating FF
    // =========================================================================
    (* keep = "true" *) reg [N_RINGS-1:0] sample_ff;
    always @(posedge clk) sample_ff <= ring_out;

    // =========================================================================
    // BUTTON DEBOUNCE + EDGE DETECT
    // R7 is active-low. 2-FF sync, then 16-cycle stable hold, then 1-cycle pulse
    // on the press edge.
    // =========================================================================
    // Enter key (kp_col) debounce → btn_press (advance + acquire)
    reg [1:0]  btn_sync = 2'b11;
    always @(posedge clk) btn_sync <= {btn_sync[0], btn};
    wire btn_low = ~btn_sync[1];

    reg [19:0] btn_db_cnt = 0;
    reg        btn_db_state = 1'b0;  // 1 = pressed (debounced)
    reg        btn_db_prev  = 1'b0;
    wire       btn_press = btn_db_state && !btn_db_prev;

    always @(posedge clk) begin
        btn_db_prev <= btn_db_state;
        if (btn_low != btn_db_state) begin
            btn_db_cnt <= btn_db_cnt + 1;
            if (&btn_db_cnt) begin
                btn_db_state <= btn_low;
                btn_db_cnt   <= 0;
            end
        end else begin
            btn_db_cnt <= 0;
        end
    end

    // Zilor key (kp_col2) debounce → btn2_press (resample, no advance)
    reg [1:0]  btn2_sync = 2'b11;
    always @(posedge clk) btn2_sync <= {btn2_sync[0], btn2};
    wire btn2_low = ~btn2_sync[1];

    reg [19:0] btn2_db_cnt = 0;
    reg        btn2_db_state = 1'b0;
    reg        btn2_db_prev  = 1'b0;
    wire       btn2_press = btn2_db_state && !btn2_db_prev;

    always @(posedge clk) begin
        btn2_db_prev <= btn2_db_state;
        if (btn2_low != btn2_db_state) begin
            btn2_db_cnt <= btn2_db_cnt + 1;
            if (&btn2_db_cnt) begin
                btn2_db_state <= btn2_low;
                btn2_db_cnt   <= 0;
            end
        end else begin
            btn2_db_cnt <= 0;
        end
    end

    // =========================================================================
    // RING SELECTOR + ACQUISITION FSM
    // States:
    //   ACQ_IDLE     — waiting for button press
    //   ACQ_ACQUIRE  — sampling currently-selected ring across 128 columns,
    //                  256 samples per column, popcount per column → fb byte
    //
    // Acquisition: at sysclock rate, sample_ff[ring_sel] feeds a popcount
    // accumulator. After 256 samples, write popcount to fb at addr={ring_sel, col};
    // reset popcount; advance col. After 128 columns, stop and return to IDLE.
    // Total per acquisition: 128 × 256 = 32,768 cycles = ~1.31 ms.
    // =========================================================================
    // ring_sel: 0..7 = individual rings, 8 = XOR-of-all mode (9 states total)
    reg [3:0]  ring_sel = 4'd0;
    reg        acq_busy = 1'b0;
    reg        acq_warmup = 1'b0;
    reg [7:0]  acq_warmup_cnt = 0;
    reg [12:0] acq_pixel = 13'd0;     // 0..8191 — current pixel being filled
    reg [2:0]  acq_bit_idx = 3'd0;    // 0..7 — which bit of the byte we're filling
    reg [7:0]  acq_shifter = 8'd0;    // accumulating byte (bit-packed sample bits)

    // Source bit: individual ring sample if ring_sel < 8, else XOR of all 8 rings.
    wire current_sample = (ring_sel == 4'd8) ? (^sample_ff)
                                             : sample_ff[ring_sel[2:0]];

    // ring_enable signal computed for future use (not currently wired into
    // the inverters because nextpnr crashes on gated combinational loops).
    genvar ge;
    generate
        for (ge = 0; ge < N_RINGS; ge = ge + 1) begin : ring_en_gen
            assign ring_enable[ge] = acq_busy && ((ring_sel == ge[3:0]) || (ring_sel == 4'd8));
        end
    endgenerate

    // Framebuffer write port (driver reads, this top writes)
    reg [12:0] fb_waddr;
    reg [7:0]  fb_wdata;
    reg        fb_we;

    always @(posedge clk) begin
        fb_we <= 1'b0;

        if (!acq_busy) begin
            // IDLE — wait for button press
            if (btn_press) begin
                // Enter: advance ring_sel 0→1→...→8→0, then acquire
                ring_sel       <= (ring_sel == 4'd8) ? 4'd0 : (ring_sel + 4'd1);
                acq_busy       <= 1'b1;
                acq_warmup     <= 1'b1;
                acq_warmup_cnt <= 0;
                acq_pixel      <= 13'd0;
                acq_bit_idx    <= 3'd0;
                acq_shifter    <= 8'd0;
            end else if (btn2_press) begin
                // Zilor: resample the CURRENT ring (no advance)
                acq_busy       <= 1'b1;
                acq_warmup     <= 1'b1;
                acq_warmup_cnt <= 0;
                acq_pixel      <= 13'd0;
                acq_bit_idx    <= 3'd0;
                acq_shifter    <= 8'd0;
            end
        end else if (acq_warmup) begin
            if (acq_warmup_cnt == 8'd255) begin
                acq_warmup <= 1'b0;
            end else begin
                acq_warmup_cnt <= acq_warmup_cnt + 8'd1;
            end
        end else begin
            // ACQUIRE — 8 raw sample bits per pixel, bit-packed into one byte.
            // Sample N goes to bit N of the pixel's byte. The greyscale
            // driver dithers this byte against an LFSR for true 0–255
            // brightness. Total: 8192 pixels × 8 samples = 65,536 samples.
            if (acq_bit_idx == 3'd7) begin
                // 8th sample — commit the bit-packed byte to fb.
                fb_waddr <= acq_pixel;
                fb_wdata <= {current_sample, acq_shifter[7:1]};
                fb_we    <= 1'b1;

                if (acq_pixel == 13'd8191) begin
                    acq_busy  <= 1'b0;
                    acq_pixel <= 13'd0;
                end else begin
                    acq_pixel <= acq_pixel + 13'd1;
                end
                acq_bit_idx <= 3'd0;
                acq_shifter <= 8'd0;
            end else begin
                // Shift right: new sample at MSB, old bits shift down.
                // After 7 such shifts, acq_shifter[7:1] holds samples 0..6
                // in bit positions 1..7 (sample 0 ends up at bit 1, then
                // after the final commit-cycle's prepend, sample 0 is at bit 0).
                acq_shifter <= {current_sample, acq_shifter[7:1]};
                acq_bit_idx <= acq_bit_idx + 3'd1;
            end
        end
    end

    // =========================================================================
    // FRAMEBUFFER (8192 bytes = 8bpp, one byte per OLED pixel, full 128×64)
    //   Write port: acquisition FSM (one raw sample bit → 0x00 or 0xFF)
    //   Read port:  oled_greyscale_driver
    // =========================================================================
    reg [7:0] fb [0:8191];

    // Initialize to all-zero (black) so the screen is dark before any
    // acquisition. After first press, ring 1's full 128×64 raw-bit pattern
    // appears across the entire OLED.
    integer ii;
    initial begin
        for (ii = 0; ii < 8192; ii = ii + 1) fb[ii] = 8'd0;
    end

    always @(posedge clk) if (fb_we) fb[fb_waddr] <= fb_wdata;

    wire [12:0] fb_raddr;
    reg  [7:0]  fb_rdata_raw;
    always @(posedge clk) fb_rdata_raw <= fb[fb_raddr];

    // Visual feedback: while Enter is held down, force the entire OLED to
    // black by short-circuiting fb_rdata to 0. Release → display returns
    // to the just-acquired ring snapshot.
    wire btn_held = btn_db_state;
    wire [7:0] fb_rdata = btn_held ? 8'h00 : fb_rdata_raw;

    // =========================================================================
    // OLED DRIVER
    // =========================================================================
    wire driver_frame_pulse;
    oled_greyscale_driver #(.CLK_DIV(CLK_DIV)) driver (
        .clk(clk),
        .oled_scl(oled_scl),
        .oled_sda(oled_sda),
        .frame_pulse(driver_frame_pulse),
        .fb_raddr(fb_raddr),
        .fb_rdata(fb_rdata)
    );

    // =========================================================================
    // GEIGER LED on T6 — random flicker from ^sample_ff (XOR of all 8 rings).
    // Rarely flashes ON, briefly stays. Active-low.
    // =========================================================================
    reg [14:0] geiger_cnt = 15'd0;
    reg [7:0]  geiger_accum = 8'd0;
    wire       trng_bit = ^sample_ff;
    always @(posedge clk) begin
        geiger_accum <= geiger_accum + {7'd0, trng_bit};
        geiger_cnt   <= geiger_cnt + 15'd1;
        if (&geiger_cnt) begin
            // Sample every ~1.3 ms; threshold on the running random count.
            if (led && (geiger_accum < 8'd8))             // OFF→ON: ~3% chance
                led <= 1'b0;  // active-low: ON
            else if (!led && (geiger_accum < 8'd100))     // ON→OFF: ~39% chance
                led <= 1'b1;  // OFF
            geiger_accum <= 8'd0;
        end
    end

    // =========================================================================
    // KEYPAD LED on T2 (J4 pin 6) — solid ON when in XOR-of-all-rings mode
    // (ring_sel == 8). Active-low.
    // =========================================================================
    always @(posedge clk) begin
        ext_led <= (ring_sel == 4'd8) ? 1'b0 : 1'b1;
    end

endmodule
