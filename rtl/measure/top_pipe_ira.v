// =============================================================================
// top_pipe_ira.v — first-silicon KORE → ORA ceremony
// =============================================================================
//
// Minimal hardware top for the provisioning ceremony. Press Enter on the
// dozenal keypad (kp_col / R13) and the FPGA runs KOHI (~110 ms gather) →
// BLAKE3 (~22 ms hash) → TAHU (8 OTP burns) and the LEDs walk through:
//
//   T6 (onboard LED, active-low):
//     OFF                  → power-up KORE (provisionable, idle)
//     fast blink           → ceremony_busy (KOHI / BLAKE3 / TAHU running)
//     solid ON             → ORA / HARA / WHARA (post-provisioning)
//     OFF (with T2 lit)    → NGARO
//
//   T2 (J4 ext LED):
//     OFF                  → not NGARO
//     solid ON             → NGARO (silent chip per [[pipe-ngaro-state-silent-wire]])
//
// OTP state does not persist across power cycles in FPGA emulation — every
// boot starts KORE, every press provisions a *fresh* ira derived from
// real ring entropy gathered live.
//
// This is the first silicon manifestation of the full IRA ceremony.
// =============================================================================

`timescale 1ns / 1ps

module top_pipe_ira (
    input  wire clk,            // 25 MHz crystal (P6)

    // Dozenal keypad (11 bidirectional pins, all PULLMODE=UP)
    inout  wire kp_p27,         // matrix row 0
    inout  wire kp_p28,         // matrix row 1
    inout  wire kp_p44,         // matrix row 2 / Decimal shared
    inout  wire kp_p51,         // matrix row 3
    inout  wire kp_p49,         // matrix col 0
    inout  wire kp_p63,         // matrix col 1 / Divide shared
    inout  wire kp_p62,         // matrix col 2 / Negate shared / Multiply special
    inout  wire kp_p56,         // matrix col 3
    inout  wire kp_p50,         // ad-hoc: Negate
    inout  wire kp_p57,         // ad-hoc: Decimal
    inout  wire kp_p58,         // ad-hoc: Divide

    output wire oled_scl,       // SSD1306 I2C clock (P2)
    output wire oled_sda,       // SSD1306 I2C data  (R2)
    output reg  led,            // T6 onboard LED — ceremony status
    output reg  ext_led         // T2 J4 LED — NGARO indicator
);

    // =========================================================================
    // 16 RING OSCILLATORS — odd primes 3..59
    //   stages: 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59
    // Same instantiation pattern proven by top_pipe_ring_scope.v.
    // =========================================================================
    localparam integer N_RINGS = 16;
    wire [N_RINGS-1:0] ring_out;

    (* noglobal *) wire [2:0]  r0_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r0_inv (.A(r0_q[2]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r0_q[0]));
    (* keep *) LUT4 #(.INIT(16'hAAAA)) r0_b1  (.A(r0_q[0]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r0_q[1]));
    (* keep *) LUT4 #(.INIT(16'hAAAA)) r0_b2  (.A(r0_q[1]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r0_q[2]));
    assign ring_out[0] = r0_q[0];

    (* noglobal *) wire [4:0]  r1_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r1_inv (.A(r1_q[4]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r1_q[0]));
    genvar g1;
    generate for (g1 = 1; g1 < 5; g1 = g1 + 1) begin : r1_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r1_q[g1-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r1_q[g1]));
    end endgenerate
    assign ring_out[1] = r1_q[0];

    (* noglobal *) wire [6:0]  r2_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r2_inv (.A(r2_q[6]),  .B(1'b0), .C(1'b0), .D(1'b0), .Z(r2_q[0]));
    genvar g2;
    generate for (g2 = 1; g2 < 7; g2 = g2 + 1) begin : r2_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r2_q[g2-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r2_q[g2]));
    end endgenerate
    assign ring_out[2] = r2_q[0];

    (* noglobal *) wire [10:0] r3_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r3_inv (.A(r3_q[10]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r3_q[0]));
    genvar g3;
    generate for (g3 = 1; g3 < 11; g3 = g3 + 1) begin : r3_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r3_q[g3-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r3_q[g3]));
    end endgenerate
    assign ring_out[3] = r3_q[0];

    (* noglobal *) wire [12:0] r4_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r4_inv (.A(r4_q[12]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r4_q[0]));
    genvar g4;
    generate for (g4 = 1; g4 < 13; g4 = g4 + 1) begin : r4_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r4_q[g4-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r4_q[g4]));
    end endgenerate
    assign ring_out[4] = r4_q[0];

    (* noglobal *) wire [16:0] r5_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r5_inv (.A(r5_q[16]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r5_q[0]));
    genvar g5;
    generate for (g5 = 1; g5 < 17; g5 = g5 + 1) begin : r5_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r5_q[g5-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r5_q[g5]));
    end endgenerate
    assign ring_out[5] = r5_q[0];

    (* noglobal *) wire [18:0] r6_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r6_inv (.A(r6_q[18]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r6_q[0]));
    genvar g6;
    generate for (g6 = 1; g6 < 19; g6 = g6 + 1) begin : r6_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r6_q[g6-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r6_q[g6]));
    end endgenerate
    assign ring_out[6] = r6_q[0];

    (* noglobal *) wire [22:0] r7_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r7_inv (.A(r7_q[22]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r7_q[0]));
    genvar g7;
    generate for (g7 = 1; g7 < 23; g7 = g7 + 1) begin : r7_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r7_q[g7-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r7_q[g7]));
    end endgenerate
    assign ring_out[7] = r7_q[0];

    (* noglobal *) wire [28:0] r8_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r8_inv (.A(r8_q[28]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r8_q[0]));
    genvar g8;
    generate for (g8 = 1; g8 < 29; g8 = g8 + 1) begin : r8_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r8_q[g8-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r8_q[g8]));
    end endgenerate
    assign ring_out[8] = r8_q[0];

    (* noglobal *) wire [30:0] r9_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r9_inv (.A(r9_q[30]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r9_q[0]));
    genvar g9;
    generate for (g9 = 1; g9 < 31; g9 = g9 + 1) begin : r9_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r9_q[g9-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r9_q[g9]));
    end endgenerate
    assign ring_out[9] = r9_q[0];

    (* noglobal *) wire [36:0] r10_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r10_inv (.A(r10_q[36]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r10_q[0]));
    genvar g10;
    generate for (g10 = 1; g10 < 37; g10 = g10 + 1) begin : r10_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r10_q[g10-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r10_q[g10]));
    end endgenerate
    assign ring_out[10] = r10_q[0];

    (* noglobal *) wire [40:0] r11_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r11_inv (.A(r11_q[40]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r11_q[0]));
    genvar g11;
    generate for (g11 = 1; g11 < 41; g11 = g11 + 1) begin : r11_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r11_q[g11-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r11_q[g11]));
    end endgenerate
    assign ring_out[11] = r11_q[0];

    (* noglobal *) wire [42:0] r12_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r12_inv (.A(r12_q[42]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r12_q[0]));
    genvar g12;
    generate for (g12 = 1; g12 < 43; g12 = g12 + 1) begin : r12_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r12_q[g12-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r12_q[g12]));
    end endgenerate
    assign ring_out[12] = r12_q[0];

    (* noglobal *) wire [46:0] r13_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r13_inv (.A(r13_q[46]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r13_q[0]));
    genvar g13;
    generate for (g13 = 1; g13 < 47; g13 = g13 + 1) begin : r13_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r13_q[g13-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r13_q[g13]));
    end endgenerate
    assign ring_out[13] = r13_q[0];

    (* noglobal *) wire [52:0] r14_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r14_inv (.A(r14_q[52]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r14_q[0]));
    genvar g14;
    generate for (g14 = 1; g14 < 53; g14 = g14 + 1) begin : r14_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r14_q[g14-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r14_q[g14]));
    end endgenerate
    assign ring_out[14] = r14_q[0];

    (* noglobal *) wire [58:0] r15_q;
    (* keep *) LUT4 #(.INIT(16'h5555)) r15_inv (.A(r15_q[58]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r15_q[0]));
    genvar g15;
    generate for (g15 = 1; g15 < 59; g15 = g15 + 1) begin : r15_buf
        (* keep *) LUT4 #(.INIT(16'hAAAA)) buf_ (.A(r15_q[g15-1]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(r15_q[g15]));
    end endgenerate
    assign ring_out[15] = r15_q[0];

    // =========================================================================
    // Reset synchronizer + power-on hold (~1 ms at 25 MHz)
    // =========================================================================
    reg [15:0] por_cnt = 16'b0;
    reg        reset_n = 1'b0;
    always @(posedge clk) begin
        if (!&por_cnt) por_cnt <= por_cnt + 16'd1;
        reset_n <= &por_cnt;
    end

    // =========================================================================
    // Keypad scanner — full 18-key dozenal scanner (3-phase: Multiply detect,
    // 4×4 matrix scan, 3 ad-hoc keys). Emits press_pulse on each new press.
    // =========================================================================
    wire [4:0] key_code;
    wire       key_valid;
    wire       key_press_pulse;
    wire       multiply_held, shift_held;

    keypad u_keypad (
        .clk          (clk),
        .reset_n      (reset_n),
        .p27_row0     (kp_p27),
        .p28_row1     (kp_p28),
        .p44_row2     (kp_p44),
        .p51_row3     (kp_p51),
        .p49_col0     (kp_p49),
        .p63_col1     (kp_p63),
        .p62_col2     (kp_p62),
        .p56_col3     (kp_p56),
        .p50_negate   (kp_p50),
        .p57_decimal  (kp_p57),
        .p58_divide   (kp_p58),
        .o_key        (key_code),
        .o_key_valid  (key_valid),
        .press_pulse  (key_press_pulse),
        .multiply_held(multiply_held),
        .shift_held   (shift_held)
    );

    // Key role assignments:
    //   Enter — provision_request (run KOHI → BLAKE3 → TAHU)
    //   Zil   — OLED screen 0 (STATUS)
    //   Zila  — OLED screen 1 (IRA HEX)
    //   Zilor — OLED screen 2 (OTP SLOTS)
    wire provision_request = key_press_pulse && (key_code == 5'd15);

    // OLED display mode register. Direct addressing: each "screen key" sets
    // the mode register to its corresponding value. Other keys don't touch it.
    reg [1:0] mode;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mode <= 2'd1;  // boot defaults to IRA HEX (the most useful first view)
        end else if (key_press_pulse) begin
            case (key_code)
                5'd14: mode <= 2'd0;  // Zil   → STATUS
                5'd13: mode <= 2'd1;  // Zila  → IRA HEX
                5'd12: mode <= 2'd2;  // Zilor → OTP SLOTS
                default: ;            // other keys leave mode alone
            endcase
        end
    end

    // =========================================================================
    // trng — feeds blake3_tree
    // =========================================================================
    wire [12:0] buf_raddr;
    wire [7:0]  buf_rdata;
    wire        trng_busy, trng_gather_done, trng_health_fail;
    wire [15:0] trng_ring_health;
    wire [4:0]  trng_ring_health_cnt;
    wire [15:0] trng_ring_enable;
    wire        trng_start, blake3_start;

    trng u_trng (
        .clk            (clk),
        .reset_n        (reset_n),
        .start          (trng_start),
        .ring_in        (ring_out),
        .buf_raddr      (buf_raddr),
        .buf_rdata      (buf_rdata),
        .busy           (trng_busy),
        .gather_done    (trng_gather_done),
        .health_fail    (trng_health_fail),
        .ring_health    (trng_ring_health),
        .ring_health_cnt(trng_ring_health_cnt),
        .ring_enable    (trng_ring_enable)
    );

    // =========================================================================
    // blake3_tree — shares the trng buffer port
    // =========================================================================
    wire        blake3_busy, blake3_ira_valid;
    wire [255:0] blake3_ira;

    blake3_tree u_blake3 (
        .clk      (clk),
        .reset_n  (reset_n),
        .start    (blake3_start),
        .buf_raddr(buf_raddr),
        .buf_rdata(buf_rdata),
        .ira      (blake3_ira),
        .ira_valid(blake3_ira_valid),
        .busy     (blake3_busy)
    );

    // =========================================================================
    // OTP — 8 slots × 256 bits, POR=KORE
    // =========================================================================
    wire [2:0]            otp_write_addr;
    wire [255:0]          otp_write_data;
    wire                  otp_write_enable;
    wire                  otp_write_done, otp_write_rejected;
    wire [7:0]            otp_burned_mask;
    wire [8*256-1:0]      all_slots_flat;

    otp u_otp (
        .clk           (clk),
        .reset_n       (reset_n),
        .wipe          (1'b0),
        .read_addr     (3'b0),
        .read_data     (),
        .read_burned   (),
        .write_addr    (otp_write_addr),
        .write_data    (otp_write_data),
        .write_enable  (otp_write_enable),
        .write_done    (otp_write_done),
        .write_rejected(otp_write_rejected),
        .burned_mask   (otp_burned_mask),
        .all_slots_flat(all_slots_flat)
    );

    // =========================================================================
    // inverted_pair_verify — combinational classifier
    // =========================================================================
    wire [1:0]   chip_state;
    wire         chip_state_ngaro;
    wire         byzantine_ok;
    wire [255:0] recovered_ira;

    wire verify_state_valid;
    inverted_pair_verify u_verify (
        .clk         (clk),
        .reset_n     (reset_n),
        .slot_flat   (all_slots_flat),
        .state_valid (verify_state_valid),
        .pair_kore (),
        .pair_valid  (),
        .pair_corrupt(),
        .valid_count (),
        .all_kore  (),
        .agreement_ok(),
        .byzantine_ok(byzantine_ok),
        .chip_ngaro  (chip_state_ngaro),
        .state       (chip_state),
        .ira         (recovered_ira)
    );

    // =========================================================================
    // ira_fsm — the orchestrator
    // =========================================================================
    wire chip_ngaro, ceremony_busy, ceremony_done;
    wire [3:0] fsm_state;

    ira_fsm u_fsm (
        .clk               (clk),
        .reset_n           (reset_n),
        .provision_request (provision_request),
        .chip_state        (chip_state),
        .chip_state_ngaro  (chip_state_ngaro),
        .byzantine_ok      (byzantine_ok),
        .trng_start        (trng_start),
        .trng_busy         (trng_busy),
        .trng_gather_done  (trng_gather_done),
        .trng_health_fail  (trng_health_fail),
        .blake3_start      (blake3_start),
        .blake3_busy       (blake3_busy),
        .blake3_ira_valid  (blake3_ira_valid),
        .blake3_ira        (blake3_ira),
        .otp_write_addr    (otp_write_addr),
        .otp_write_data    (otp_write_data),
        .otp_write_enable  (otp_write_enable),
        .otp_write_done    (otp_write_done),
        .otp_write_rejected(otp_write_rejected),
        // FPGA dev rig: bench supply has effectively unbounded stored energy.
        .energy_ok         (1'b1),
        .chip_ngaro       (chip_ngaro),
        .ceremony_busy     (ceremony_busy),
        .ceremony_done     (ceremony_done),
        .fsm_state         (fsm_state)
    );

    // =========================================================================
    // LED state machine
    //   T6 (active-low, so output = ~drive_value):
    //     ceremony_busy → fast blink (every 2^21 cycles ≈ 12 Hz at 25 MHz)
    //     post-ORA   → solid on
    //     KORE idle    → off
    //     NGARO         → off (T2 carries the NGARO indicator)
    //   T2 (active-high, since T2 drives the ext LED through a buffer):
    //     chip_ngaro    → solid on
    //     else           → off
    // =========================================================================
    reg [23:0] blink_div = 24'b0;
    always @(posedge clk) blink_div <= blink_div + 24'd1;

    wire blink_fast = blink_div[20];     // ~12 Hz
    wire chip_operational = (chip_state >= 2'd1);

    always @(posedge clk) begin
        if (chip_ngaro) begin
            led     <= 1'b1;   // OFF (active-low)
            ext_led <= 1'b1;   // ON (T2 buffer logic — match scope convention)
        end else if (ceremony_busy) begin
            led     <= blink_fast;       // fast blink while working
            ext_led <= 1'b0;             // off
        end else if (chip_operational) begin
            led     <= 1'b0;   // solid ON (active-low)
            ext_led <= 1'b0;
        end else begin
            led     <= 1'b1;   // OFF (KORE, idle)
            ext_led <= 1'b0;
        end
    end

    // =========================================================================
    // OLED hex-display of ira
    //
    // 8 KB byte-greyscale framebuffer shared between the text renderer (write
    // port) and the SSD1306 driver (read port). The renderer paints 4 lines of
    // 16 hex chars each = the 64 nibbles of recovered_ira[255:0] (MSB at top
    // left, descending row-major). On every ceremony_done pulse the renderer
    // is re-triggered with the freshly-burned ira string.
    // =========================================================================
    localparam integer FB_W = 128;
    localparam integer FB_H = 64;
    localparam integer N_LINES            = 4;
    localparam integer MAX_CHARS_PER_LINE = 24;
    localparam integer STR_LEN            = N_LINES * MAX_CHARS_PER_LINE;

    reg [7:0]  fb [0:FB_W*FB_H-1];
    initial begin : fb_init
        integer fbi;
        for (fbi = 0; fbi < FB_W*FB_H; fbi = fbi + 1) fb[fbi] = 8'h00;
    end

    wire        rend_we;
    wire [12:0] rend_waddr;
    wire  [7:0] rend_wdata;
    wire [12:0] oled_raddr;
    reg   [7:0] oled_rdata;

    // CE divider matching oled_greyscale_driver's CLK_DIV=7. The driver
    // advances per-CE, so its combinational fb_raddr also changes per-CE.
    // We MUST gate the framebuffer read with this same CE pulse — otherwise
    // fb_rdata races ahead each clock and the driver captures the WRONG
    // byte at each CE pulse (verified by top_oled_diag: ungated per-clk
    // read causes bytes 0..7 to wrap to 1..7,0, producing a mirror-reflect
    // pattern around bit 4 in each OLED page byte). Per-clk read works for
    // random data (ring scope) but fails for structured data (hex glyphs).
    localparam integer OLED_CLK_DIV = 7;
    reg [2:0] ce_cnt = 3'b0;
    wire ce_at_top = (ce_cnt == OLED_CLK_DIV - 1);
    always @(posedge clk) ce_cnt <= ce_at_top ? 3'b0 : ce_cnt + 3'd1;
    reg ce_pulse = 1'b0;
    always @(posedge clk) ce_pulse <= ce_at_top;

    // Separate always blocks for write and read ports — forces yosys to
    // infer true dual-port BRAM (DP16KD with W port + R port) rather than
    // a single-port + read-or-write arbiter, which would corrupt OLED
    // reads during renderer writes.
    always @(posedge clk) begin
        if (rend_we) fb[rend_waddr] <= rend_wdata;
    end
    always @(posedge clk) begin
        if (ce_pulse) oled_rdata <= fb[oled_raddr];
    end

    // -------------------------------------------------------------------------
    // Screen content selector. oled_mode_fsm composes the 4×24 text grid
    // (768 bits = strings_flat) from the current mode + chip state.
    // -------------------------------------------------------------------------
    wire [STR_LEN*8-1:0] strings_flat;

    oled_mode_fsm #(
        .N_LINES           (N_LINES),
        .MAX_CHARS_PER_LINE(MAX_CHARS_PER_LINE),
        .SLOT_BITS         (256)
    ) u_mode_fsm (
        .mode            (mode),
        .ira             (recovered_ira),
        .chip_state      (chip_state),
        .chip_state_ngaro  (chip_state_ngaro),
        .ring_health_cnt (trng_ring_health_cnt),
        .slot_flat       (all_slots_flat),
        .ring_rct_fail   (16'b0),
        .ring_apt_fail   (16'b0),
        .ring_level_fail (112'b0),
        .strings_flat    (strings_flat)
    );

    // -------------------------------------------------------------------------
    // Re-render request: pulse on every ceremony_done, mode change, or
    // chip_state change. Also pulse once shortly after reset so the boot
    // screen renders.
    // -------------------------------------------------------------------------
    reg [3:0] re_render_init_cnt;
    reg [1:0] last_chip_state;
    reg [1:0] last_mode;
    reg       re_render_req;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            re_render_init_cnt <= 4'd0;
            re_render_req      <= 1'b0;
            last_chip_state    <= 3'd0;
            last_mode          <= 2'd0;
        end else begin
            re_render_req <= 1'b0;
            if (re_render_init_cnt != 4'd15) begin
                re_render_init_cnt <= re_render_init_cnt + 4'd1;
                if (re_render_init_cnt == 4'd14)
                    re_render_req <= 1'b1;
            end
            if (ceremony_done)                  re_render_req <= 1'b1;
            if (chip_state != last_chip_state)  re_render_req <= 1'b1;
            if (mode != last_mode)              re_render_req <= 1'b1;
            last_chip_state <= chip_state;
            last_mode       <= mode;
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

endmodule
