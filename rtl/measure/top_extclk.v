// top_extclk.v — pure frequency counter for an external RC-oscillator clock.
//
// Pot wired between ext_clk (E16) and osc_drive (F15). FPGA inverts ext_clk
// onto osc_drive, forming an RC oscillator whose frequency is set by the pot.
//
// Each frame (60 Hz, 1/60 sec window):
//   1. SAMPLE         — counter accumulates ext_clk edges for SNAP_INTERVAL
//                       cycles of the 25 MHz reference clock.
//   2. DISCONNECT     — gate counter input off, wait a couple of cycles for
//                       any in-flight ripple to settle.
//   3. READ           — snapshot count into count_snap (which directly equals
//                       the count over the window since the counter was reset
//                       at the start of this window).
//   4. RESET          — async-reset the counter back to zero.
//   5. RECONNECT      — re-enable counter input, restart the window.
//
// count_snap × K >> 32 = milli-MHz integer (K calibrated so 25 MHz reads
// 25.000). Double-dabble produces 7 BCD digits → glyph render → OLED.
//
// Below the digits, a 32-cell × 16-row binary ruler shows count_snap with
// light-grey blocks for 1s and dark-grey blocks for 0s, MSB on the left.
//
// All display values are latched into display_* registers on snap_pulse so
// the OLED only changes at frame boundaries.
//
// Build with `-DPLL_TEST` to replace ext_clk with a 25→400 MHz PLL output
// (sanity-check that the counter matches a known reference). RC osc still
// runs but its output is ignored.

module top_extclk #(
    parameter integer CLK_DIV = 7   // SSD1306 I2C SCL divisor (25 MHz / 7 ≈ 3.57 MHz)
)(
    input  wire clk,            // 25 MHz reference oscillator (P6)
    input  wire ext_clk,        // RC oscillator input (E16)
    output wire osc_drive,      // FPGA inverter output → pot (F15)
    output reg  led,            // T6 — heartbeat (slow blink)
    input  wire btn,            // R7 — global reset (active-low)
    output wire ntsc_sync,      // C4 — held low (CRT not used)
    output wire ntsc_vid,       // D4
    output wire oled_scl,       // P2
    output wire oled_sda,       // R2
    inout  wire p27, p28, p44, p49, p50, p51, p56, p57, p62, p63  // dozenal keypad
);

    // =========================================================================
    // POR + button-driven global reset
    // =========================================================================
    reg [11:0] por_cnt = 0;
    reg por_done = 0;
    always @(posedge clk) begin
        if (!por_done) begin
            por_cnt <= por_cnt + 1;
            if (&por_cnt) por_done <= 1;
        end
    end

    reg [1:0] btn_sync = 2'b11;
    always @(posedge clk) btn_sync <= {btn_sync[0], btn};
    wire btn_held = ~btn_sync[1];
    wire global_reset = btn_held | ~por_done;

    // =========================================================================
    // RC oscillator: osc_drive = ~ext_clk_pin (combinational inverter).
    // External pot between the two pins forms the feedback delay.
    // =========================================================================
    assign osc_drive = ~ext_clk;
    assign ntsc_sync = 1'b0;
    assign ntsc_vid  = 1'b0;

