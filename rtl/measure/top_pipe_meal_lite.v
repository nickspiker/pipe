// =============================================================================
// top_pipe_meal_lite.v — Meal Deal without runtime flash R/W
// =============================================================================
//
// Identical to top_pipe_meal.v EXCEPT the OTP backend is the emulated
// `otp.v` (RAM-backed, parameterizable via INIT_FILE) instead of the
// flash-backed `otp_persistent.v` + `spi_master.v` stack. The runtime SPI
// flash write path is the only piece of the meal deal that's blocked on the
// ECP5 USRMCLK quirk; skipping it lets the rest of the system demonstrate.
//
// Persistence story: instead of writing IRA to flash at runtime, the
// equivalent "burned eFuse" state is baked into the bitstream itself via the
// OTP_INIT_FILE parameter ($readmemh-loaded slot contents). One bitstream
// per IRA. For the demo:
//
//   v1: OTP_INIT_FILE="" → boots VIRGIN → ceremony generates IRA → displayed
//       on OLED. Same boot, host can also send challenges and verify
//       response = BLAKE3_keyed_hash(IRA, challenge).
//
//   v2: OTP_INIT_FILE=<file containing the IRA from v1's OLED> → boots
//       directly HEALTHY (no ceremony, no TRNG run) → challenges work
//       immediately → power cycle → same IRA, same response.
//
//   v3.<fault>: OTP_INIT_FILE=<corrupt fixture> → boots into the appropriate
//       FUCKED/DEGRADED state per inverted_pair_verify, demonstrating
//       classifier robustness against realistic eFuse failure modes
//       (interrupted programming, stuck bits).
//
// All other behavior — ring TRNG, BLAKE3 conditioning, ira_fsm orchestration,
// inverted_pair_verify classification, challenge-response over PIPE wire,
// OLED status displays — is unchanged from top_pipe_meal.v.
//
// LEDs:
//   T6 (active-low): mirrors ext_led for completeness; hard to see near power LED
//   T2 (active-high, ext): OFF→VIRGIN; ~12 Hz→busy; solid→HEALTHY; ~1.5 Hz→FUCKED
//
// =============================================================================

