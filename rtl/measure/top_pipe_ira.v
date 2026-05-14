// =============================================================================
// top_pipe_ira.v — first-silicon VIRGIN → HEALTHY ceremony
// =============================================================================
//
// Minimal hardware top for the provisioning ceremony. Press Enter on the
// dozenal keypad (kp_col / R13) and the FPGA runs KOHI (~110 ms gather) →
// BLAKE3 (~22 ms hash) → TAHU (8 OTP burns) and the LEDs walk through:
//
//   T6 (onboard LED, active-low):
//     OFF                  → power-up VIRGIN (provisionable, idle)
//     fast blink           → ceremony_busy (KOHI / BLAKE3 / TAHU running)
//     solid ON             → HEALTHY / DEGRADED (post-provisioning)
//     OFF (with T2 lit)    → FUCKED
//
//   T2 (J4 ext LED):
//     OFF                  → not FUCKED
//     solid ON             → FUCKED (silent chip per [[pipe-fucked-state-silent-wire]])
//
// OTP state does not persist across power cycles in FPGA emulation — every
// boot starts VIRGIN, every press provisions a *fresh* ira derived from
// real ring entropy gathered live.
//
// This is the first silicon manifestation of the full IRA ceremony.
// =============================================================================

`timescale 1ns / 1ps

module top_pipe_ira (
    input  wire clk,           // 25 MHz crystal (P6)
    output wire kp_row,        // dozenal keypad p51 (P14) — driven LOW
    input  wire kp_col,        // dozenal keypad p56 (R13) — Enter triggers provision
    output reg  led,           // T6 onboard LED — ceremony status
    output reg  ext_led        // T2 J4 LED — FUCKED indicator
);

    assign kp_row = 1'b0;
    wire btn_raw = kp_col;     // active-low button

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
    // Button debounce + edge detect — same pattern as ring_scope
    // =========================================================================
    reg [1:0]  btn_sync = 2'b11;
    always @(posedge clk) btn_sync <= {btn_sync[0], btn_raw};
    wire btn_clean = btn_sync[1];        // active-low, synced

    reg [3:0]  btn_stable_cnt = 0;
    reg        btn_state      = 1'b1;    // released
    reg        btn_state_prev = 1'b1;
    always @(posedge clk) begin
        if (btn_clean == btn_state) begin
            btn_stable_cnt <= 0;
        end else begin
            btn_stable_cnt <= btn_stable_cnt + 4'd1;
            if (&btn_stable_cnt) btn_state <= btn_clean;
        end
        btn_state_prev <= btn_state;
    end

    wire provision_request = btn_state_prev & ~btn_state;  // falling edge = press

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
    // OTP — 8 slots × 256 bits, POR=VIRGIN
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
    wire [2:0]   chip_state;
    wire         byzantine_ok;
    wire [255:0] recovered_ira;

    wire verify_state_valid;
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
    // ira_fsm — the orchestrator
    // =========================================================================
    wire chip_fucked, ceremony_busy, ceremony_done;
    wire [2:0] fsm_state;

    ira_fsm u_fsm (
        .clk               (clk),
        .reset_n           (reset_n),
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
    //   T6 (active-low, so output = ~drive_value):
    //     ceremony_busy → fast blink (every 2^21 cycles ≈ 12 Hz at 25 MHz)
    //     post-HEALTHY   → solid on
    //     VIRGIN idle    → off
    //     FUCKED         → off (T2 carries the FUCKED indicator)
    //   T2 (active-high, since T2 drives the ext LED through a buffer):
    //     chip_fucked    → solid on
    //     else           → off
    // =========================================================================
    reg [23:0] blink_div = 24'b0;
    always @(posedge clk) blink_div <= blink_div + 24'd1;

    wire blink_fast = blink_div[20];     // ~12 Hz
    wire chip_alive = (chip_state >= 3'd2);

    always @(posedge clk) begin
        if (chip_fucked) begin
            led     <= 1'b1;   // OFF (active-low)
            ext_led <= 1'b1;   // ON (T2 buffer logic — match scope convention)
        end else if (ceremony_busy) begin
            led     <= blink_fast;       // fast blink while working
            ext_led <= 1'b0;             // off
        end else if (chip_alive) begin
            led     <= 1'b0;   // solid ON (active-low)
            ext_led <= 1'b0;
        end else begin
            led     <= 1'b1;   // OFF (VIRGIN, idle)
            ext_led <= 1'b0;
        end
    end

endmodule