`ifdef RING_TEST
`ifndef RING_STAGES
  `define RING_STAGES 32
`endif
    // PIPE divergence from spirix: single-inverter ring oscillator.
    // Stage 0 is a NOT (LUT4 INIT=h5555 → Z=~A); stages 1..N-1 are BUFs
    // (LUT4 INIT=hAAAA → Z=A). Exactly one inversion per loop, so the ring
    // oscillates regardless of total stage count. RING_STAGES can be any
    // integer ≥ 1, no parity restriction.
    //
    // (* keep *) on each LUT4 prevents yosys from optimizing the BUFs away
    // (their function reduces to a wire) or collapsing the loop to a constant.
    // (* noglobal *) on count_clk prevents nextpnr from promoting it to a
    // DCCA global clock buffer (which would inject 3-5 ns into the loop).
    (* noglobal *) wire [`RING_STAGES-1:0] ring_q;

    (* keep *) LUT4 #(.INIT(16'h5555)) ring_inv (
        .A(ring_q[`RING_STAGES-1]),
        .B(1'b0), .C(1'b0), .D(1'b0),
        .Z(ring_q[0])
    );

    genvar ri;
    generate
        for (ri = 1; ri < `RING_STAGES; ri = ri + 1) begin : ring_buf_stage
            (* keep *) LUT4 #(.INIT(16'hAAAA)) ring_buf (
                .A(ring_q[ri - 1]),
                .B(1'b0), .C(1'b0), .D(1'b0),
                .Z(ring_q[ri])
            );
        end
    endgenerate

    (* noglobal *) wire count_clk = ring_q[0];
`elsif PLL_TEST
`ifndef PLL_FBDIV
  `define PLL_FBDIV 32
`endif
    // 25 MHz × PLL_FBDIV = VCO = CLKOP (CLKOP_DIV=1, CPHASE=0).
    // Datasheet VCO spec: 400-800 MHz (FBDIV 16-32). Beyond is silicon-lottery.
    wire pll_clk;
    wire pll_locked;
    (* FREQUENCY_PIN_CLKI="25" *)
    (* FREQUENCY_PIN_CLKOP="800" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(1),
        .CLKOP_CPHASE(0),
        .CLKOP_FPHASE(0),
        .FEEDBK_PATH("CLKOP"),
        .CLKFB_DIV(`PLL_FBDIV)
    ) pll_i (
        .RST(1'b0),
        .STDBY(1'b0),
        .CLKI(clk),
        .CLKOP(pll_clk),
        .CLKFB(pll_clk),
        .CLKINTFB(),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b1),
        .PHASESTEP(1'b1),
        .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .LOCK(pll_locked)
    );
    wire count_clk = pll_clk;
`elsif DDS_TEST
`ifndef DDS_PLL_FBDIV
  `define DDS_PLL_FBDIV 40
`endif
`ifndef DDS_K
  `define DDS_K 32'h4000_0000
`endif
    // 25 MHz × DDS_PLL_FBDIV = high-freq PLL (default 1000 MHz, FBDIV=40)
    // 32-bit DDS phase accumulator clocked at PLL rate.
    // Output (count_clk) = MSB of accumulator, average freq = K × PLL / 2^32.
    // Jitter ±1 PLL cycle on individual edges, but average freq is exact.
    wire dds_pll_clk;
    wire dds_pll_locked;
    (* FREQUENCY_PIN_CLKI="25" *)
    (* FREQUENCY_PIN_CLKOP="1000" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(1),
        .CLKOP_CPHASE(0),
        .CLKOP_FPHASE(0),
        .FEEDBK_PATH("CLKOP"),
        .CLKFB_DIV(`DDS_PLL_FBDIV)
    ) dds_pll_i (
        .RST(1'b0),
        .STDBY(1'b0),
        .CLKI(clk),
        .CLKOP(dds_pll_clk),
        .CLKFB(dds_pll_clk),
        .CLKINTFB(),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b1),
        .PHASESTEP(1'b1),
        .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .LOCK(dds_pll_locked)
    );

    // Runtime-adjustable K register (clk domain). Step = 2^32 / 1000 ≈ 1 MHz.
    localparam [31:0] K_STEP_1MHZ = 32'd4294967;
    reg [31:0] dds_k_reg = `DDS_K;
    always @(posedge clk) begin
        if (ter_press)    dds_k_reg <= dds_k_reg + K_STEP_1MHZ;
        if (teror_press)  dds_k_reg <= dds_k_reg - K_STEP_1MHZ;
    end

    // Sync K into dds_pll_clk domain (single FF — partial-update glitches are
    // harmless for DDS, just adds 1 cycle of phase noise at update time).
    reg [31:0] dds_k_pll;
    always @(posedge dds_pll_clk) dds_k_pll <= dds_k_reg;

    reg [31:0] dds_phase = 0;
    always @(posedge dds_pll_clk) dds_phase <= dds_phase + dds_k_pll;

    wire count_clk = dds_phase[31];
`else
    wire count_clk = ext_clk;
`endif

    // =========================================================================
    // DUT_BLAKE3 — single-phase BLAKE3 silicon Fmax bench (PIPE Phase C)
    //
    // Hashes continuously on bench_clk (= pll_clk if PLL_TEST, else 25 MHz clk).
    // LFSR-derived inputs feed i_mblock; o_hash XOR-folded to 32b; rotate-XOR
    // accumulator integrates over ACCUM_LEN samples then latches result_reg
    // and starts over. result_reg is deterministic at any frequency where
    // timing closes; it changes when timing fails.
    //
    // Methodology: build at low frequency (e.g., raw 25 MHz, no PLL) → record
    // displayed result_reg as ground truth. Build at higher frequencies → if
    // displayed value matches ground truth, timing closes; if it changes,
    // timing fails. Binary-search for the boundary.
    //
    // result_reg displayed via the existing 60 Hz windowed FSM by overriding
    // count_snap source (see line further below). The displayed number is NOT
    // milli-MHz in this mode; it's a stable signature of the computation.
    // =========================================================================
`ifdef DUT_BLAKE3
    `ifdef PLL_TEST
        wire bench_clk  = pll_clk;
        wire bench_lock = pll_locked;
    `else
        wire bench_clk  = clk;
        wire bench_lock = 1'b1;
    `endif

    // Bench reset: hold low until POR done AND PLL locked AND 16 bench cycles passed.
    reg [3:0] b3_por_cnt = 0;
    reg       b3_reset_n = 0;
    always @(posedge bench_clk) begin
        if (!bench_lock || global_reset) begin
            b3_por_cnt <= 0;
            b3_reset_n <= 0;
        end else if (!(&b3_por_cnt)) begin
            b3_por_cnt <= b3_por_cnt + 1;
        end else begin
            b3_reset_n <= 1;
        end
    end

    // 64-bit Galois LFSR (matches spirix harness pattern)
    localparam [63:0] B3_LFSR_SEED = 64'hCAFE_BABE_DEAD_BEEF;
    localparam [63:0] B3_LFSR_TAPS = 64'hD800_0000_0000_0000;  // bits 63,62,60,59
    reg  [63:0] b3_lfsr;
    wire        b3_lfsr_fb   = b3_lfsr[0];
    wire [63:0] b3_lfsr_next = {1'b0, b3_lfsr[63:1]} ^ (b3_lfsr_fb ? B3_LFSR_TAPS : 64'b0);
    always @(posedge bench_clk) begin
        if (!b3_reset_n) b3_lfsr <= B3_LFSR_SEED;
        else             b3_lfsr <= b3_lfsr_next;
    end

    // BLAKE3 inputs:
    //   chain  = BLAKE3 IV (256b, word 0 in [31:0])
    //   mblock = 8 derivations of the 64b LFSR tiled into 512b
    //   counter = 0, numbytes = 64, dflags = ROOT|CHUNK_END|CHUNK_START
    //   i_valid held high → blake3 retriggers from S_IDLE every 30 cycles
    wire [255:0] b3_chain = {
        32'h5BE0CD19, 32'h1F83D9AB, 32'h9B05688C, 32'h510E527F,
        32'hA54FF53A, 32'h3C6EF372, 32'hBB67AE85, 32'h6A09E667
    };
    wire [511:0] b3_mblock = {
        ~b3_lfsr,
        b3_lfsr ^ 64'hAAAA_AAAA_AAAA_AAAA,
        b3_lfsr + 64'h1234_5678_9ABC_DEF0,
        b3_lfsr - 64'hFEDC_BA98_7654_3210,
        {b3_lfsr[31:0], b3_lfsr[63:32]},
        {b3_lfsr[15:0], b3_lfsr[63:16]},
        b3_lfsr ^ 64'h5555_5555_5555_5555,
        b3_lfsr
    };

    wire [511:0] b3_hash;
    wire         b3_valid;
    blake3 b3 (
        .i_clk     (bench_clk),
        .i_reset   (b3_reset_n),
        .i_ce      (1'b1),
        .i_chain   (b3_chain),
        .i_mblock  (b3_mblock),
        .i_counter (64'd0),
        .i_numbytes(32'd64),
        .i_dflags  (32'h0000_000B),  // CHUNK_START | CHUNK_END | ROOT
        .i_valid   (1'b1),
        .o_hash    (b3_hash),
        .o_valid   (b3_valid)
    );

    // XOR-fold 512 → 32. Accumulate only on o_valid (one fresh sample per ~30 cycles).
    function [31:0] b3_fold;
        input [511:0] h;
        integer i;
        reg [31:0] f;
        begin
            f = 32'b0;
            for (i = 0; i < 16; i = i + 1) f = f ^ h[i*32 +: 32];
            b3_fold = f;
        end
    endfunction
    wire [31:0] b3_hash_fold = b3_fold(b3_hash);

    // 17-bit cycle counter → ACCUM_LEN = 131072 cycles per result loop.
    // At 50 MHz that's 2.6 ms per result_reg update — comfortably faster than 60 Hz refresh.
    reg [16:0] b3_cyc        = 0;
    reg [31:0] b3_accum      = 0;
    reg [31:0] b3_result_reg = 0;
    always @(posedge bench_clk) begin
        if (!b3_reset_n) begin
            b3_cyc        <= 0;
            b3_accum      <= 0;
            b3_result_reg <= 0;
        end else begin
            if (b3_valid)
                b3_accum <= {b3_accum[30:0], b3_accum[31]} ^ b3_hash_fold;
            b3_cyc <= b3_cyc + 1;
            if (&b3_cyc) begin
                b3_result_reg <= b3_accum;
                b3_accum      <= 0;
            end
        end
    end

    // CDC: 2-flop sync into 25 MHz clk domain (b3_result_reg only changes
    // every ACCUM_LEN cycles, so the sync window is huge — no metastability risk).
    reg [31:0] b3_result_sync1 = 0;
    reg [31:0] b3_result_sync2 = 0;
    always @(posedge clk) begin
        b3_result_sync1 <= b3_result_reg;
        b3_result_sync2 <= b3_result_sync1;
    end
    wire [31:0] b3_result_clk = b3_result_sync2;
`endif

    // =========================================================================
    // Keypad — pure combinational decoder for ter (p44+p62) and teror (p44+p49).
    // Drive p44 LOW continuously; tristate every other matrix pin. Only buttons
    // connecting to p44 can pull a column LOW, so column reads directly identify
    // ter/teror with no scan, no FSM, no settle wait, no clock counters.
    // =========================================================================
    wire [9:0] kp_in;
    // pin_t[i] = 1 → tristate. p44 (idx 2) is the only driven row; everything else high-Z.
    localparam [9:0] KP_T = 10'b11_11111011;  // bit 2 (p44) = 0, all others = 1
    localparam [9:0] KP_DRV = 10'd0;          // when not tristate, drive LOW

    BB bb_p27 (.B(p27), .I(KP_DRV[0]), .T(KP_T[0]), .O(kp_in[0]));
    BB bb_p28 (.B(p28), .I(KP_DRV[1]), .T(KP_T[1]), .O(kp_in[1]));
    BB bb_p44 (.B(p44), .I(KP_DRV[2]), .T(KP_T[2]), .O(kp_in[2]));
    BB bb_p49 (.B(p49), .I(KP_DRV[3]), .T(KP_T[3]), .O(kp_in[3]));
    BB bb_p50 (.B(p50), .I(KP_DRV[4]), .T(KP_T[4]), .O(kp_in[4]));
    BB bb_p51 (.B(p51), .I(KP_DRV[5]), .T(KP_T[5]), .O(kp_in[5]));
    BB bb_p56 (.B(p56), .I(KP_DRV[6]), .T(KP_T[6]), .O(kp_in[6]));
    BB bb_p57 (.B(p57), .I(KP_DRV[7]), .T(KP_T[7]), .O(kp_in[7]));
    BB bb_p62 (.B(p62), .I(KP_DRV[8]), .T(KP_T[8]), .O(kp_in[8]));
    BB bb_p63 (.B(p63), .I(KP_DRV[9]), .T(KP_T[9]), .O(kp_in[9]));

    // Active-low column reads. Pullup HIGH when no button connects p44 to that col.
    wire is_ter   = !kp_in[8];   // p62 LOW → ter pressed
    wire is_teror = !kp_in[3];   // p49 LOW → teror pressed

    // Single-FF rising-edge detect per signal (one decode = one event).
    reg ter_prev = 0, teror_prev = 0;
    reg ter_press = 0, teror_press = 0;
    always @(posedge clk) begin
        ter_press   <= is_ter   && !ter_prev;
        teror_press <= is_teror && !teror_prev;
        ter_prev    <= is_ter;
        teror_prev  <= is_teror;
    end

    // =========================================================================
    // Counter — 32-stage async ripple, gated by `counter_enable`,
    // async-resettable via `counter_reset`. Both signals are driven from the
    // 25 MHz reference domain and synchronized into count_clk before use.
    //
    // The buffer LUT on count_clk_buf isolates the counter chain's load from
    // the bare ext_clk pin, so any backwards-driven activity in the counter
    // logic doesn't perturb the RC oscillator loop.
    // =========================================================================
    reg counter_enable = 1;
    reg counter_reset  = 0;

    reg [1:0] ena_sync;
    reg [1:0] rst_sync;
    always @(posedge count_clk) begin
        ena_sync <= {ena_sync[0], counter_enable};
        rst_sync <= {rst_sync[0], counter_reset};
    end
    wire ena_ext = ena_sync[1];
    wire rst_ext = rst_sync[1];

    reg [31:0] count;
    always @(posedge count_clk or posedge rst_ext) begin
        if (rst_ext)        count[0] <= 1'b0;
        else if (ena_ext)   count[0] <= ~count[0];
    end
    genvar gi;
    generate
        for (gi = 1; gi < 32; gi = gi + 1) begin : ripple
            always @(negedge count[gi-1] or posedge rst_ext) begin
                if (rst_ext) count[gi] <= 1'b0;
                else         count[gi] <= ~count[gi];
            end
        end
    endgenerate

    // =========================================================================
    // 60 Hz windowed FSM
    //   state 0  SAMPLE       — counter accumulating, window_cnt → SNAP_INTERVAL
    //   state 1  DISCONNECT   — gate off, wait `settle` cycles for ripple to clear
    //   state 2  READ         — snapshot count → count_snap, fire snap_pulse
    //   state 3  RESET        — assert counter_reset, wait `settle` cycles
    //   state 4  RECONNECT    — drop reset, re-enable, restart window → state 0
    // =========================================================================
    localparam integer SNAP_INTERVAL = 25_000_000 / 60;  // = 416,666

    reg [19:0] window_cnt = 0;
    reg [3:0]  state      = 0;
    reg [3:0]  settle     = 0;
    reg [31:0] count_snap = 0;
    reg        snap_pulse = 0;

    always @(posedge clk) begin
        snap_pulse <= 1'b0;
        if (global_reset) begin
            state          <= 0;
            window_cnt     <= 0;
            settle         <= 0;
            counter_enable <= 1;
            counter_reset  <= 0;
        end else begin
            case (state)
                4'd0: begin // SAMPLE
                    window_cnt <= window_cnt + 1;
                    if (window_cnt == SNAP_INTERVAL - 1) begin
                        counter_enable <= 1'b0;
                        settle         <= 0;
                        state          <= 4'd1;
                    end
                end
                4'd1: begin // DISCONNECT (settle ripple)
                    settle <= settle + 1;
                    if (settle == 4'd4) state <= 4'd2;
                end
                4'd2: begin // READ
`ifdef DUT_BLAKE3
                    count_snap <= b3_result_clk;
`else
                    count_snap <= count;
`endif
                    snap_pulse <= 1'b1;
                    settle     <= 0;
                    state      <= 4'd3;
                end
                4'd3: begin // RESET counter
                    counter_reset <= 1'b1;
                    settle        <= settle + 1;
                    if (settle == 4'd4) state <= 4'd4;
                end
                4'd4: begin // RECONNECT
                    counter_reset  <= 1'b0;
                    counter_enable <= 1'b1;
                    window_cnt     <= 0;
                    state          <= 4'd0;
                end
            endcase
        end
    end

    // =========================================================================
    // Frequency math: count_snap × K >> 32 = milli-MHz integer.
    //   K = ceil(25,000 × 2^32 / 416,666) = 257,698,453
    //   For count_snap = 416,666 (= 25 MHz × 1/60 sec) → 25,000 milli-MHz
    // =========================================================================
    localparam [27:0] MULT_K = 28'd257_698_453;
    wire [59:0] product   = count_snap * MULT_K;
    wire [22:0] milli_mhz = product[54:32];

    // =========================================================================
    // Double-dabble: 23-bit milli_mhz → 7 BCD digits (28 bits)
    // 23 cycles to complete; kicks off one cycle after snap_pulse.
    // =========================================================================
    reg snap_pulse_d = 0;
    always @(posedge clk) snap_pulse_d <= snap_pulse;

    reg [50:0] dd_reg;
    reg [4:0]  dd_step;
    reg        dd_busy;
    reg [27:0] bcd_value = 0;

    wire [50:0] dd_adjusted;
    assign dd_adjusted[22: 0] = dd_reg[22: 0];
    assign dd_adjusted[26:23] = (dd_reg[26:23] >= 4'd5) ? dd_reg[26:23] + 4'd3 : dd_reg[26:23];
    assign dd_adjusted[30:27] = (dd_reg[30:27] >= 4'd5) ? dd_reg[30:27] + 4'd3 : dd_reg[30:27];
    assign dd_adjusted[34:31] = (dd_reg[34:31] >= 4'd5) ? dd_reg[34:31] + 4'd3 : dd_reg[34:31];
    assign dd_adjusted[38:35] = (dd_reg[38:35] >= 4'd5) ? dd_reg[38:35] + 4'd3 : dd_reg[38:35];
    assign dd_adjusted[42:39] = (dd_reg[42:39] >= 4'd5) ? dd_reg[42:39] + 4'd3 : dd_reg[42:39];
    assign dd_adjusted[46:43] = (dd_reg[46:43] >= 4'd5) ? dd_reg[46:43] + 4'd3 : dd_reg[46:43];
    assign dd_adjusted[50:47] = (dd_reg[50:47] >= 4'd5) ? dd_reg[50:47] + 4'd3 : dd_reg[50:47];
    wire [50:0] dd_next = {dd_adjusted[49:0], 1'b0};

    always @(posedge clk) begin
        if (global_reset) begin
            dd_busy   <= 0;
            bcd_value <= 0;
        end else if (snap_pulse_d) begin
            dd_reg  <= {28'd0, milli_mhz};
            dd_step <= 0;
            dd_busy <= 1;
        end else if (dd_busy) begin
            dd_reg  <= dd_next;
            dd_step <= dd_step + 1;
            if (dd_step == 5'd22) begin
                dd_busy   <= 0;
                bcd_value <= dd_next[50:23];
            end
        end
    end

    // =========================================================================
    // Frame-coherent display registers — latched on snap_pulse
    //   display_bcd   — 7 BCD digits to render at the top
    //   display_count — raw 32-bit count_snap to render as the binary ruler
    // =========================================================================
    reg [27:0] display_bcd   = 0;
    reg [31:0] display_count = 0;
    always @(posedge clk) if (snap_pulse) begin
        display_bcd   <= bcd_value;
        display_count <= count_snap;
    end

    // =========================================================================
    // Glyph ROM — 11 glyphs × 12 wide × 16 tall × 8bpp = 2112 bytes.
    // No padding: each tile is exactly the inked content. addr = slot*192 + gy*12 + gx.
    // =========================================================================
    reg [7:0] glyph_rom [0:2111];
    initial $readmemh("decimal_glyphs.mem", glyph_rom);

    // =========================================================================
    // LFSR dither (32-bit Galois, period 2^32-1) — clk domain, OLED greyscale
    // =========================================================================
    reg [31:0] lfsr = 32'hCAFE_BABE;
    always @(posedge clk) begin
        lfsr <= {lfsr[0], lfsr[31:1]} ^ ({32{lfsr[0]}} & 32'h80200003);
    end
    wire [7:0] dither = lfsr[7:0];

`ifdef BENCH
    // =========================================================================
    // Bench harness — count_clk (= PLL) domain
    // Phase: IDLE → GOLD (CE=1/256) → SWITCH (LFSR replay) → TEST (CE=1) → DONE
    // 18-bit protocol counter: warmup [0..32767], accumulate [32768..131071]
    // 32-bit accumulator captures gold then test; mismatch = gold ^ test
    // =========================================================================
    localparam [2:0] PH_IDLE   = 3'd0,
                     PH_GOLD   = 3'd1,
                     PH_SWITCH = 3'd2,
                     PH_TEST   = 3'd3,
                     PH_DONE   = 3'd4;
    reg [2:0] bench_phase = PH_IDLE;

    // 64-bit Galois LFSR, taps x^64+x^63+x^61+x^60
    localparam [63:0] LFSR_SEED = 64'hCAFE_BABE_DEAD_BEEF;
    localparam [63:0] LFSR_TAPS = 64'hD800000000000000;
    reg  [63:0] dut_lfsr;
    wire        dut_lfsr_fb = dut_lfsr[0];
    wire [63:0] dut_lfsr_next = {1'b0, dut_lfsr[63:1]} ^ (dut_lfsr_fb ? LFSR_TAPS : 64'b0);
    reg  [63:0] captured_seed;

    // Free-running entropy counter in clk domain, sampled into count_clk at IDLE
    reg [63:0] entropy = 0;
    always @(posedge clk) entropy <= entropy + 1;
    reg [63:0] entropy_sync;
    always @(posedge count_clk) entropy_sync <= entropy;

    // Sync global_reset into count_clk domain
    reg [1:0] bench_rst_sync;
    always @(posedge count_clk) bench_rst_sync <= {bench_rst_sync[0], global_reset};
    wire bench_reset = bench_rst_sync[1];

    // CE generator — gold = 1 every 256 count_clk, test = every count_clk
    reg [7:0] ce_div_dut = 0;
    reg       ce_dut = 0;
    always @(posedge count_clk) begin
        ce_div_dut <= (ce_div_dut == 8'd255) ? 8'd0 : ce_div_dut + 1;
        ce_dut     <= (bench_phase == PH_TEST) || (ce_div_dut == 8'd255);
    end

    // 18-bit split protocol counter (registered carry between halves)
    reg [8:0] proto_lo;
    reg [8:0] proto_hi;
    reg       proto_carry;
    wire      proto_done    = proto_hi[8];
    wire      accumulating  = proto_hi[6] & ~proto_done;

    // DUT — 32-bit registered passthrough
    wire [31:0] dut_in   = dut_lfsr[31:0];
    reg  [31:0] dut_out_r;
    always @(posedge count_clk) if (ce_dut) dut_out_r <= dut_in;
    wire [31:0] dut_out  = dut_out_r;

    reg [31:0] accum;
    reg [31:0] gold_reg = 0;
    reg [31:0] test_reg = 0;

    always @(posedge count_clk) begin
        if (bench_reset) begin
            bench_phase   <= PH_IDLE;
            dut_lfsr      <= LFSR_SEED;
            captured_seed <= LFSR_SEED;
            proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
            accum    <= 0;
            gold_reg <= 0;
            test_reg <= 0;
        end else begin
            case (bench_phase)
                PH_IDLE: begin
                    captured_seed <= dut_lfsr ^ entropy_sync;
                    dut_lfsr      <= dut_lfsr ^ entropy_sync;
                    proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
                    accum    <= 0;
                    bench_phase <= PH_GOLD;
                end
                PH_GOLD: begin
                    if (proto_done) begin
                        gold_reg    <= accum;
                        bench_phase <= PH_SWITCH;
                    end
                end
                PH_SWITCH: begin
                    dut_lfsr <= captured_seed;
                    proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
                    accum    <= 0;
                    bench_phase <= PH_TEST;
                end
                PH_TEST: begin
                    if (proto_done) begin
                        test_reg    <= accum;
                        bench_phase <= PH_DONE;
                    end
                end
                PH_DONE: ;  // hold values
            endcase

            // CE-gated datapath — only during GOLD/TEST
            if (ce_dut && (bench_phase == PH_GOLD || bench_phase == PH_TEST)) begin
                dut_lfsr <= dut_lfsr_next;

                if (!proto_done) begin
                    proto_lo    <= proto_lo + 1;
                    proto_carry <= &proto_lo;
                    proto_hi    <= proto_hi + {8'b0, proto_carry};
                end

                if (accumulating)
                    accum <= {accum[30:0], accum[31]} ^ dut_out;
            end
        end
    end

    // CDC: gold_reg, test_reg → clk domain (change rarely, 2-FF sync is safe)
    reg [31:0] gold_sync1, gold_sync2;
    reg [31:0] test_sync1, test_sync2;
    always @(posedge clk) begin
        gold_sync1 <= gold_reg; gold_sync2 <= gold_sync1;
        test_sync1 <= test_reg; test_sync2 <= test_sync1;
    end
    wire [31:0] display_gold = gold_sync2;
    wire [31:0] display_test = test_sync2;
    wire [31:0] display_miss = display_gold ^ display_test;
`endif

    // =========================================================================
    // 8bpp framebuffer (128 × 64), continuous write at 25 MHz
    // =========================================================================
    reg [7:0]  fb [0:8191];
    reg [12:0] fb_wr_addr = 0;
    wire [6:0] wr_col = fb_wr_addr[6:0];
    wire [5:0] wr_row = fb_wr_addr[12:7];

    // Bands
    wire in_freq_band   = (wr_row < 6'd16);                                // rows 0..15
`ifdef BENCH
    wire in_gold_band   = (wr_row >= 6'd16) && (wr_row < 6'd32);           // rows 16..31
    wire in_test_band   = (wr_row >= 6'd32) && (wr_row < 6'd48);           // rows 32..47
    wire in_miss_band   = (wr_row >= 6'd48);                                // rows 48..63
`else
    wire in_binary_band = (wr_row >= 6'd16) && (wr_row < 6'd32);           // rows 16..31
`endif

`ifdef FONT_TEST
    // ----- Font test: 10 cells × 12 wide showing digits 0-9 at top -----
    localparam integer DIGIT_AREA_START = 4;
    localparam integer DIGIT_AREA_END   = 4 + 10 * 12;  // 124
    wire in_digit_area = (wr_col >= DIGIT_AREA_START[6:0]) && (wr_col < DIGIT_AREA_END[6:0]);
    wire [6:0] rel_col = wr_col - DIGIT_AREA_START[6:0];

    reg [3:0] freq_slot;
    reg [3:0] gx_in_cell;
    always @(*) begin
        if      (rel_col < 7'd12)  begin freq_slot = 4'd0; gx_in_cell = rel_col[3:0]; end
        else if (rel_col < 7'd24)  begin freq_slot = 4'd1; gx_in_cell = (rel_col - 7'd12); end
        else if (rel_col < 7'd36)  begin freq_slot = 4'd2; gx_in_cell = (rel_col - 7'd24); end
        else if (rel_col < 7'd48)  begin freq_slot = 4'd3; gx_in_cell = (rel_col - 7'd36); end
        else if (rel_col < 7'd60)  begin freq_slot = 4'd4; gx_in_cell = (rel_col - 7'd48); end
        else if (rel_col < 7'd72)  begin freq_slot = 4'd5; gx_in_cell = (rel_col - 7'd60); end
        else if (rel_col < 7'd84)  begin freq_slot = 4'd6; gx_in_cell = (rel_col - 7'd72); end
        else if (rel_col < 7'd96)  begin freq_slot = 4'd7; gx_in_cell = (rel_col - 7'd84); end
        else if (rel_col < 7'd108) begin freq_slot = 4'd8; gx_in_cell = (rel_col - 7'd96); end
        else                       begin freq_slot = 4'd9; gx_in_cell = (rel_col - 7'd108); end
    end
    wire [3:0] gy = wr_row[3:0];
    wire freq_slot_valid = 1'b1;
`else
    // ----- Frequency display: 8 cells × 12 wide centered at col 16 -----
    localparam integer DIGIT_AREA_START = 16;
    localparam integer DIGIT_AREA_END   = 16 + 8 * 12;  // 112
    wire in_digit_area = (wr_col >= DIGIT_AREA_START[6:0]) && (wr_col < DIGIT_AREA_END[6:0]);
    wire [6:0] rel_col = wr_col - DIGIT_AREA_START[6:0];

    reg [2:0] freq_pos;
    reg [3:0] gx_in_cell;
    always @(*) begin
        if      (rel_col < 7'd12) begin freq_pos = 3'd0; gx_in_cell = rel_col[3:0]; end
        else if (rel_col < 7'd24) begin freq_pos = 3'd1; gx_in_cell = (rel_col - 7'd12); end
        else if (rel_col < 7'd36) begin freq_pos = 3'd2; gx_in_cell = (rel_col - 7'd24); end
        else if (rel_col < 7'd48) begin freq_pos = 3'd3; gx_in_cell = (rel_col - 7'd36); end
        else if (rel_col < 7'd60) begin freq_pos = 3'd4; gx_in_cell = (rel_col - 7'd48); end
        else if (rel_col < 7'd72) begin freq_pos = 3'd5; gx_in_cell = (rel_col - 7'd60); end
        else if (rel_col < 7'd84) begin freq_pos = 3'd6; gx_in_cell = (rel_col - 7'd72); end
        else                      begin freq_pos = 3'd7; gx_in_cell = (rel_col - 7'd84); end
    end
    wire [3:0] gy = wr_row[3:0];

    // Leading-zero suppression (positions 0/1/2)
    wire suppress_p0 = (display_bcd[27:24] == 4'd0);
    wire suppress_p1 = suppress_p0 && (display_bcd[23:20] == 4'd0);
    wire suppress_p2 = suppress_p1 && (display_bcd[19:16] == 4'd0);

    reg [3:0] freq_slot;
    reg       freq_slot_valid;
    always @(*) begin
        case (freq_pos)
            3'd0: begin freq_slot = display_bcd[27:24]; freq_slot_valid = !suppress_p0; end
            3'd1: begin freq_slot = display_bcd[23:20]; freq_slot_valid = !suppress_p1; end
            3'd2: begin freq_slot = display_bcd[19:16]; freq_slot_valid = !suppress_p2; end
            3'd3: begin freq_slot = display_bcd[15:12]; freq_slot_valid = 1'b1; end
            3'd4: begin freq_slot = 4'd10;              freq_slot_valid = 1'b1; end // '.'
            3'd5: begin freq_slot = display_bcd[11: 8]; freq_slot_valid = 1'b1; end
            3'd6: begin freq_slot = display_bcd[ 7: 4]; freq_slot_valid = 1'b1; end
            3'd7: begin freq_slot = display_bcd[ 3: 0]; freq_slot_valid = 1'b1; end
        endcase
    end
`endif

    // 12-wide tiles. addr = slot*192 + gy*12 + gx_in_cell (gx_in_cell is 0..11).
    // gy*12 = gy*8 + gy*4 (no multiplier needed).
    reg [11:0] slot_offset;
    always @(*) begin
        case (freq_slot)
            4'd0:  slot_offset = 12'd0;
            4'd1:  slot_offset = 12'd192;
            4'd2:  slot_offset = 12'd384;
            4'd3:  slot_offset = 12'd576;
            4'd4:  slot_offset = 12'd768;
            4'd5:  slot_offset = 12'd960;
            4'd6:  slot_offset = 12'd1152;
            4'd7:  slot_offset = 12'd1344;
            4'd8:  slot_offset = 12'd1536;
            4'd9:  slot_offset = 12'd1728;
            4'd10: slot_offset = 12'd1920;
            default: slot_offset = 12'd0;
        endcase
    end
    wire [7:0]  gy_x12     = ({4'd0, gy} << 3) + ({4'd0, gy} << 2);
    wire [11:0] glyph_addr = slot_offset + {4'd0, gy_x12} + {8'd0, gx_in_cell};
    wire [7:0]  glyph_pixel = glyph_rom[glyph_addr];
    wire [7:0]  freq_pixel  = (in_freq_band && in_digit_area && freq_slot_valid)
                              ? glyph_pixel : 8'h00;

    // ----- Bit display (32 cells × 4 px wide) -----
    // Alternating bright/dark pairs per bit position so adjacent bits are
    // always visually distinct AND the bit value is readable at a glance:
    //   even bit index: 0 → 0   (black),     1 → 191 (light grey)
    //   odd  bit index: 0 → 32  (dark grey), 1 → 255 (white)
    wire [4:0] bit_idx       = wr_col[6:2];                  // 0..31
    wire       bit_pos_odd   = bit_idx[0];

`ifdef BENCH
    wire [31:0] band_value = in_gold_band ? display_gold :
                             in_test_band ? display_test :
                                            display_miss;
    wire        bit_value   = band_value[5'd31 - bit_idx];   // MSB on left
    wire [7:0]  bit_pixel   = bit_pos_odd ? (bit_value ? 8'd255 : 8'd32)
                                          : (bit_value ? 8'd191 : 8'd0);

    wire [7:0] fb_wr_pixel =
        in_freq_band                                ? freq_pixel :
        (in_gold_band || in_test_band || in_miss_band) ? bit_pixel :
                                                      8'h00;
`else
    wire       bin_bit_value = display_count[5'd31 - bit_idx];
    wire [7:0] binary_pixel  = bit_pos_odd ? (bin_bit_value ? 8'd255 : 8'd32)
                                            : (bin_bit_value ? 8'd191 : 8'd0);

    wire [7:0] fb_wr_pixel =
        in_freq_band   ? freq_pixel   :
        in_binary_band ? binary_pixel :
                         8'h00;
`endif

    always @(posedge clk) begin
        fb[fb_wr_addr] <= fb_wr_pixel;
        fb_wr_addr     <= fb_wr_addr + 1;
    end

    // =========================================================================
    // OLED I2C clock-enable (one ce pulse per CLK_DIV ref cycles)
    // =========================================================================
    reg [$clog2(CLK_DIV)-1:0] cnt = 0;
    wire at_top = (cnt == CLK_DIV - 1);
    always @(posedge clk) cnt <= at_top ? 0 : cnt + 1;
    reg ce = 0;
    always @(posedge clk) ce <= at_top;

    // =========================================================================
    // I2C driver
    // =========================================================================
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

    // =========================================================================
    // SSD1306/SH1106 init
    // =========================================================================
    localparam I2C_ADDR    = 8'h78;
    localparam CMD_PREFIX  = 8'h00;
    localparam DATA_PREFIX = 8'h40;
    localparam INIT_LEN    = 25;

    reg [7:0] init_cmds [0:INIT_LEN-1];
    initial begin
        init_cmds[ 0] = 8'hAE; init_cmds[ 1] = 8'hD5;
        init_cmds[ 2] = 8'h80; init_cmds[ 3] = 8'hA8;
        init_cmds[ 4] = 8'h3F; init_cmds[ 5] = 8'hD3;
        init_cmds[ 6] = 8'h00; init_cmds[ 7] = 8'h40;
        init_cmds[ 8] = 8'h8D; init_cmds[ 9] = 8'h14;
        init_cmds[10] = 8'hAD; init_cmds[11] = 8'h8B;
        init_cmds[12] = 8'hA1; init_cmds[13] = 8'hC8;
        init_cmds[14] = 8'hDA; init_cmds[15] = 8'h12;
        init_cmds[16] = 8'h81; init_cmds[17] = 8'hCF;
        init_cmds[18] = 8'hD9; init_cmds[19] = 8'hF1;
        init_cmds[20] = 8'hDB; init_cmds[21] = 8'h40;
        init_cmds[22] = 8'hA4; init_cmds[23] = 8'hA6;
        init_cmds[24] = 8'hAF;
    end

    // =========================================================================
    // OLED FSM — gather + dither
    // =========================================================================
    localparam [2:0]
        ST_RESET   = 3'd0,
        ST_SEND    = 3'd1,
        ST_WAIT    = 3'd2,
        ST_NEXT    = 3'd3,
        ST_BUSFREE = 3'd4,
        ST_GATHER  = 3'd5;

    localparam [1:0]
        PH_INIT      = 2'd0,
        PH_PAGE_CMD  = 2'd1,
        PH_PAGE_DATA = 2'd2;

    reg [2:0]  oled_state   = ST_RESET;
    reg [1:0]  phase        = PH_INIT;
    reg [19:0] reset_cnt    = 0;
    reg [9:0]  busfree_cnt  = 0;
    reg [4:0]  cmd_idx      = 0;
    reg [2:0]  page         = 0;
    reg [6:0]  col          = 0;
    reg [7:0]  px_byte      = 0;
    reg [3:0]  gather_cnt   = 0;
    reg [7:0]  fb_dout      = 0;

    always @(posedge clk) if (ce) begin
        fb_dout   <= fb[{page, gather_cnt[2:0], col}];
        i2c_start <= 0;

        case (oled_state)
            ST_RESET: begin
                reset_cnt <= reset_cnt + 1;
                if (&reset_cnt) begin
                    phase   <= PH_INIT;
                    cmd_idx <= 0;
                    page    <= 0;
                    col     <= 0;
                    oled_state <= ST_SEND;
                end
            end
            ST_SEND: begin
                if (!i2c_busy) begin
                    case (phase)
                        PH_INIT: begin
                            if (cmd_idx == 0) begin
                                i2c_data      <= I2C_ADDR;
                                i2c_send_stop <= 0;
                            end else if (cmd_idx == 1) begin
                                i2c_data      <= CMD_PREFIX;
                                i2c_send_stop <= 0;
                            end else begin
                                i2c_data      <= init_cmds[cmd_idx - 2];
                                i2c_send_stop <= (cmd_idx == INIT_LEN + 1);
                            end
                        end
                        PH_PAGE_CMD: begin
                            case (cmd_idx[2:0])
                                3'd0: begin i2c_data <= I2C_ADDR;            i2c_send_stop <= 0; end
                                3'd1: begin i2c_data <= CMD_PREFIX;          i2c_send_stop <= 0; end
                                3'd2: begin i2c_data <= 8'hB0 | {5'd0, page}; i2c_send_stop <= 0; end
                                3'd3: begin i2c_data <= 8'h02;               i2c_send_stop <= 0; end
                                3'd4: begin i2c_data <= 8'h10;               i2c_send_stop <= 1; end
                                default: ;
                            endcase
                        end
                        PH_PAGE_DATA: begin
                            if (cmd_idx == 0) begin
                                i2c_data      <= I2C_ADDR;
                                i2c_send_stop <= 0;
                            end else if (cmd_idx == 1) begin
                                i2c_data      <= DATA_PREFIX;
                                i2c_send_stop <= 0;
                            end else begin
                                i2c_data      <= px_byte;
                                i2c_send_stop <= (col == 7'd127);
                            end
                        end
                    endcase
                    i2c_start  <= 1;
                    oled_state <= ST_WAIT;
                end
            end
            ST_WAIT: begin
                if (i2c_busy) oled_state <= ST_NEXT;
            end
            ST_NEXT: begin
                if (!i2c_busy) begin
                    case (phase)
                        PH_INIT: begin
                            if (cmd_idx == INIT_LEN + 1) begin
                                phase   <= PH_PAGE_CMD;
                                cmd_idx <= 0;
                                page    <= 0;
                                oled_state <= ST_BUSFREE;
                            end else begin
                                cmd_idx    <= cmd_idx + 1;
                                oled_state <= ST_SEND;
                            end
                        end
                        PH_PAGE_CMD: begin
                            if (cmd_idx == 4) begin
                                phase      <= PH_PAGE_DATA;
                                cmd_idx    <= 0;
                                col        <= 0;
                                gather_cnt <= 0;
                                oled_state <= ST_BUSFREE;
                            end else begin
                                cmd_idx    <= cmd_idx + 1;
                                oled_state <= ST_SEND;
                            end
                        end
                        PH_PAGE_DATA: begin
                            if (cmd_idx < 2) begin
                                cmd_idx <= cmd_idx + 1;
                                if (cmd_idx == 1) begin
                                    gather_cnt <= 0;
                                    oled_state <= ST_GATHER;
                                end else begin
                                    oled_state <= ST_SEND;
                                end
                            end else if (col == 7'd127) begin
                                phase   <= PH_PAGE_CMD;
                                cmd_idx <= 0;
                                page    <= (page == 3'd7) ? 3'd0 : page + 1;
                                oled_state <= ST_BUSFREE;
                            end else begin
                                col        <= col + 1;
                                gather_cnt <= 0;
                                oled_state <= ST_GATHER;
                            end
                        end
                    endcase
                end
            end
            ST_BUSFREE: begin
                busfree_cnt <= busfree_cnt + 1;
                if (&busfree_cnt) begin
                    busfree_cnt <= 0;
                    oled_state <= ST_SEND;
                end
            end
            ST_GATHER: begin
                gather_cnt <= gather_cnt + 1;
                if (gather_cnt >= 4'd1) begin
                    px_byte <= {(fb_dout > dither), px_byte[7:1]};
                end
                if (gather_cnt == 4'd8) begin
                    gather_cnt <= 0;
                    oled_state <= ST_SEND;
                end
            end
        endcase
    end

    // =========================================================================
    // LED — solid ON (active-low). Eliminates power-rail perturbation that a
    // blinking LED was causing on the RC oscillator (~0.15% frequency wiggle).
    // The OLED already indicates the bitstream is alive.
    // =========================================================================
    always @(posedge clk) led <= 1'b0;

endmodule