`timescale 1ns / 1ps

// Synthesis-time OTP slot contents are controlled by the build script via
//   `read_verilog -DOTP_INIT_FILE="<path>"` passed to otp.v's read.
// The macro defaults to "" (VIRGIN) inside otp.v when undefined.

module top_pipe_meal_lite (
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
    output reg  ext_led,        // T2 J4 LED — primary status

    // User button (R7, active-low, PULLMODE=UP). Held = wipe OTP slots back
    // to VIRGIN and reset the ceremony FSM so a fresh ceremony can run
    // without a USB power-cycle. Useful for v1 iterative testing.
    input  wire user_btn,

    // PIPE wire — bidirectional, carries challenge in / response out
    inout  wire pipe_pad        // E16
);

    // =========================================================================
    // 16 RING OSCILLATORS — odd primes 3..59
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
    // User button → wipe + ira_fsm reset.
    //
    // The button is active-low (PULLMODE=UP). Held = wipe slots back to
    // VIRGIN and hold ira_fsm in reset; release = ira_fsm leaves reset and
    // observes the (now-virgin) chip_state, ready to accept a fresh Enter
    // press to start the ceremony again.
    //
    // The wipe signal is intentionally kept SEPARATE from the POR reset_n.
    // POR reset_n preserves slot_data (eFuse semantics — fuses don't
    // un-burn from a reset pulse); the button-driven wipe is the dev-
    // convenience escape hatch only.
    // =========================================================================
    reg btn_sync0, btn_sync1, btn_sync2;
    always @(posedge clk) begin
        btn_sync0 <= ~user_btn;   // active-low input → active-high internal
        btn_sync1 <= btn_sync0;
        btn_sync2 <= btn_sync1;
    end
    wire wipe_active = btn_sync2 & reset_n;       // only after POR completes
    wire ira_fsm_reset_n = reset_n & ~wipe_active;

    // =========================================================================
    // Keypad scanner
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

    // Enter (key 15) — provision_request (run KOHI → BLAKE3 → TAHU)
    // Keys for mode select: "0"=STATUS, "1"=IRA HEX, "2"=OTP SLOTS, "A"=HEALTH DETAIL
    wire provision_request = key_press_pulse && (key_code == 5'd15);

    reg [1:0] mode;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mode <= 2'd1;  // boot default: IRA HEX (most useful for v1/v2 demos)
        end else if (key_press_pulse) begin
            case (key_code)
                5'd14: mode <= 2'd0;  // Zil   "0" → STATUS
                5'd13: mode <= 2'd1;  // Zila  "1" → IRA HEX
                5'd12: mode <= 2'd2;  // Zilor "2" → OTP SLOTS
                5'd10: mode <= 2'd3;  // "A" key → RING HEALTH DETAIL (diagnostic)
                default: ;
            endcase
        end
    end

    // =========================================================================
    // trng — feeds blake3_tree, surfaces per-ring failure diagnostics
    // =========================================================================
    wire [12:0] buf_raddr;
    wire [7:0]  buf_rdata;
    wire        trng_busy, trng_gather_done, trng_health_fail;
    wire [15:0] trng_ring_health;
    wire [4:0]  trng_ring_health_cnt;
    wire [15:0] trng_ring_enable;
    wire        trng_start, blake3_start;
    wire [15:0]  trng_ring_rct_fail;
    wire [15:0]  trng_ring_apt_fail;
    wire [111:0] trng_ring_level_fail;

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
        .ring_enable    (trng_ring_enable),
        .ring_rct_fail  (trng_ring_rct_fail),
        .ring_apt_fail  (trng_ring_apt_fail),
        .ring_level_fail(trng_ring_level_fail)
    );

    // =========================================================================
    // SHARED BLAKE3 core (ceremony OR challenge-response — never both)
    // =========================================================================
    wire        blake3_busy, blake3_ira_valid;
    wire [255:0] blake3_ira;

    wire [255:0] tree_b3_chain;
    wire [511:0] tree_b3_mblock;
    wire [63:0]  tree_b3_counter;
    wire [31:0]  tree_b3_numbytes;
    wire [31:0]  tree_b3_dflags;
    wire         tree_b3_valid;

    blake3_tree_shared u_blake3_tree (
        .clk          (clk),
        .reset_n      (reset_n),
        .start        (blake3_start),
        .buf_raddr    (buf_raddr),
        .buf_rdata    (buf_rdata),
        .ira          (blake3_ira),
        .ira_valid    (blake3_ira_valid),
        .busy         (blake3_busy),
        .o_b3_chain   (tree_b3_chain),
        .o_b3_mblock  (tree_b3_mblock),
        .o_b3_counter (tree_b3_counter),
        .o_b3_numbytes(tree_b3_numbytes),
        .o_b3_dflags  (tree_b3_dflags),
        .o_b3_valid   (tree_b3_valid),
        .i_b3_hash    (b3_shared_hash),
        .i_b3_done    (b3_shared_done)
    );

    wire [255:0] cr_blake3_chain;
    wire [511:0] cr_blake3_mblock;
    wire [63:0]  cr_blake3_counter;
    wire [31:0]  cr_blake3_numbytes;
    wire [31:0]  cr_blake3_dflags;
    wire         cr_blake3_start;
    wire [511:0] cr_blake3_hash;
    wire         cr_blake3_valid;

    wire [255:0] b3_shared_chain    = blake3_busy ? tree_b3_chain    : cr_blake3_chain;
    wire [511:0] b3_shared_mblock   = blake3_busy ? tree_b3_mblock   : cr_blake3_mblock;
    wire [63:0]  b3_shared_counter  = blake3_busy ? tree_b3_counter  : cr_blake3_counter;
    wire [31:0]  b3_shared_numbytes = blake3_busy ? tree_b3_numbytes : cr_blake3_numbytes;
    wire [31:0]  b3_shared_dflags   = blake3_busy ? tree_b3_dflags   : cr_blake3_dflags;
    wire         b3_shared_valid    = blake3_busy ? tree_b3_valid    : cr_blake3_start;
    wire [511:0] b3_shared_hash;
    wire         b3_shared_done;

    blake3 u_blake3_core (
        .i_clk     (clk),
        .i_reset   (reset_n),
        .i_ce      (1'b1),
        .i_chain   (b3_shared_chain),
        .i_mblock  (b3_shared_mblock),
        .i_counter (b3_shared_counter),
        .i_numbytes(b3_shared_numbytes),
        .i_dflags  (b3_shared_dflags),
        .i_valid   (b3_shared_valid),
        .o_hash    (b3_shared_hash),
        .o_valid   (b3_shared_done)
    );

    assign cr_blake3_hash  = b3_shared_hash;
    assign cr_blake3_valid = b3_shared_done;

    // =========================================================================
    // OTP — emulated 8×256 with optional synthesis-time INIT_FILE.
    //
    // INIT_FILE="" → boots VIRGIN, ceremony runs (v1).
    // INIT_FILE=<file> → slots pre-populated with baked IRA or fault fixture
    //                    (v2 / v3). slot_burned[i] is auto-derived from
    //                    (slot_data[i] != 0) inside otp.v.
    // =========================================================================
    wire [2:0]            otp_write_addr;
    wire [255:0]          otp_write_data;
    wire                  otp_write_enable;
    wire                  otp_write_done, otp_write_rejected;
    wire [7:0]            otp_burned_mask;
    wire [8*256-1:0]      all_slots_flat;

    otp u_otp (
        .clk            (clk),
        .reset_n        (reset_n),
        .wipe           (wipe_active),
        .read_addr      (3'b0),
        .read_data      (),
        .read_burned    (),
        .write_addr     (otp_write_addr),
        .write_data     (otp_write_data),
        .write_enable   (otp_write_enable),
        .write_done     (otp_write_done),
        .write_rejected (otp_write_rejected),
        .burned_mask    (otp_burned_mask),
        .all_slots_flat (all_slots_flat)
    );

    // =========================================================================
    // inverted_pair_verify — combinational classifier
    // =========================================================================
    wire [2:0]   chip_state;
    wire         byzantine_ok;
    wire [255:0] recovered_ira;
    wire         verify_state_valid;

    inverted_pair_verify u_verify (
        .clk         (clk),
        .reset_n     (reset_n),
        .slot_flat   (all_slots_flat),
        .state_valid (verify_state_valid),
        .pair_virgin (),
        .pair_valid  (),
        .pair_corrupt(),
        .valid_count (),
        .all_virgin  (),
        .agreement_ok(),
        .byzantine_ok(byzantine_ok),
        .state       (chip_state),
        .ira         (recovered_ira)
    );

    // =========================================================================
    // ira_fsm — KOHI → BLAKE3 → TAHU ceremony orchestrator
    // =========================================================================
    wire chip_fucked, ceremony_busy, ceremony_done;
    wire [2:0] fsm_state;

    ira_fsm u_fsm (
        .clk               (clk),
        .reset_n           (ira_fsm_reset_n),
        .provision_request (provision_request),
        .chip_state        (chip_state),
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
        .chip_fucked       (chip_fucked),
        .ceremony_busy     (ceremony_busy),
        .ceremony_done     (ceremony_done),
        .fsm_state         (fsm_state)
    );

    // =========================================================================
    // LED state machine
    //   ext_led (T2 active-high) is primary status:
    //     ring0-alive blink → VIRGIN idle
    //     ~12 Hz fast blink → ceremony busy
    //     solid             → HEALTHY (or DEGRADED, still alive)
    //     ~1.5 Hz slow      → FUCKED
    // =========================================================================
    reg [23:0] blink_div = 24'b0;
    always @(posedge clk) blink_div <= blink_div + 24'd1;
    wire blink_fast = blink_div[20];
    wire blink_slow = blink_div[23];
    wire chip_alive = (chip_state >= 3'd2);

    reg [21:0] ring0_div = 22'b0;
    always @(posedge ring_out[0]) ring0_div <= ring0_div + 22'd1;
    wire ring0_alive = ring0_div[21];

    always @(posedge clk) begin
        if (chip_fucked) begin
            led     <= ~blink_slow;
            ext_led <=  blink_slow;
        end else if (ceremony_busy) begin
            led     <= ~blink_fast;
            ext_led <=  blink_fast;
        end else if (chip_alive) begin
            led     <= 1'b0;
            ext_led <= 1'b1;
        end else begin
            led     <= 1'b1;
            ext_led <= ring0_alive;
        end
    end

    // =========================================================================
    // OLED — framebuffer + greyscale driver + text renderer + mode selector
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

    wire [STR_LEN*8-1:0] strings_flat;

    oled_mode_fsm #(
        .N_LINES           (N_LINES),
        .MAX_CHARS_PER_LINE(MAX_CHARS_PER_LINE),
        .SLOT_BITS         (256)
    ) u_mode_fsm (
        .mode            (mode),
        .ira             (recovered_ira),
        .chip_state      (chip_state),
        .ring_health_cnt (trng_ring_health_cnt),
        .slot_flat       (all_slots_flat),
        .ring_rct_fail   (trng_ring_rct_fail),
        .ring_apt_fail   (trng_ring_apt_fail),
        .ring_level_fail (trng_ring_level_fail),
        .strings_flat    (strings_flat)
    );

    // Re-render request: LATCHED until the renderer accepts it (i.e. leaves
    // its R_DONE idle state). Previously this was a 1-cycle pulse, which was
    // dropped if a new trigger fired while the renderer was still mid-frame
    // from a previous trigger. Specifically: ceremony_done fires the first
    // re-render; chip_state transitions VIRGIN→HEALTHY a few hundred cycles
    // later (after inverted_pair_verify finishes its sweep) and fires a
    // second re-render — but the first render is still in progress, so the
    // pulse is missed. Result: OLED shows a stale frame at the leftmost
    // chars of line 0 until the user manually triggers another re-render
    // by switching modes. Latching fixes this: each trigger SETS the request
    // flag, and the renderer's render_done falling edge clears it (= request
    // consumed).
    reg [3:0] re_render_init_cnt;
    reg [2:0] last_chip_state;
    reg [1:0] last_mode;
    reg       last_chip_fucked;
    reg       last_trng_health_fail;
    reg       last_trng_gather_done_seen;
    reg       re_render_req;
    reg       last_render_done;
    wire      render_done_w;            // from oled_text_renderer instance below
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            re_render_init_cnt         <= 4'd0;
            re_render_req              <= 1'b0;
            last_chip_state            <= 3'd0;
            last_mode                  <= 2'd0;
            last_chip_fucked           <= 1'b0;
            last_trng_health_fail      <= 1'b0;
            last_trng_gather_done_seen <= 1'b0;
            last_render_done           <= 1'b1;
        end else begin
            // Clear request the cycle AFTER render_done falls (renderer
            // left R_DONE = accepted our request and started painting).
            // Set has priority below, so simultaneous trigger + clear = set.
            last_render_done <= render_done_w;
            if (last_render_done && !render_done_w) re_render_req <= 1'b0;

            // Any trigger sets (and overrides clear in the same cycle).
            if (re_render_init_cnt != 4'd15) begin
                re_render_init_cnt <= re_render_init_cnt + 4'd1;
                if (re_render_init_cnt == 4'd14)
                    re_render_req <= 1'b1;
            end
            if (ceremony_done)                                       re_render_req <= 1'b1;
            if (chip_state != last_chip_state)                       re_render_req <= 1'b1;
            if (mode != last_mode)                                   re_render_req <= 1'b1;
            if (chip_fucked && !last_chip_fucked)                    re_render_req <= 1'b1;
            if (trng_health_fail && !last_trng_health_fail)          re_render_req <= 1'b1;
            if (trng_gather_done && !last_trng_gather_done_seen)     re_render_req <= 1'b1;
            last_chip_state            <= chip_state;
            last_mode                  <= mode;
            last_chip_fucked           <= chip_fucked;
            last_trng_health_fail      <= trng_health_fail;
            last_trng_gather_done_seen <= trng_gather_done;
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
        .render_done  (render_done_w),
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
    // PIPE wire — bidirectional I/O for challenge-response.
    // chal_resp_fsm takes ownership of wire after chip_alive. Until then wire
    // is tristated and pulled DOWN by the LPF (= idle LOW).
    // =========================================================================
    wire wire_out_internal;
    wire drive_en_internal;
    wire wire_in_synced;

    wire_io u_wire (
        .clk     (clk),
        .reset_n (reset_n),
        .drive_en(drive_en_internal),
        .wire_out(wire_out_internal),
        .wire_in (wire_in_synced),
        .pad     (pipe_pad)
    );

    // =========================================================================
    // Challenge-response FSM. On chip_alive, listens for 256-bit challenges
    // and responds with BLAKE3_keyed_hash(IRA, challenge) using shared blake3.
    // =========================================================================
    wire [3:0] cr_state_debug;

    chal_resp_fsm u_chal_resp (
        .clk             (clk),
        .reset_n         (reset_n),
        .chip_healthy    (chip_alive),
        .wire_in_sync    (wire_in_synced),
        .wire_out        (wire_out_internal),
        .drive_en        (drive_en_internal),
        .ira_value       (recovered_ira),
        .blake3_start    (cr_blake3_start),
        .blake3_chain    (cr_blake3_chain),
        .blake3_mblock   (cr_blake3_mblock),
        .blake3_counter  (cr_blake3_counter),
        .blake3_numbytes (cr_blake3_numbytes),
        .blake3_dflags   (cr_blake3_dflags),
        .blake3_valid    (cr_blake3_valid),
        .blake3_hash     (cr_blake3_hash),
        .fsm_state_debug (cr_state_debug)
    );

endmodule
