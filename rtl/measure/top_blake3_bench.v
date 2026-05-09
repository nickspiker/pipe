// Single-instance CE-gated BLAKE3 self-test for Colorlight 5A-75B v8.0
//
// One blake3 instance, run twice: slow CE (gold, guaranteed correct) then
// fast CE (test, full PLL speed). Counter-based protocol ensures both
// phases process identical PRNG sequences. Compare accumulated hashes.
//
// CRT shows: gold hash (bottom strip), test hash (top strip, flipped CRT).
// Output: J1 pin 1 (R0, C4) = sync, J1 pin 2 (G0, D4) = video

module top_ntsc (
    input  wire clk,       // 25 MHz oscillator (P6)
    output reg  led,       // LED on T6 (active-low) — geiger random (alive indicator)
    output wire ext_led,   // T2 (J4 pin 6) — keypad LED, solid ON = pass, OFF = fail
    input  wire btn,       // User button on R7 (active-low)
    output reg  ntsc_sync, // J1 R0 (C4) — 560Ω
    output reg  ntsc_vid,  // J1 G0 (D4) — 220Ω
    output wire oled_scl,  // J1 B0 (E4) — I2C SCL
    output wire oled_sda   // J1 R1 (D3) — I2C SDA
);

    // =========================================================================
    // PLL: high-speed clock for test
    // =========================================================================
    wire sys_clk, pll_lock;

    // Power-on reset: hold blake3 in reset for 15 sys_clk cycles after PLL lock
    reg [3:0] por_cnt = 0;
    wire      por_done = &por_cnt;

`ifdef RING_STAGES
    // Single-inverter ring oscillator drives sys_clk. The 25 MHz crystal
    // (clk) is reserved for OLED display + windowed freq counter only.
    // Stage 0 = NOT (LUT4 INIT=h5555). Stages 1..N-1 = BUFs (INIT=hAAAA).
    // (* keep *) prevents BUF optimization. (* noglobal *) prevents nextpnr
    // from inserting a DCCA buffer into the loop.
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

    // Explicitly buffer ring_q[0] through a DCCA (global clock network)
    // for low-skew distribution to all sys_clk-clocked FFs (blake3, FSM,
    // accumulator, ...). Without DCCA, sys_clk is direct-routed and the
    // skew across blake3's wide datapath causes setup/hold failures even
    // at frequencies far below silicon Fmax. The (* noglobal *) on ring_q
    // keeps the oscillator loop itself fast (no DCCA delay inside the ring).
    (* keep *) DCCA dcca_sys_clk (
        .CLKI(ring_q[0]),
        .CE  (1'b1),
        .CLKO(sys_clk)
    );
    assign pll_lock = 1'b1;
`elsif PLL_CLKFB_DIV
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA       ("DISABLED"),
        .INTFB_WAKE       ("DISABLED"),
        .STDBY_ENABLE     ("DISABLED"),
        .DPHASE_SOURCE    ("DISABLED"),
        .OUTDIVIDER_MUXA  ("DIVA"),
        .OUTDIVIDER_MUXB  ("DIVB"),
        .OUTDIVIDER_MUXC  ("DIVC"),
        .OUTDIVIDER_MUXD  ("DIVD"),
        .CLKI_DIV         (`PLL_CLKI_DIV),
        .CLKFB_DIV        (`PLL_CLKFB_DIV),
        .CLKOP_ENABLE     ("ENABLED"),
        .CLKOP_DIV        (`PLL_CLKOP_DIV),
        .CLKOP_CPHASE     (`PLL_CLKOP_CPHASE),
        .CLKOP_FPHASE     (0),
        .FEEDBK_PATH      ("CLKOP")
    ) pll (
        .RST(1'b0), .STDBY(1'b0), .CLKI(clk),
        .CLKOP(sys_clk), .CLKFB(sys_clk), .CLKINTFB(),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0), .LOCK(pll_lock)
    );
`else
    assign sys_clk  = clk;
    assign pll_lock = 1'b1;
`endif

    always @(posedge sys_clk)
        if (!pll_lock)    por_cnt <= 0;
        else if (!por_done) por_cnt <= por_cnt + 1;

    // Blake3 reset: active-low. Assert during POR and button hold.
    wire b3_reset_n = por_done & pll_lock & ~btn_held_sys;

`ifdef RING_STAGES
    // =========================================================================
    // Ring frequency counter — ported from top_extclk.v (proven pipeline).
    //
    // Gated 32-bit ripple counter on sys_clk (the ring). 1/60 sec windowed FSM
    // in 25 MHz clk domain samples count → count_snap. count_snap × MULT_K
    // >> 32 = milli-MHz integer. Double-dabble produces 7 BCD digits → glyph
    // render → OLED top band.
    //
    // counter_enable / counter_reset are clk-domain regs synchronized into
    // sys_clk domain via 2-FF sync (race-free).
    // =========================================================================
    reg counter_enable = 1;
    reg counter_reset  = 0;

    reg [1:0] fc_ena_sync;
    reg [1:0] fc_rst_sync;
    always @(posedge sys_clk) begin
        fc_ena_sync <= {fc_ena_sync[0], counter_enable};
        fc_rst_sync <= {fc_rst_sync[0], counter_reset};
    end
    wire fc_ena_ext = fc_ena_sync[1];
    wire fc_rst_ext = fc_rst_sync[1];

    reg [31:0] fc_count;
    always @(posedge sys_clk or posedge fc_rst_ext) begin
        if (fc_rst_ext)        fc_count[0] <= 1'b0;
        else if (fc_ena_ext)   fc_count[0] <= ~fc_count[0];
    end
    genvar fc_gi;
    generate
        for (fc_gi = 1; fc_gi < 32; fc_gi = fc_gi + 1) begin : fc_ripple
            always @(negedge fc_count[fc_gi-1] or posedge fc_rst_ext) begin
                if (fc_rst_ext) fc_count[fc_gi] <= 1'b0;
                else            fc_count[fc_gi] <= ~fc_count[fc_gi];
            end
        end
    endgenerate

    // 60 Hz windowed FSM (clk domain): SAMPLE → DISCONNECT → READ → RESET → RECONNECT
    localparam integer FC_SNAP_INTERVAL = 25_000_000 / 60;  // 416666
    reg [19:0] fc_window_cnt = 0;
    reg [3:0]  fc_state      = 0;
    reg [3:0]  fc_settle     = 0;
    reg [31:0] count_snap    = 0;
    reg        snap_pulse    = 0;
    wire fc_global_reset = !por_done || btn_held_sys;
    always @(posedge clk) begin
        snap_pulse <= 1'b0;
        if (fc_global_reset) begin
            fc_state       <= 0;
            fc_window_cnt  <= 0;
            fc_settle      <= 0;
            counter_enable <= 1;
            counter_reset  <= 0;
        end else begin
            case (fc_state)
                4'd0: begin // SAMPLE
                    fc_window_cnt <= fc_window_cnt + 1;
                    if (fc_window_cnt == FC_SNAP_INTERVAL - 1) begin
                        counter_enable <= 1'b0;
                        fc_settle      <= 0;
                        fc_state       <= 4'd1;
                    end
                end
                4'd1: begin // DISCONNECT (settle ripple)
                    fc_settle <= fc_settle + 1;
                    if (fc_settle == 4'd4) fc_state <= 4'd2;
                end
                4'd2: begin // READ
                    count_snap <= fc_count;
                    snap_pulse <= 1'b1;
                    fc_settle  <= 0;
                    fc_state   <= 4'd3;
                end
                4'd3: begin // RESET counter
                    counter_reset <= 1'b1;
                    fc_settle     <= fc_settle + 1;
                    if (fc_settle == 4'd4) fc_state <= 4'd4;
                end
                4'd4: begin // RECONNECT
                    counter_reset  <= 1'b0;
                    counter_enable <= 1'b1;
                    fc_window_cnt  <= 0;
                    fc_state       <= 4'd0;
                end
            endcase
        end
    end

    // count_snap × MULT_K >> 32 = milli-MHz integer.
    // K = ceil(25,000 × 2^32 / 416,666) = 257,698,453.
    localparam [27:0] FC_MULT_K = 28'd257_698_453;
    wire [59:0] fc_product   = count_snap * FC_MULT_K;
    wire [22:0] milli_mhz    = fc_product[54:32];

    // Double-dabble: 23-bit milli_mhz → 7 BCD digits (28 bits). 23 cycles.
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
        if (fc_global_reset) begin
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

    reg [27:0] display_bcd = 0;
    always @(posedge clk) if (snap_pulse) display_bcd <= bcd_value;

    // Glyph ROM — 11 glyphs × 12w × 16h × 8bpp = 2112 bytes. Slot 10 = '.'.
    reg [7:0] glyph_rom [0:2111];
    initial $readmemh("decimal_glyphs.mem", glyph_rom);
`endif

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CE_GOLD_DIV = 256;      // gold CE divider (effective freq = PLL/256)

    // Protocol: 18-bit counter, bit taps for events (zero comparisons)
    //   [0..32767]                       warmup (LFSR runs, no accumulation)
    //   [32768..65535] + [98304..131071] accumulate (65536 cycles total)
    //   bit 17 high                      → done (≥131072)
    // The accumulate window has a 32K hole at counts 65536..98303 because the
    // bit-tap selects bit 15 (proto_hi[6]) directly instead of doing a ≥32768
    // comparison. Symmetric across gold/test so the comparison stays valid.
    localparam PROTO_BITS = 18;

    // =========================================================================
    // XOR-fold: 512 bits → 32 bits
    // =========================================================================
    function [31:0] xor_fold;
        input [511:0] h;
        integer i;
        begin
            xor_fold = 32'b0;
            for (i = 0; i < 16; i = i + 1)
                xor_fold = xor_fold ^ h[i*32 +: 32];
        end
    endfunction

    // =========================================================================
    // Phase + CE
    // =========================================================================
    localparam [2:0] PH_IDLE   = 3'd0, PH_GOLD = 3'd1, PH_SWITCH = 3'd2,
                     PH_TEST   = 3'd3, PH_DONE = 3'd4;
    reg [2:0] phase = PH_IDLE;
    reg [63:0] captured_seed, captured_seed2;

`ifdef DUT_SPIRIX_BITWISE
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_ADDBIT
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_ADDBIT_PIPE
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_UNIFIED
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_BASIC
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_MINMAX
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_ROUND
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_ROUND_PIPE
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_MUL_OPS
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_MUL_OPS_PIPE
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_DIVSQRT
`define DUT_MULTI_COMBO
`endif
`ifdef DUT_SPIRIX_CORE
`define DUT_MULTI_COMBO
`endif

`ifdef DUT_MULTI_COMBO
    // Multi-round: cycle through all 16 width combos (4 frac × 4 exp)
    reg [3:0]  combo = 0;          // sequential counter 0..15
    reg [3:0]  combo_mask = 0;     // random XOR mask (captured at start)
    wire [3:0] combo_actual = combo ^ combo_mask;  // shuffled combo index
    reg [15:0] combo_results = 0;  // pass/fail per combo (indexed by combo_actual)
    reg [15:0] combo_tested = 0;  // 1 = this combo has been tested
`endif

    // CE generator (registered for clean fanout at high freq)
    reg [7:0] ce_div = 0;
    reg       ce = 0;
    always @(posedge sys_clk) begin
        ce_div <= (ce_div == CE_GOLD_DIV - 1) ? 8'd0 : ce_div + 1;
        ce     <= (phase == PH_TEST) || (ce_div == CE_GOLD_DIV - 1);
    end

    // =========================================================================
    // PRNG: 64-bit Galois LFSR (maximal length, period 2^64-1)
    // Critical path: lfsr[0] → 1 LUT (AND tap) → FF.  ~0.7ns.
    // Taps: x^64 + x^63 + x^61 + x^60  (maximal, from Xilinx XAPP052)
    // Output: lfsr[31:0] window
    // =========================================================================
    localparam [63:0] LFSR_SEED  = 64'hCAFE_BABE_DEAD_BEEF;
    localparam [63:0] LFSR_SEED2 = 64'h0123_4567_89AB_CDEF;
    localparam [63:0] LFSR_TAPS = 64'hD800000000000000;  // bits 63,62,60,59

    reg [63:0] lfsr;
    wire       lfsr_fb = lfsr[0];
    wire [63:0] lfsr_next = {1'b0, lfsr[63:1]} ^ (lfsr_fb ? LFSR_TAPS : 64'b0);

    // Free-running entropy counter (never stops, XORed into seed on capture)
    reg [63:0] entropy = 0;
    always @(posedge sys_clk) entropy <= entropy + 1;

    // =========================================================================
    // DUT — switchable via defines
    //
    // DUT_SPIRIX_FMA (default), DUT_SPIRIX_MUL, DUT_SPIRIX_MUL_PIPE2,
    // DUT_SPIRIX_DIV_ITER, DUT_SPIRIX_DIVMOD_NR, DUT_SPIRIX_SQRT_NR,
    // DUT_SPIRIX_NR_DIV, DUT_SPIRIX_NR_SQRT, DUT_SPIRIX_SQRT_ITER,
    // DUT_HF_FMA, DUT_HF_MUL, DUT_HF_ADD, DUT_HF_DIV, DUT_HF_SQRT,
    // DUT_FPN_FMA, DUT_FPN_MUL, DUT_FPN_ADD, DUT_FPN_DIV, DUT_FPN_SQRT
    // All produce: 32-bit mul_fold. Iterative DUTs also define dut_advance.
    // =========================================================================

    // Second LFSR for 3-operand DUTs (FMA)
    reg [63:0] lfsr2;
    wire       lfsr2_fb = lfsr2[0];
    wire [63:0] lfsr2_next = {1'b0, lfsr2[63:1]} ^ (lfsr2_fb ? LFSR_TAPS : 64'b0);

`ifdef DUT_LFSR_PASSTHRU
    // ----- LFSR passthrough (harness ceiling benchmark, no DUT) -----
    // Fold both LFSRs to 32 bits, matching addbit's 128-bit output fanout.
    wire [31:0] mul_fold = lfsr[63:32] ^ lfsr[31:0]
                         ^ lfsr2[63:32] ^ lfsr2[31:0];

`elsif DUT_HF_FMA
    // ----- HardFloat mulAddRecFN (binary32 FMA), IEEE 754 I/O -----
    // LFSR provides 32-bit IEEE inputs; fNToRecFN/recFNToFN convert at boundary
    wire [31:0] ieee_a = lfsr[31:0];
    wire [31:0] ieee_b = lfsr[63:32];
    wire [31:0] ieee_c = lfsr2[31:0];
    wire [1:0]  hf_op  = lfsr2[33:32];

    wire [32:0] rec_a, rec_b, rec_c;
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_a (.in(ieee_a), .out(rec_a));
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_b (.in(ieee_b), .out(rec_b));
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_c (.in(ieee_c), .out(rec_c));

    wire [32:0] rec_out;
    wire [4:0]  hf_flags;
    mulAddRecFN #(.expWidth(8), .sigWidth(24)) dut_hf_fma (
        .control      (1'b1),
        .op           (hf_op),
        .a            (rec_a),
        .b            (rec_b),
        .c            (rec_c),
        .roundingMode (3'b000),
        .out          (rec_out),
        .exceptionFlags(hf_flags)
    );

    wire [31:0] hf_ieee_out;
    recFNToFN #(.expWidth(8), .sigWidth(24)) cvt_out (.in(rec_out), .out(hf_ieee_out));

    reg [31:0] hf_out_r;
    always @(posedge sys_clk) if (ce) hf_out_r <= hf_ieee_out;
    wire [31:0] mul_fold = hf_out_r;

`elsif DUT_HF_MUL
    // ----- HardFloat mulRecFN (binary32 multiply), IEEE 754 I/O -----
    wire [31:0] ieee_a = lfsr[31:0];
    wire [31:0] ieee_b = lfsr[63:32];

    wire [32:0] rec_a, rec_b;
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_a (.in(ieee_a), .out(rec_a));
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_b (.in(ieee_b), .out(rec_b));

    wire [32:0] rec_out;
    wire [4:0]  hf_flags;
    mulRecFN #(.expWidth(8), .sigWidth(24)) dut_hf_mul (
        .control      (1'b1),
        .a            (rec_a),
        .b            (rec_b),
        .roundingMode (3'b000),
        .out          (rec_out),
        .exceptionFlags(hf_flags)
    );

    wire [31:0] hf_ieee_out;
    recFNToFN #(.expWidth(8), .sigWidth(24)) cvt_out (.in(rec_out), .out(hf_ieee_out));

    reg [31:0] hf_out_r;
    always @(posedge sys_clk) if (ce) hf_out_r <= hf_ieee_out;
    wire [31:0] mul_fold = hf_out_r;

`elsif DUT_HF_ADD
    // ----- HardFloat addRecFN (binary32 add/sub), IEEE 754 I/O -----
    wire [31:0] ieee_a = lfsr[31:0];
    wire [31:0] ieee_b = lfsr[63:32];
    wire        hf_sub = lfsr[0];

    wire [32:0] rec_a, rec_b;
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_a (.in(ieee_a), .out(rec_a));
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_b (.in(ieee_b), .out(rec_b));

    wire [32:0] rec_out;
    wire [4:0]  hf_flags;
    addRecFN #(.expWidth(8), .sigWidth(24)) dut_hf_add (
        .control      (1'b1),
        .subOp        (hf_sub),
        .a            (rec_a),
        .b            (rec_b),
        .roundingMode (3'b000),
        .out          (rec_out),
        .exceptionFlags(hf_flags)
    );

    wire [31:0] hf_ieee_out;
    recFNToFN #(.expWidth(8), .sigWidth(24)) cvt_out (.in(rec_out), .out(hf_ieee_out));

    reg [31:0] hf_out_r;
    always @(posedge sys_clk) if (ce) hf_out_r <= hf_ieee_out;
    wire [31:0] mul_fold = hf_out_r;

`elsif DUT_FPN_FMA
    // ----- FPnew FMA (binary32), native IEEE 754 I/O -----
    wire [31:0] fpn_a = lfsr[31:0];
    wire [31:0] fpn_b = lfsr[63:32];
    wire [31:0] fpn_c = lfsr2[31:0];
    wire        fpn_sub = lfsr2[32];

    wire [31:0] fpn_result;
    fpnew_fma dut_fpn_fma (
        .clk_i          (sys_clk),
        .rst_ni         (b3_reset_n),
        .operands_i     ({fpn_c, fpn_b, fpn_a}),
        .is_boxed_i     (3'b111),
        .rnd_mode_i     (3'b000),       // RNE
        .op_i           (4'd0),         // FMADD
        .op_mod_i       (fpn_sub),
        .tag_i          (1'b0),
        .mask_i         (1'b1),
        .aux_i          (1'b0),
        .in_valid_i     (1'b1),
        .flush_i        (1'b0),
        .out_ready_i    (1'b1),
        .result_o       (fpn_result),
        .status_o       (),
        .extension_bit_o(),
        .tag_o          (),
        .mask_o         (),
        .aux_o          (),
        .out_valid_o    (),
        .in_ready_o     (),
        .busy_o         (),
        .reg_ena_i      (1'b0),
        .early_out_valid_o()
    );

    reg [31:0] fpn_out_r;
    always @(posedge sys_clk) if (ce) fpn_out_r <= fpn_result;
    wire [31:0] mul_fold = fpn_out_r;

`elsif DUT_FPN_MUL
    // ----- FPnew multiply (FMA with c=0), native IEEE 754 I/O -----
    wire [31:0] fpn_a = lfsr[31:0];
    wire [31:0] fpn_b = lfsr[63:32];

    wire [31:0] fpn_result;
    fpnew_fma dut_fpn_mul (
        .clk_i          (sys_clk),
        .rst_ni         (b3_reset_n),
        .operands_i     ({32'h00000000, fpn_b, fpn_a}),
        .is_boxed_i     (3'b111),
        .rnd_mode_i     (3'b000),       // RNE
        .op_i           (4'd3),         // MUL
        .op_mod_i       (1'b0),
        .tag_i          (1'b0),
        .mask_i         (1'b1),
        .aux_i          (1'b0),
        .in_valid_i     (1'b1),
        .flush_i        (1'b0),
        .out_ready_i    (1'b1),
        .result_o       (fpn_result),
        .status_o       (),
        .extension_bit_o(),
        .tag_o          (),
        .mask_o         (),
        .aux_o          (),
        .out_valid_o    (),
        .in_ready_o     (),
        .busy_o         (),
        .reg_ena_i      (1'b0),
        .early_out_valid_o()
    );

    reg [31:0] fpn_out_r;
    always @(posedge sys_clk) if (ce) fpn_out_r <= fpn_result;
    wire [31:0] mul_fold = fpn_out_r;

`elsif DUT_FPN_ADD
    // ----- FPnew add (FMA with b=1.0), native IEEE 754 I/O -----
    wire [31:0] fpn_a = lfsr[31:0];
    wire [31:0] fpn_b = lfsr[63:32];
    wire        fpn_sub = lfsr[0];

    wire [31:0] fpn_result;
    fpnew_fma dut_fpn_add (
        .clk_i          (sys_clk),
        .rst_ni         (b3_reset_n),
        .operands_i     ({fpn_b, 32'h3F800000, fpn_a}),
        .is_boxed_i     (3'b111),
        .rnd_mode_i     (3'b000),       // RNE
        .op_i           (4'd2),         // ADD
        .op_mod_i       (fpn_sub),
        .tag_i          (1'b0),
        .mask_i         (1'b1),
        .aux_i          (1'b0),
        .in_valid_i     (1'b1),
        .flush_i        (1'b0),
        .out_ready_i    (1'b1),
        .result_o       (fpn_result),
        .status_o       (),
        .extension_bit_o(),
        .tag_o          (),
        .mask_o         (),
        .aux_o          (),
        .out_valid_o    (),
        .in_ready_o     (),
        .busy_o         (),
        .reg_ena_i      (1'b0),
        .early_out_valid_o()
    );

    reg [31:0] fpn_out_r;
    always @(posedge sys_clk) if (ce) fpn_out_r <= fpn_result;
    wire [31:0] mul_fold = fpn_out_r;

`elsif DUT_SPIRIX_ADDSUB
    // ----- Spirix addsub (combinational + registered output) -----
    wire signed [24:0] as_a_frac = lfsr[24:0];
    wire signed  [7:0] as_a_exp  = lfsr[32:25];
    wire signed [24:0] as_b_frac = lfsr[57:33];
    wire signed  [7:0] as_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};
    wire               as_sub    = lfsr[0];

    wire signed [24:0] as_r_frac;
    wire signed  [7:0] as_r_exp;

    spirix_addsub #(.FRAC_BITS(25), .EXP_BITS(8)) dut_as (
        .a_frac(as_a_frac), .a_exp(as_a_exp),
        .b_frac(as_b_frac), .b_exp(as_b_exp),
        .sub(as_sub),
        .result_frac(as_r_frac), .result_exp(as_r_exp)
    );

    reg signed [24:0] as_r_frac_r;
    reg signed  [7:0] as_r_exp_r;
    always @(posedge sys_clk) if (ce) begin
        as_r_frac_r <= as_r_frac;
        as_r_exp_r  <= as_r_exp;
    end

    wire [32:0] as_out = {as_r_exp_r, as_r_frac_r};
    wire [31:0] mul_fold = as_out[31:0] ^ {31'b0, as_out[32]};

`elsif DUT_SPIRIX_ADDSUB_PIPE2
    // ----- Spirix addsub_pipe2 (2-stage pipeline) -----
    wire signed [24:0] as_a_frac = lfsr[24:0];
    wire signed  [7:0] as_a_exp  = lfsr[32:25];
    wire signed [24:0] as_b_frac = lfsr[57:33];
    wire signed  [7:0] as_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};
    wire               as_sub    = lfsr[0];

    wire signed [24:0] as_r_frac;
    wire signed  [7:0] as_r_exp;

    spirix_addsub_pipe2 #(.FRAC_BITS(25), .EXP_BITS(8)) dut_as (
        .clk(sys_clk), .ce(ce),
        .a_frac(as_a_frac), .a_exp(as_a_exp),
        .b_frac(as_b_frac), .b_exp(as_b_exp),
        .sub(as_sub),
        .result_frac(as_r_frac), .result_exp(as_r_exp)
    );

    wire [32:0] as_out = {as_r_exp, as_r_frac};
    wire [31:0] mul_fold = as_out[31:0] ^ {31'b0, as_out[32]};

`elsif DUT_SPIRIX_MUL
    // ----- Spirix multiply (standalone) -----
    wire signed [24:0] mul_a_frac = lfsr[24:0];
    wire signed  [7:0] mul_a_exp  = lfsr[32:25];
    wire signed [24:0] mul_b_frac = lfsr[57:33];
    wire signed  [7:0] mul_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};

    wire signed [24:0] mul_r_frac;
    wire signed  [7:0] mul_r_exp;

    spirix_multiply #(.FRAC_BITS(25), .EXP_BITS(8)) dut_mul (
        .a_frac(mul_a_frac), .a_exp(mul_a_exp),
        .b_frac(mul_b_frac), .b_exp(mul_b_exp),
        .negate(1'b0),
        .result_frac(mul_r_frac), .result_exp(mul_r_exp)
    );

    reg signed [24:0] mul_r_frac_r;
    reg signed  [7:0] mul_r_exp_r;
    always @(posedge sys_clk) if (ce) begin
        mul_r_frac_r <= mul_r_frac;
        mul_r_exp_r  <= mul_r_exp;
    end

    wire [32:0] mul_out = {mul_r_exp_r, mul_r_frac_r};
    wire [31:0] mul_fold = mul_out[31:0] ^ {31'b0, mul_out[32]};

`elsif DUT_SPIRIX_MUL_PIPE2
    // ----- Spirix multiply_pipe2 (2-stage pipeline) -----
    wire signed [24:0] mul_a_frac = lfsr[24:0];
    wire signed  [7:0] mul_a_exp  = lfsr[32:25];
    wire signed [24:0] mul_b_frac = lfsr[57:33];
    wire signed  [7:0] mul_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};

    wire signed [24:0] mul_r_frac;
    wire signed  [7:0] mul_r_exp;

    spirix_multiply_pipe2 #(.FRAC_BITS(25), .EXP_BITS(8)) dut_mul (
        .clk(sys_clk), .ce(ce),
        .a_frac(mul_a_frac), .a_exp(mul_a_exp),
        .b_frac(mul_b_frac), .b_exp(mul_b_exp),
        .negate(1'b0),
        .result_frac(mul_r_frac), .result_exp(mul_r_exp)
    );

    wire [32:0] mul_out = {mul_r_exp, mul_r_frac};
    wire [31:0] mul_fold = mul_out[31:0] ^ {31'b0, mul_out[32]};

`elsif DUT_SPIRIX_DIV_ITER
    // ----- Spirix divide_iter (iterative, 0 DSP) -----
    wire signed [24:0] dut_a_frac = lfsr[24:0];
    wire signed  [7:0] dut_a_exp  = lfsr[32:25];
    wire signed [24:0] dut_b_frac = lfsr[57:33];
    wire signed  [7:0] dut_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};

    wire signed [24:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;
    wire dut_busy_w, dut_done_w;

    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        // Block iter_start during PH_IDLE/PH_SWITCH so we don't sample stale lfsr.
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && !dut_busy_w)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (dut_done_w)
            iter_busy <= 0;
    end

    spirix_divide_iter #(.FRAC_BITS(25), .EXP_BITS(8)) dut (
        .clk(sys_clk), .start(iter_start),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .b_frac(dut_b_frac), .b_exp(dut_b_exp),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp),
        .busy(dut_busy_w), .done(dut_done_w)
    );

    wire [32:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out[31:0] ^ {31'b0, dut_out[32]};
    wire dut_advance = dut_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_DIVMOD_NR
    // ----- Spirix divmod_nr (8-stage pipeline, 20 DSP) -----
    wire signed [24:0] dut_a_frac = lfsr[24:0];
    wire signed  [7:0] dut_a_exp  = lfsr[32:25];
    wire signed [24:0] dut_b_frac = lfsr[57:33];
    wire signed  [7:0] dut_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};

    wire signed [24:0] dut_q_frac;
    wire signed  [7:0] dut_q_exp;

    spirix_divmod_nr #(.FRAC_BITS(25), .EXP_BITS(8), .ENABLE_MOD(0)) dut (
        .clk(sys_clk), .ce(ce),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .b_frac(dut_b_frac), .b_exp(dut_b_exp),
        .q_frac(dut_q_frac), .q_exp(dut_q_exp),
        .mod_frac(), .mod_exp()
    );

    wire [32:0] dut_out = {dut_q_exp, dut_q_frac};
    wire [31:0] mul_fold = dut_out[31:0] ^ {31'b0, dut_out[32]};

`elsif DUT_SPIRIX_SQRT_NR
    // ----- Spirix sqrt_nr (10-stage pipeline, 27 DSP) -----
    wire signed [24:0] dut_a_frac = lfsr[24:0];
    wire signed  [7:0] dut_a_exp  = lfsr[32:25];

    wire signed [24:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;

    spirix_sqrt_nr #(.FRAC_BITS(25), .EXP_BITS(8)) dut (
        .clk(sys_clk), .ce(ce),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp)
    );

    wire [32:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out[31:0] ^ {31'b0, dut_out[32]};

`elsif DUT_SPIRIX_NR_DIV
    // ----- Spirix nr_divsqrt (divide mode, iterative, 1 DSP) -----
    wire signed [24:0] dut_a_frac = lfsr[24:0];
    wire signed  [7:0] dut_a_exp  = lfsr[32:25];
    wire signed [24:0] dut_b_frac = lfsr[57:33];
    wire signed  [7:0] dut_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};

    wire signed [24:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;
    wire dut_busy_w, dut_done_w;

    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        // Block iter_start during PH_IDLE/PH_SWITCH so we don't sample stale lfsr.
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && !dut_busy_w)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (dut_done_w)
            iter_busy <= 0;
    end

    spirix_nr_divsqrt #(.FRAC_BITS(25), .EXP_BITS(8)) dut (
        .clk(sys_clk), .start(iter_start), .mode(1'b0),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .b_frac(dut_b_frac), .b_exp(dut_b_exp),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp),
        .busy(dut_busy_w), .done(dut_done_w)
    );

    wire [32:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out[31:0] ^ {31'b0, dut_out[32]};
    wire dut_advance = dut_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_NR_SQRT
    // ----- Spirix nr_divsqrt (sqrt mode, iterative, 1 DSP) -----
    wire signed [24:0] dut_a_frac = lfsr[24:0];
    wire signed  [7:0] dut_a_exp  = lfsr[32:25];

    wire signed [24:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;
    wire dut_busy_w, dut_done_w;

    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        // Block iter_start during PH_IDLE/PH_SWITCH so we don't sample stale lfsr.
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && !dut_busy_w)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (dut_done_w)
            iter_busy <= 0;
    end

    spirix_nr_divsqrt #(.FRAC_BITS(25), .EXP_BITS(8)) dut (
        .clk(sys_clk), .start(iter_start), .mode(1'b1),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .b_frac(25'sb0), .b_exp(8'sb0),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp),
        .busy(dut_busy_w), .done(dut_done_w)
    );

    wire [32:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out[31:0] ^ {31'b0, dut_out[32]};
    wire dut_advance = dut_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_SQRT_ITER
    // ----- Spirix sqrt_iter (iterative, 0 DSP) -----
    wire signed [24:0] dut_a_frac = lfsr[24:0];
    wire signed  [7:0] dut_a_exp  = lfsr[32:25];

    wire signed [24:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;
    wire dut_busy_w, dut_done_w;

    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        // Block iter_start during PH_IDLE/PH_SWITCH so we don't sample stale lfsr.
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && !dut_busy_w)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (dut_done_w)
            iter_busy <= 0;
    end

    spirix_sqrt_iter #(.FRAC_BITS(25), .EXP_BITS(8)) dut (
        .clk(sys_clk), .start(iter_start),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp),
        .busy(dut_busy_w), .done(dut_done_w)
    );

    wire [32:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out[31:0] ^ {31'b0, dut_out[32]};
    wire dut_advance = dut_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_ADDSUB_P4
    // ----- Spirix add/sub paper-comparison (FRAC=24, banker's RNE, 0 DSP) -----
    wire signed [23:0] as_a_frac = lfsr[23:0];
    wire signed  [7:0] as_a_exp  = lfsr[31:24];
    wire signed [23:0] as_b_frac = lfsr[55:32];
    wire signed  [7:0] as_b_exp  = lfsr[63:56];
    wire               as_sub    = lfsr[0];

    wire signed [23:0] as_r_frac;
    wire signed  [7:0] as_r_exp;

    spirix_addsub #(.FRAC_BITS(24), .EXP_BITS(8)) dut_as (
        .a_frac(as_a_frac), .a_exp(as_a_exp),
        .b_frac(as_b_frac), .b_exp(as_b_exp),
        .sub(as_sub),
        .result_frac(as_r_frac), .result_exp(as_r_exp)
    );

    reg signed [23:0] as_r_frac_r;
    reg signed  [7:0] as_r_exp_r;
    always @(posedge sys_clk) if (ce) begin
        as_r_frac_r <= as_r_frac;
        as_r_exp_r  <= as_r_exp;
    end

    wire [31:0] mul_fold = {as_r_exp_r, as_r_frac_r};

`elsif DUT_SPIRIX_MUL_P4
    // ----- Spirix multiply paper-comparison (FRAC=24, banker's RNE, 0 DSP) -----
    wire signed [23:0] mp_a_frac = lfsr[23:0];
    wire signed  [7:0] mp_a_exp  = lfsr[31:24];
    wire signed [23:0] mp_b_frac = lfsr[55:32];
    wire signed  [7:0] mp_b_exp  = lfsr[63:56];

    wire signed [23:0] mp_r_frac;
    wire signed  [7:0] mp_r_exp;

    spirix_multiply #(.FRAC_BITS(24), .EXP_BITS(8)) dut_mp (
        .a_frac(mp_a_frac), .a_exp(mp_a_exp),
        .b_frac(mp_b_frac), .b_exp(mp_b_exp),
        .result_frac(mp_r_frac), .result_exp(mp_r_exp)
    );

    reg signed [23:0] mp_r_frac_r;
    reg signed  [7:0] mp_r_exp_r;
    always @(posedge sys_clk) if (ce) begin
        mp_r_frac_r <= mp_r_frac;
        mp_r_exp_r  <= mp_r_exp;
    end

    wire [31:0] mul_fold = {mp_r_exp_r, mp_r_frac_r};

`elsif DUT_SPIRIX_DIV_P4
    // ----- Spirix divide PARALLEL=4 (paper-comparison FRAC=24, 7 cyc, 0 DSP) -----
    wire signed [23:0] dut_a_frac = lfsr[23:0];
    wire signed  [7:0] dut_a_exp  = lfsr[31:24];
    wire signed [23:0] dut_b_frac = lfsr[55:32];
    wire signed  [7:0] dut_b_exp  = lfsr[63:56];

    wire signed [23:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;
    wire dut_busy_w, dut_done_w;

    // Block iter_start during PH_IDLE/PH_SWITCH for parity with FPnew reset
    // gating. Without this, an iter_start in PH_SWITCH samples stale gold-phase
    // lfsr (captured_seed assignment hasn't taken effect yet), contaminating
    // the first test-phase result and causing repeatable gold≠test mismatches.
    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && !dut_busy_w)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (dut_done_w)
            iter_busy <= 0;
    end

    spirix_divide #(.FRAC_BITS(24), .EXP_BITS(8), .PARALLEL(4)) dut (
        .clk(sys_clk), .start(iter_start),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .b_frac(dut_b_frac), .b_exp(dut_b_exp),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp),
        .busy(dut_busy_w), .done(dut_done_w)
    );

    wire [31:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out;
    wire dut_advance = dut_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_SQRT_P4
    // ----- Spirix sqrt PARALLEL=4 (paper-comparison FRAC=24, 8 cyc, 0 DSP) -----
    wire signed [23:0] dut_a_frac = lfsr[23:0];
    wire signed  [7:0] dut_a_exp  = lfsr[31:24];

    wire signed [23:0] dut_r_frac;
    wire signed  [7:0] dut_r_exp;
    wire dut_busy_w, dut_done_w;

    // See DUT_SPIRIX_DIV_P4 note above: block iter_start during PH_IDLE/PH_SWITCH.
    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && !dut_busy_w)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (dut_done_w)
            iter_busy <= 0;
    end

    spirix_sqrt #(.FRAC_BITS(24), .EXP_BITS(8), .PARALLEL(4)) dut (
        .clk(sys_clk), .start(iter_start),
        .a_frac(dut_a_frac), .a_exp(dut_a_exp),
        .result_frac(dut_r_frac), .result_exp(dut_r_exp),
        .busy(dut_busy_w), .done(dut_done_w)
    );

    wire [31:0] dut_out = {dut_r_exp, dut_r_frac};
    wire [31:0] mul_fold = dut_out;
    wire dut_advance = dut_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_HF_DIV
    // ----- HardFloat divSqrtRecFN_small (divide), IEEE 754 I/O -----
    wire [31:0] ieee_a = lfsr[31:0];
    wire [31:0] ieee_b = lfsr[63:32];

    wire [32:0] rec_a, rec_b;
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_a (.in(ieee_a), .out(rec_a));
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_b (.in(ieee_b), .out(rec_b));

    wire hf_inReady, hf_outValid;
    wire [32:0] hf_rec_out;
    wire [4:0]  hf_flags;

    reg iter_busy = 0;
    reg iter_inValid = 0;
    always @(posedge sys_clk) begin
        iter_inValid <= 0;
        // Block iter_inValid during PH_IDLE/PH_SWITCH (parity with FPnew/Spirix iterative).
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && hf_inReady)
            begin iter_inValid <= 1; iter_busy <= 1; end
        else if (hf_outValid)
            iter_busy <= 0;
    end

    div_f32 dut_hf_div (
        .nReset    (b3_reset_n),
        .clock     (sys_clk),
        .inReady   (hf_inReady),
        .inValid   (iter_inValid),
        .a         (rec_a),
        .b         (rec_b),
        .roundingMode(3'b000),
        .outValid  (hf_outValid),
        .out       (hf_rec_out),
        .exceptionFlags(hf_flags)
    );

    wire [31:0] hf_ieee_out;
    recFNToFN #(.expWidth(8), .sigWidth(24)) cvt_out (.in(hf_rec_out), .out(hf_ieee_out));

    reg [31:0] hf_out_r;
    always @(posedge sys_clk) if (hf_outValid) hf_out_r <= hf_ieee_out;
    wire [31:0] mul_fold = hf_out_r;
    wire dut_advance = hf_outValid;
`define DUT_ITER_ADVANCE

`elsif DUT_HF_SQRT
    // ----- HardFloat divSqrtRecFN_small (sqrt), IEEE 754 I/O -----
    wire [31:0] ieee_a = lfsr[31:0];

    wire [32:0] rec_a;
    fNToRecFN #(.expWidth(8), .sigWidth(24)) cvt_a (.in(ieee_a), .out(rec_a));

    wire hf_inReady, hf_outValid;
    wire [32:0] hf_rec_out;
    wire [4:0]  hf_flags;

    reg iter_busy = 0;
    reg iter_inValid = 0;
    always @(posedge sys_clk) begin
        iter_inValid <= 0;
        // Block iter_inValid during PH_IDLE/PH_SWITCH (parity with FPnew/Spirix iterative).
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            iter_busy <= 0;
        else if (ce && !iter_busy && hf_inReady)
            begin iter_inValid <= 1; iter_busy <= 1; end
        else if (hf_outValid)
            iter_busy <= 0;
    end

    sqrt_f32 dut_hf_sqrt (
        .nReset    (b3_reset_n),
        .clock     (sys_clk),
        .inReady   (hf_inReady),
        .inValid   (iter_inValid),
        .a         (rec_a),
        .roundingMode(3'b000),
        .outValid  (hf_outValid),
        .out       (hf_rec_out),
        .exceptionFlags(hf_flags)
    );

    wire [31:0] hf_ieee_out;
    recFNToFN #(.expWidth(8), .sigWidth(24)) cvt_out (.in(hf_rec_out), .out(hf_ieee_out));

    reg [31:0] hf_out_r;
    always @(posedge sys_clk) if (hf_outValid) hf_out_r <= hf_ieee_out;
    wire [31:0] mul_fold = hf_out_r;
    wire dut_advance = hf_outValid;
`define DUT_ITER_ADVANCE

`elsif DUT_FPN_DIV
    // ----- FPnew div (div_sqrt_mvp_wrapper, Div_start) -----
    wire [31:0] ieee_a = lfsr[31:0];
    wire [31:0] ieee_b = lfsr[63:32];

    wire fpn_ready, fpn_done;
    wire [63:0] fpn_result64;
    wire [4:0]  fpn_fflags;

    // Reset between phases so DUT state doesn't leak gold→test.
    wire fpn_div_rst_n = b3_reset_n && (phase != PH_IDLE) && (phase != PH_SWITCH);

    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        // Clear iter_busy whenever DUT is in reset — otherwise an iter_start
        // pulse fired during PH_IDLE/PH_SWITCH (when ce ticks but DUT ignores
        // it) leaves iter_busy stuck at 1 forever and the handshake deadlocks.
        if (btn_held_sys || !por_done || !fpn_div_rst_n)
            iter_busy <= 0;
        else if (ce && !iter_busy && fpn_ready)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (fpn_done)
            iter_busy <= 0;
    end

    div_sqrt_mvp_wrapper #(.PrePipeline_depth_S(0), .PostPipeline_depth_S(0)) dut_fpn_div (
        .Clk_CI          (sys_clk),
        .Rst_RBI         (fpn_div_rst_n),
        .Div_start_SI    (iter_start),
        .Sqrt_start_SI   (1'b0),
        .Operand_a_DI    ({32'b0, ieee_a}),
        .Operand_b_DI    ({32'b0, ieee_b}),
        .RM_SI           (3'b000),
        .Precision_ctl_SI(6'b0),
        .Format_sel_SI   (2'b00),       // FP32
        .Kill_SI         (1'b0),
        .Result_DO       (fpn_result64),
        .Fflags_SO       (fpn_fflags),
        .Ready_SO        (fpn_ready),
        .Done_SO         (fpn_done)
    );

    reg [31:0] fpn_out_r;
    always @(posedge sys_clk) if (fpn_done) fpn_out_r <= fpn_result64[31:0];
    wire [31:0] mul_fold = fpn_out_r;
    wire dut_advance = fpn_done;
`define DUT_ITER_ADVANCE

`elsif DUT_FPN_SQRT
    // ----- FPnew sqrt (div_sqrt_mvp_wrapper, Sqrt_start) -----
    wire [31:0] ieee_a = lfsr[31:0];

    wire fpn_ready, fpn_done;
    wire [63:0] fpn_result64;
    wire [4:0]  fpn_fflags;

    // Reset between phases so DUT state doesn't leak gold→test.
    wire fpn_sqrt_rst_n = b3_reset_n && (phase != PH_IDLE) && (phase != PH_SWITCH);

    reg iter_busy = 0;
    reg iter_start = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        // Clear iter_busy whenever DUT is in reset (see fpn_div note above).
        if (btn_held_sys || !por_done || !fpn_sqrt_rst_n)
            iter_busy <= 0;
        else if (ce && !iter_busy && fpn_ready)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (fpn_done)
            iter_busy <= 0;
    end
    div_sqrt_mvp_wrapper #(.PrePipeline_depth_S(0), .PostPipeline_depth_S(0)) dut_fpn_sqrt (
        .Clk_CI          (sys_clk),
        .Rst_RBI         (fpn_sqrt_rst_n),
        .Div_start_SI    (1'b0),
        .Sqrt_start_SI   (iter_start),
        .Operand_a_DI    ({32'b0, ieee_a}),
        .Operand_b_DI    (64'b0),
        .RM_SI           (3'b000),
        .Precision_ctl_SI(6'b0),
        .Format_sel_SI   (2'b00),       // FP32
        .Kill_SI         (1'b0),
        .Result_DO       (fpn_result64),
        .Fflags_SO       (fpn_fflags),
        .Ready_SO        (fpn_ready),
        .Done_SO         (fpn_done)
    );

    reg [31:0] fpn_out_r;
    always @(posedge sys_clk) if (fpn_done) fpn_out_r <= fpn_result64[31:0];
    wire [31:0] mul_fold = fpn_out_r;
    wire dut_advance = fpn_done;
`define DUT_ITER_ADVANCE

`elsif DUT_BLAKE3
    // ----- BLAKE3 compression core (iterative, ~30 cycles per hash) -----
    // 256-bit chain (BLAKE3 IV), 512-bit message tiled from lfsr/lfsr2,
    // counter=0, numbytes=64, dflags = ROOT|CHUNK_END|CHUNK_START.
    // Reset gated through PH_IDLE/PH_SWITCH so internal state doesn't leak
    // gold→test (parity with FPnew div/sqrt iter pattern, see SYNTH_NOTES.md).
    wire [255:0] b3_chain_in = {
        32'h5BE0CD19, 32'h1F83D9AB, 32'h9B05688C, 32'h510E527F,
        32'hA54FF53A, 32'h3C6EF372, 32'hBB67AE85, 32'h6A09E667
    };
    wire [511:0] b3_mblock_in = {
        ~lfsr,
        lfsr ^ 64'hAAAA_AAAA_AAAA_AAAA,
        lfsr + 64'h1234_5678_9ABC_DEF0,
        lfsr - 64'hFEDC_BA98_7654_3210,
        lfsr2 ^ lfsr,
        lfsr2,
        lfsr2 + 64'h5555_5555_5555_5555,
        lfsr
    };

    wire [511:0] b3_hash_out;
    wire         b3_ready;       // o_valid: high during S_IDLE = ready for next input
    wire blake3_rst_n = b3_reset_n && (phase != PH_IDLE) && (phase != PH_SWITCH);

    reg iter_busy   = 0;
    reg iter_start  = 0;
    reg b3_ready_d  = 0;
    always @(posedge sys_clk) begin
        iter_start <= 0;
        b3_ready_d <= b3_ready;
        // Clear iter_busy whenever DUT is in reset — same defensive pattern
        // as fpn_div: prevents handshake deadlock if iter_start fired during
        // PH_IDLE/PH_SWITCH while DUT was held in reset.
        if (btn_held_sys || !por_done || !blake3_rst_n)
            iter_busy <= 0;
        else if (ce && !iter_busy && b3_ready)
            begin iter_start <= 1; iter_busy <= 1; end
        else if (b3_ready && !b3_ready_d)
            iter_busy <= 0;
    end

    // i_ce held high so blake3's internal FSM advances every sys_clk inside
    // a hash. CE-gating happens at iter_start (matches spirix_divide_iter and
    // FPnew div/sqrt pattern). Without this, blake3 deadlocks: iter_start is a
    // 1-cycle pulse, but blake3.i_ce is only high 1/256 cycles in PH_GOLD, so
    // blake3 misses the i_valid window and stays stuck in S_IDLE forever.
    blake3 dut_blake3 (
        .i_clk     (sys_clk),
        .i_reset   (blake3_rst_n),
        .i_ce      (1'b1),
        .i_chain   (b3_chain_in),
        .i_mblock  (b3_mblock_in),
        .i_counter (64'd0),
        .i_numbytes(32'd64),
        .i_dflags  (32'h0000_000B),  // CHUNK_START | CHUNK_END | ROOT
        .i_valid   (iter_start),
        .o_hash    (b3_hash_out),
        .o_valid   (b3_ready)
    );

    // Latch output on completion (rising edge of b3_ready)
    reg [511:0] b3_out_r = 0;
    always @(posedge sys_clk)
        if (b3_ready && !b3_ready_d) b3_out_r <= b3_hash_out;

    // XOR-fold 512 → 32 (matches xor_fold function pattern — manually unrolled)
    wire [31:0] mul_fold = b3_out_r[ 31:  0] ^ b3_out_r[ 63: 32]
                         ^ b3_out_r[ 95: 64] ^ b3_out_r[127: 96]
                         ^ b3_out_r[159:128] ^ b3_out_r[191:160]
                         ^ b3_out_r[223:192] ^ b3_out_r[255:224]
                         ^ b3_out_r[287:256] ^ b3_out_r[319:288]
                         ^ b3_out_r[351:320] ^ b3_out_r[383:352]
                         ^ b3_out_r[415:384] ^ b3_out_r[447:416]
                         ^ b3_out_r[479:448] ^ b3_out_r[511:480];

    wire dut_advance = b3_ready && !b3_ready_d;  // rising edge = hash done
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_ADDBIT
    // ----- Spirix ALU addbit (combinational + output reg, 5 ops, 64-bit datapath) -----
    // ADD/SUB/AND/OR/XOR with close/far split + shared barrel.
    // Full 64-bit inputs, random width + op selection from LFSR.

    wire signed [63:0] ab_a_frac = lfsr[63:0];
    wire signed [63:0] ab_a_exp  = lfsr2[63:0];
    wire signed [63:0] ab_b_frac = {lfsr[31:0], lfsr2[31:0]};
    wire signed [63:0] ab_b_exp  = {lfsr2[31:0], lfsr[31:0]};

    // Map lfsr2 bits to valid op range 0..4 (5 ops: ADD/SUB/AND/OR/XOR)
    wire [2:0] ab_raw_op = lfsr2[34:32];
    wire [2:0] ab_op = (ab_raw_op > 3'd4) ? (ab_raw_op - 3'd5) : ab_raw_op;

    // Width from shuffled combo: random execution order each run
    wire [1:0] ab_frac_w = combo_actual[1:0];  // 00=8 01=16 10=32 11=64
    wire [1:0] ab_exp_w  = combo_actual[3:2];  // 00=8 01=16 10=32 11=64

    wire signed [63:0] ab_r_frac, ab_r_exp;

    spirix_alu_addbit #(.MAX_FRAC(64), .MAX_EXP(64)) dut_ab (
        .clk(sys_clk), .ce(ce),
        .op(ab_op),
        .frac_width(ab_frac_w),
        .exp_width(ab_exp_w),
        .a_frac(ab_a_frac), .a_exp(ab_a_exp),
        .b_frac(ab_b_frac), .b_exp(ab_b_exp),
        .result_frac(ab_r_frac), .result_exp(ab_r_exp)
    );

    wire [31:0] mul_fold = ab_r_frac[63:32] ^ ab_r_frac[31:0]
                         ^ ab_r_exp[63:32]  ^ ab_r_exp[31:0];

`elsif DUT_SPIRIX_ADDBIT_PIPE
    // ----- Spirix ALU addbit_pipe (2-stage CE-gated, 5 ops, 64-bit datapath) -----
    // ADD/SUB/AND/OR/XOR with close/far split + shared barrel.

    wire signed [63:0] abp_a_frac = lfsr[63:0];
    wire signed [63:0] abp_a_exp  = lfsr2[63:0];
    wire signed [63:0] abp_b_frac = {lfsr[31:0], lfsr2[31:0]};
    wire signed [63:0] abp_b_exp  = {lfsr2[31:0], lfsr[31:0]};

    // Map lfsr2 bits to valid op range 0..4 (5 ops: ADD/SUB/AND/OR/XOR)
    wire [2:0] abp_raw_op = lfsr2[34:32];
    wire [2:0] abp_op = (abp_raw_op > 3'd4) ? (abp_raw_op - 3'd5) : abp_raw_op;

    wire [1:0] abp_frac_w = combo_actual[1:0];
    wire [1:0] abp_exp_w  = combo_actual[3:2];

    wire signed [63:0] abp_r_frac, abp_r_exp;

    spirix_alu_addbit_pipe #(.MAX_FRAC(64), .MAX_EXP(64)) dut_abp (
        .clk(sys_clk), .ce(ce),
        .op(abp_op),
        .frac_width(abp_frac_w),
        .exp_width(abp_exp_w),
        .a_frac(abp_a_frac), .a_exp(abp_a_exp),
        .b_frac(abp_b_frac), .b_exp(abp_b_exp),
        .result_frac(abp_r_frac), .result_exp(abp_r_exp)
    );

    wire [31:0] mul_fold = abp_r_frac[63:32] ^ abp_r_frac[31:0]
                         ^ abp_r_exp[63:32]  ^ abp_r_exp[31:0];

`elsif DUT_SPIRIX_BASIC
    // ----- Spirix ALU basic (combinational + output reg, 5 ops, 64-bit datapath) -----
    // NEG/ABS/SIGN/SHL/SHR with full edge case handling.

    wire signed [63:0] ba_a_frac = lfsr[63:0];
    wire signed [63:0] ba_a_exp  = lfsr2[63:0];
    wire signed [63:0] ba_b_frac = {lfsr[31:0], lfsr2[31:0]};
    wire signed [63:0] ba_b_exp  = {lfsr2[31:0], lfsr[31:0]};

    // Map lfsr2 bits to valid op range 0..4 (5 ops)
    wire [2:0] ba_raw_op = lfsr2[34:32];
    wire [2:0] ba_op = (ba_raw_op > 3'd4) ? 3'd0 : ba_raw_op;

    wire [1:0] ba_frac_w = combo_actual[1:0];
    wire [1:0] ba_exp_w  = combo_actual[3:2];

    wire signed [63:0] ba_r_frac_comb, ba_r_exp_comb;

    spirix_alu_basic #(.MAX_FRAC(64), .MAX_EXP(64)) dut_ba (
        .op(ba_op),
        .frac_width(ba_frac_w),
        .exp_width(ba_exp_w),
        .a_frac(ba_a_frac), .a_exp(ba_a_exp),
        .b_frac(ba_b_frac), .b_exp(ba_b_exp),
        .result_frac(ba_r_frac_comb), .result_exp(ba_r_exp_comb)
    );

    // Output register (CE-gated)
    reg signed [63:0] ba_r_frac, ba_r_exp;
    always @(posedge sys_clk) if (ce) begin
        ba_r_frac <= ba_r_frac_comb;
        ba_r_exp  <= ba_r_exp_comb;
    end

    wire [31:0] mul_fold = ba_r_frac[63:32] ^ ba_r_frac[31:0]
                         ^ ba_r_exp[63:32]  ^ ba_r_exp[31:0];

`elsif DUT_SPIRIX_MINMAX
    // ----- Spirix ALU minmax (combinational + output reg, 2 ops, 64-bit datapath) -----
    // MIN/MAX with full edge case handling.

    wire signed [63:0] mm_a_frac = lfsr[63:0];
    wire signed [63:0] mm_a_exp  = lfsr2[63:0];
    wire signed [63:0] mm_b_frac = {lfsr[31:0], lfsr2[31:0]};
    wire signed [63:0] mm_b_exp  = {lfsr2[31:0], lfsr[31:0]};

    // 1-bit op from LFSR: 0=MIN, 1=MAX
    wire mm_op = lfsr2[32];

    wire [1:0] mm_frac_w = combo_actual[1:0];
    wire [1:0] mm_exp_w  = combo_actual[3:2];

    wire signed [63:0] mm_r_frac_comb, mm_r_exp_comb;

    spirix_alu_minmax #(.MAX_FRAC(64), .MAX_EXP(64)) dut_mm (
        .op(mm_op),
        .frac_width(mm_frac_w),
        .exp_width(mm_exp_w),
        .a_frac(mm_a_frac), .a_exp(mm_a_exp),
        .b_frac(mm_b_frac), .b_exp(mm_b_exp),
        .result_frac(mm_r_frac_comb), .result_exp(mm_r_exp_comb)
    );

    // Output register (CE-gated)
    reg signed [63:0] mm_r_frac, mm_r_exp;
    always @(posedge sys_clk) if (ce) begin
        mm_r_frac <= mm_r_frac_comb;
        mm_r_exp  <= mm_r_exp_comb;
    end

    wire [31:0] mul_fold = mm_r_frac[63:32] ^ mm_r_frac[31:0]
                         ^ mm_r_exp[63:32]  ^ mm_r_exp[31:0];

`elsif DUT_SPIRIX_ROUND
    // ----- Spirix ALU round (combinational + output reg, 3 ops, 64-bit datapath) -----
    // FLOOR/CEIL/ROUND (FRAC moved to addbit_pipe).

    wire signed [63:0] rd_a_frac = lfsr[63:0];
    wire signed [63:0] rd_a_exp  = lfsr2[63:0];

    // 2-bit op from LFSR: 00=FLOOR, 01=CEIL, 10=ROUND (11 wraps to 00)
    wire [1:0] rd_raw_op = lfsr2[33:32];
    wire [1:0] rd_op = (rd_raw_op == 2'd3) ? 2'd0 : rd_raw_op;

    wire [1:0] rd_frac_w = combo_actual[1:0];
    wire [1:0] rd_exp_w  = combo_actual[3:2];

    wire signed [63:0] rd_r_frac_comb, rd_r_exp_comb;

    spirix_alu_round #(.MAX_FRAC(64), .MAX_EXP(64)) dut_rd (
        .op(rd_op),
        .frac_width(rd_frac_w),
        .exp_width(rd_exp_w),
        .a_frac(rd_a_frac), .a_exp(rd_a_exp),
        .result_frac(rd_r_frac_comb), .result_exp(rd_r_exp_comb)
    );

    // Output register (CE-gated)
    reg signed [63:0] rd_r_frac, rd_r_exp;
    always @(posedge sys_clk) if (ce) begin
        rd_r_frac <= rd_r_frac_comb;
        rd_r_exp  <= rd_r_exp_comb;
    end

    wire [31:0] mul_fold = rd_r_frac[63:32] ^ rd_r_frac[31:0]
                         ^ rd_r_exp[63:32]  ^ rd_r_exp[31:0];

`elsif DUT_SPIRIX_MUL_OPS
    // ----- Spirix ALU multiply (combinational, multi-width, 64-bit) -----
    wire signed [63:0] mo_a_frac = lfsr[63:0];
    wire signed [63:0] mo_a_exp  = lfsr2[63:0];
    wire signed [63:0] mo_b_frac = {lfsr2[31:0], lfsr[63:32]};
    wire signed [63:0] mo_b_exp  = {lfsr[31:0], lfsr2[63:32]};

    wire [1:0] mo_frac_w = combo_actual[1:0];
    wire [1:0] mo_exp_w  = combo_actual[3:2];

    wire signed [63:0] mo_r_frac_comb, mo_r_exp_comb;

    spirix_alu_multiply #(.MAX_FRAC(64), .MAX_EXP(64)) dut_mo (
        .frac_width(mo_frac_w), .exp_width(mo_exp_w),
        .a_frac(mo_a_frac), .a_exp(mo_a_exp),
        .b_frac(mo_b_frac), .b_exp(mo_b_exp),
        .result_frac(mo_r_frac_comb), .result_exp(mo_r_exp_comb)
    );

    // Output register (CE-gated) — combinational DUT, 1 output reg
    reg signed [63:0] mo_r_frac, mo_r_exp;
    always @(posedge sys_clk) if (ce) begin
        mo_r_frac <= mo_r_frac_comb;
        mo_r_exp  <= mo_r_exp_comb;
    end

    wire [31:0] mul_fold = mo_r_frac[63:32] ^ mo_r_frac[31:0]
                         ^ mo_r_exp[63:32]  ^ mo_r_exp[31:0];

`elsif DUT_SPIRIX_MUL_OPS_PIPE
    // ----- Spirix ALU multiply (2-stage pipe, multi-width, 64-bit) -----
    wire signed [63:0] mp_a_frac = lfsr[63:0];
    wire signed [63:0] mp_a_exp  = lfsr2[63:0];
    wire signed [63:0] mp_b_frac = {lfsr2[31:0], lfsr[63:32]};
    wire signed [63:0] mp_b_exp  = {lfsr[31:0], lfsr2[63:32]};

    wire [1:0] mp_frac_w = combo_actual[1:0];
    wire [1:0] mp_exp_w  = combo_actual[3:2];

    wire signed [63:0] mp_r_frac, mp_r_exp;

    spirix_alu_multiply_pipe #(.MAX_FRAC(64), .MAX_EXP(64)) dut_mp (
        .clk(sys_clk), .ce(ce),
        .frac_width(mp_frac_w), .exp_width(mp_exp_w),
        .a_frac(mp_a_frac), .a_exp(mp_a_exp),
        .b_frac(mp_b_frac), .b_exp(mp_b_exp),
        .result_frac(mp_r_frac), .result_exp(mp_r_exp)
    );

    wire [31:0] mul_fold = mp_r_frac[63:32] ^ mp_r_frac[31:0]
                         ^ mp_r_exp[63:32]  ^ mp_r_exp[31:0];

`elsif DUT_SPIRIX_DIVSQRT
    // ----- Spirix ALU divsqrt (iterative, multi-width, 64-bit, 0 DSP) -----
    wire signed [63:0] ds_a_frac = lfsr[63:0];
    wire signed [63:0] ds_a_exp  = lfsr2[63:0];
    wire signed [63:0] ds_b_frac = {lfsr2[31:0], lfsr[63:32]};
    wire signed [63:0] ds_b_exp  = {lfsr[31:0], lfsr2[63:32]};

    wire [1:0] ds_frac_w = combo_actual[1:0];
    wire [1:0] ds_exp_w  = combo_actual[3:2];
    wire [1:0] ds_op     = lfsr[1:0];  // 0=DIV, 1=SQRT, 2=MOD (random per vector)

    wire signed [63:0] ds_r_frac, ds_r_exp;
    wire ds_busy_w, ds_done_w;

    reg ds_iter_busy = 0;
    reg ds_iter_start = 0;
    always @(posedge sys_clk) begin
        ds_iter_start <= 0;
        // Block ds_iter_start during PH_IDLE/PH_SWITCH (parity with other iterative DUTs).
        if (btn_held_sys || !por_done || phase == PH_IDLE || phase == PH_SWITCH)
            ds_iter_busy <= 0;
        else if (ce && !ds_iter_busy && !ds_busy_w)
            begin ds_iter_start <= 1; ds_iter_busy <= 1; end
        else if (ds_done_w)
            ds_iter_busy <= 0;
    end

    spirix_alu_divmodsqrt #(.MAX_FRAC(64), .MAX_EXP(64)) dut_ds (
        .clk(sys_clk), .start(ds_iter_start), .op(ds_op),
        .frac_width(ds_frac_w), .exp_width(ds_exp_w),
        .a_frac(ds_a_frac), .a_exp(ds_a_exp),
        .b_frac(ds_b_frac), .b_exp(ds_b_exp),
        .result_frac(ds_r_frac), .result_exp(ds_r_exp),
        .busy(ds_busy_w), .done(ds_done_w)
    );

    wire [31:0] mul_fold = ds_r_frac[63:32] ^ ds_r_frac[31:0]
                         ^ ds_r_exp[63:32]  ^ ds_r_exp[31:0];
    wire dut_advance = ds_done_w;
`define DUT_ITER_ADVANCE

`elsif DUT_SPIRIX_CORE
    // ----- Spirix Core (register machine, 21 ops, variable latency) -----
    // Sequencer: load R0+R1 from LFSR → exec random instruction → wait done → read R2
    //
    // States: LOAD0 → LOAD1 → EXEC → WAIT → READ → advance LFSR
    localparam [2:0] CS_IDLE = 3'd0, CS_LOAD0 = 3'd1, CS_LOAD1 = 3'd2,
                     CS_EXEC = 3'd3, CS_WAIT  = 3'd4, CS_READ  = 3'd5;
    reg [2:0] core_state = CS_IDLE;

    // Instruction from LFSR: random opcode 0..19 (skip RNG — TRNG is non-deterministic,
    // gold/test phases would get different random values and never match)
    wire [4:0] raw_opcode = lfsr2[36:32];
    wire [4:0] sc_opcode = (raw_opcode >= 5'd20) ? (raw_opcode - 5'd20) : raw_opcode;
    wire [17:0] sc_instr = {sc_opcode, 3'd0, 3'd1, 3'd2, combo_actual[1:0], combo_actual[3:2]};

    wire signed [63:0] sc_rfrac, sc_rexp;
    wire sc_busy, sc_done;
    reg  sc_exec = 0;
    reg  [2:0]  sc_ext_addr = 0;
    reg  signed [63:0] sc_ext_wfrac = 0, sc_ext_wexp = 0;
    reg  sc_ext_we = 0;

    spirix_core #(.MAX_FRAC(64), .MAX_EXP(64)) dut_core (
        .clk(sys_clk), .rst(btn_held_sys || !por_done),
        .instr(sc_instr), .exec(sc_exec),
        .busy(sc_busy), .done(sc_done),
        .ext_addr(sc_ext_addr),
        .ext_wfrac(sc_ext_wfrac), .ext_wexp(sc_ext_wexp),
        .ext_we(sc_ext_we),
        .ext_rfrac(sc_rfrac), .ext_rexp(sc_rexp)
    );

    reg sc_iter_done = 0;
    reg signed [63:0] sc_result_frac = 0, sc_result_exp = 0;

    always @(posedge sys_clk) begin
        sc_exec   <= 0;
        sc_ext_we <= 0;
        sc_iter_done <= 0;

        if (btn_held_sys || !por_done) begin
            core_state <= CS_IDLE;
        end else case (core_state)
            CS_IDLE: begin
                if (ce && !sc_busy && !sc_iter_done) begin
                    // Load R0 frac/exp from LFSR (guard: !sc_iter_done prevents
                    // loading from pre-advance LFSR when dut_advance fires same cycle)
                    sc_ext_addr  <= 3'd0;
                    sc_ext_wfrac <= lfsr[63:0];
                    sc_ext_wexp  <= lfsr2[63:0];
                    sc_ext_we    <= 1;
                    core_state   <= CS_LOAD0;
                end
            end
            CS_LOAD0: begin
                // Load R1 frac/exp from LFSR (swizzled)
                sc_ext_addr  <= 3'd1;
                sc_ext_wfrac <= {lfsr2[31:0], lfsr[63:32]};
                sc_ext_wexp  <= {lfsr[31:0], lfsr2[63:32]};
                sc_ext_we    <= 1;
                core_state   <= CS_LOAD1;
            end
            CS_LOAD1: begin
                // Issue instruction (exec pulse)
                sc_exec    <= 1;
                core_state <= CS_EXEC;
            end
            CS_EXEC: begin
                // Wait one cycle for exec to be accepted
                core_state <= CS_WAIT;
            end
            CS_WAIT: begin
                if (sc_done) begin
                    // Read R2 result
                    sc_ext_addr <= 3'd2;
                    core_state  <= CS_READ;
                end
            end
            CS_READ: begin
                // Capture result (async read valid this cycle)
                sc_result_frac <= sc_rfrac;
                sc_result_exp  <= sc_rexp;
                sc_iter_done   <= 1;
                core_state     <= CS_IDLE;
            end
        endcase
    end

    wire [31:0] mul_fold = sc_result_frac[63:32] ^ sc_result_frac[31:0]
                         ^ sc_result_exp[63:32]  ^ sc_result_exp[31:0];
    wire dut_advance = sc_iter_done;
`define DUT_ITER_ADVANCE

`else
    // ----- Spirix FMA (default) -----
    wire signed [24:0] fma_a_frac = lfsr[24:0];
    wire signed  [7:0] fma_a_exp  = lfsr[32:25];
    wire signed [24:0] fma_b_frac = lfsr[57:33];
    wire signed  [7:0] fma_b_exp  = {lfsr[63], lfsr[63], lfsr[63:58]};
    wire signed [24:0] fma_c_frac = lfsr2[24:0];
    wire signed  [7:0] fma_c_exp  = lfsr2[32:25];
    wire               fma_sub    = lfsr[0];

    wire signed [24:0] fma_r_frac;
    wire signed  [7:0] fma_r_exp;

    spirix_fma #(.FRAC_BITS(25), .EXP_BITS(8)) dut_fma (
        .a_frac(fma_a_frac), .a_exp(fma_a_exp),
        .b_frac(fma_b_frac), .b_exp(fma_b_exp),
        .c_frac(fma_c_frac), .c_exp(fma_c_exp),
        .sub(fma_sub),
        .result_frac(fma_r_frac), .result_exp(fma_r_exp)
    );

    reg signed [24:0] fma_r_frac_r;
    reg signed  [7:0] fma_r_exp_r;
    always @(posedge sys_clk) if (ce) begin
        fma_r_frac_r <= fma_r_frac;
        fma_r_exp_r  <= fma_r_exp;
    end

    wire [32:0] fma_out = {fma_r_exp_r, fma_r_frac_r};
    wire [31:0] mul_fold = fma_out[31:0] ^ {31'b0, fma_out[32]};
`endif

`ifndef DUT_ITER_ADVANCE
    wire dut_advance = ce;
`endif

    // =========================================================================
    // Protocol counter + accumulator + phase FSM
    // =========================================================================

    // Split counter: registered carry between halves to break 18-bit carry chain.
    // Each half is 9 bits (4-5 CCU2C stages), ~1ns carry — good to 500+ MHz.
    reg [8:0] proto_lo;
    reg [8:0] proto_hi;
    reg       proto_carry;  // registered carry from lo to hi
    wire       proto_done = proto_hi[8];             // bit tap: done at 131072
    wire       accumulating = proto_hi[6] & ~proto_done;  // bit tap: accum from 32768..131071
    reg [31:0] accum;
    reg [31:0] gold_reg = 0, test_reg = 0;
    reg        test_done_sys = 0;

    always @(posedge sys_clk) begin
        if (!pll_lock || !por_done) begin
            // Hard reset (PLL not locked or POR)
            phase          <= PH_IDLE;
            lfsr           <= LFSR_SEED;
            lfsr2          <= LFSR_SEED2;
            captured_seed  <= LFSR_SEED;
            captured_seed2 <= LFSR_SEED2;
            proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
            accum          <= 0;
            gold_reg       <= 0;
            test_reg       <= 0;
            test_done_sys  <= 0;
`ifdef DUT_MULTI_COMBO
            combo          <= 0;
            combo_mask     <= 0;
            combo_results  <= 0;
            combo_tested   <= 0;
`endif
        end else if (btn_held_sys) begin
            // Button held: reset to idle, LFSR free-runs for entropy
            phase         <= PH_IDLE;
            proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
            accum         <= 0;
            gold_reg      <= 0;
            test_reg      <= 0;
            test_done_sys <= 0;
`ifdef DUT_MULTI_COMBO
            combo         <= 0;
            combo_mask     <= 0;
            combo_results <= 0;
            combo_tested  <= 0;
`endif
            lfsr          <= lfsr_next;
            lfsr2         <= lfsr2_next;
        end else begin

            // =================================================================
            // Phase transitions
            // =================================================================
            case (phase)
                PH_IDLE: begin
                    // Button just released (or first run after POR):
                    // XOR entropy counter into LFSR for unique seed each run
                    captured_seed  <= lfsr ^ entropy;
                    captured_seed2 <= lfsr2 ^ entropy;
                    lfsr           <= lfsr ^ entropy;
                    lfsr2          <= lfsr2 ^ entropy;
                    proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
                    accum          <= 0;
`ifdef DUT_MULTI_COMBO
                    // Capture shuffle mask on first combo only
                    if (combo == 0)
                        combo_mask <= entropy[3:0];
`endif
                    phase          <= PH_GOLD;
                end
                PH_GOLD: begin
                    if (proto_done) begin
                        gold_reg <= accum;
                        phase    <= PH_SWITCH;
                    end
                end
                PH_SWITCH: begin
                    // Reset LFSR to captured seed for test phase
                    lfsr           <= captured_seed;
                    lfsr2          <= captured_seed2;
                    proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
                    accum          <= 0;
                    phase          <= PH_TEST;
                end
                PH_TEST: begin
                    if (proto_done) begin
                        test_reg      <= accum;
                        test_done_sys <= 1;
                        phase         <= PH_DONE;
                    end
                end
                PH_DONE: begin
`ifdef DUT_MULTI_COMBO
                    // Record pass/fail + tested for this width combo, advance to next
                    combo_results <= combo_results | ({15'b0, (gold_reg == test_reg)} << combo_actual);
                    combo_tested  <= combo_tested  | (16'b1 << combo_actual);
                    if (combo != 4'd15) begin
                        combo         <= combo + 1;
                        test_done_sys <= 0;
                        proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
                        accum         <= 0;
                        gold_reg      <= 0;
                        test_reg      <= 0;
                        phase         <= PH_IDLE;
                    end
`else
                    // Continuous-run mode: restart for live pass/fail flicker on
                    // marginal frequencies. test_done_sys stays high until next test
                    // captures, so display reflects the most recent comparison.
                    proto_lo <= 0; proto_hi <= 0; proto_carry <= 0;
                    accum    <= 0;
                    phase    <= PH_IDLE;
`endif
                end
            endcase

            // =================================================================
            // CE-gated datapath (gold & test phases only)
            // =================================================================
            if (dut_advance && (phase == PH_GOLD || phase == PH_TEST)) begin
                lfsr  <= lfsr_next;
                lfsr2 <= lfsr2_next;
                if (accumulating)
                    accum <= {accum[30:0], accum[31]} ^ mul_fold;

                if (!proto_done) begin
                    proto_lo    <= proto_lo + 1;
                    proto_carry <= &proto_lo;  // all-ones = about to wrap
                    proto_hi    <= proto_hi + {8'b0, proto_carry};
                end
            end
        end
    end

    // =========================================================================
    // Button sync (no debounce — bouncing just re-runs the test, more entropy)
    // =========================================================================
    reg [1:0] btn_sync_sys = 2'b11;
    always @(posedge sys_clk) btn_sync_sys <= {btn_sync_sys[0], btn};
    wire btn_held_sys = ~btn_sync_sys[1];  // 1 when button held (sys_clk domain)

    // =========================================================================
    // CDC: test_done_sys → clk domain
    // =========================================================================
    reg done_sync1 = 0, done_sync2 = 0;
    always @(posedge clk) begin
        done_sync1 <= test_done_sys;
        done_sync2 <= done_sync1;
    end

    reg lock_sync1 = 0, lock_sync2 = 0;
    always @(posedge clk) begin
        lock_sync1 <= pll_lock;
        lock_sync2 <= lock_sync1;
    end

    // =========================================================================
    // Status (clk domain)
    // =========================================================================
`ifdef DUT_MULTI_COMBO
    wire pass = &combo_results;  // all 16 combos must pass
`else
    wire pass = (gold_reg == test_reg);
`endif
    wire [1:0] status = !lock_sync2  ? 2'd2 :
                        !done_sync2  ? 2'd0 :
                        pass         ? 2'd1 : 2'd2;

    // =========================================================================
    // LEDs:
    //   led (T6): geiger random toggle, driven from the test-domain lfsr —
    //     intentionally freezes if the test FSM hangs, so a stuck blinkey is
    //     a real failure signal (don't mask it with a free-running LFSR).
    //   ext_led (T2): latched pass/fail (assigned below).
    // =========================================================================
    reg [14:0] geiger_cnt = 0;
    always @(posedge clk) begin
        geiger_cnt <= geiger_cnt + 1;
        if (&geiger_cnt) begin
            if (led && lfsr[7:0] < 8'd8)
                led <= 1'b0;
            else if (!led && lfsr[7:0] < 8'd100)
                led <= 1'b1;
        end
    end

    // Keypad LED: LIVE XOR comparison — bright when (gold_reg ^ test_reg) is
    // all zeros (passing), dark when any bit is set. Reflects current state
    // rather than the last PH_DONE latch, so the LED naturally flickers
    // through the bench cycle: bright in PH_IDLE/PH_GOLD (both regs 0), dark
    // through PH_SWITCH/PH_TEST (gold latched non-zero, test still 0), then
    // bright again at PH_DONE if timing closed (test == gold).
    assign ext_led = (gold_reg == test_reg);

    // =========================================================================
    // NTSC display (clk domain = 25 MHz)
    // =========================================================================
`ifndef NO_NTSC
    wire ntsc_sync_w, ntsc_vid_w;

    ntsc_framebuf #(
        .FB_W    (320),
        .FB_H    (240),
        .H_SCALE (4)
    ) ntsc (
        .clk       (clk),
        .status    (status),
        .hash      (test_done_sys ? gold_reg : lfsr[31:0]),
        .hash2     (test_done_sys ? test_reg : lfsr[63:32]),
        .sync_pin  (ntsc_sync_w),
        .video_pin (ntsc_vid_w)
    );

    always @(posedge clk) begin
        ntsc_sync <= ntsc_sync_w;
        ntsc_vid  <= ntsc_vid_w;
    end
`else
    always @(posedge clk) begin
        ntsc_sync <= 0;
        ntsc_vid  <= 0;
    end
`endif

    // =========================================================================
    // OLED display (25 MHz clk domain, I2C)
    // =========================================================================
`ifdef DUT_MULTI_COMBO
    // 1-bpp overlay grid for unified-ALU width sweep (kept on the simple driver).
    reg [127:0] oled_r0, oled_r1, oled_r2, oled_r3;
    reg [15:0]  oled_gate;
    always @(posedge clk) begin
        oled_gate <= combo_tested;
        oled_r0 <= {{32{combo_results[ 3]}}, {32{combo_results[ 2]}},
                    {32{combo_results[ 1]}}, {32{combo_results[ 0]}}};
        oled_r1 <= {{32{combo_results[ 7]}}, {32{combo_results[ 6]}},
                    {32{combo_results[ 5]}}, {32{combo_results[ 4]}}};
        oled_r2 <= {{32{combo_results[11]}}, {32{combo_results[10]}},
                    {32{combo_results[ 9]}}, {32{combo_results[ 8]}}};
        oled_r3 <= {{32{combo_results[15]}}, {32{combo_results[14]}},
                    {32{combo_results[13]}}, {32{combo_results[12]}}};
    end
    ssd1306_oled #(.OVERLAY_FILE("build/oled_overlay.mem"), .ENABLE_OVERLAY(1)) oled (
        .clk(clk), .rst(~pll_lock),
        .reg0(oled_r0), .reg1(oled_r1), .reg2(oled_r2), .reg3(oled_r3),
        .overlay_gate(oled_gate),
        .scl(oled_scl), .sda(oled_sda)
    );
`else
    // Greyscale framebuffer + temporal dither (ported from top_extclk.v).
    // 4 bands × 32 cells × 4-px-wide bit cells, even/odd brightness pairs.
    //   Band 0 (rows  0..15): mul_fold (live DUT output)
    //   Band 1 (rows 16..31): gold_reg (slow-CE accumulated hash)
    //   Band 2 (rows 32..47): test_reg (full-speed accumulated hash)
    //   Band 3 (rows 48..63): gold_reg ^ test_reg (mismatch pattern — lit = fail)

    // CDC sys_clk → clk (rare-update regs, 2-FF sync safe).
    reg [31:0] gold_sync1 = 0, gold_sync2 = 0;
    reg [31:0] test_sync1 = 0, test_sync2 = 0;
    reg [31:0] mul_sync1  = 0, mul_sync2  = 0;
    always @(posedge clk) begin
        gold_sync1 <= gold_reg; gold_sync2 <= gold_sync1;
        test_sync1 <= test_reg; test_sync2 <= test_sync1;
        mul_sync1  <= mul_fold; mul_sync2  <= mul_sync1;
    end
    wire [31:0] display_mul_live  = mul_sync2;
    wire [31:0] display_gold_live = gold_sync2;
    wire [31:0] display_test_live = test_sync2;

    // Latch display values at OLED frame boundary (page wrap 7→0). Without this,
    // mul_fold updates every clk cycle and band 0 fills with horizontal streaks
    // since the framebuffer writer races the OLED reader. One snapshot per
    // ~30 Hz frame → coherent bitmap.
    reg [31:0] display_mul  = 0;
    reg [31:0] display_gold = 0;
    reg [31:0] display_test = 0;
    wire [31:0] display_miss = display_gold ^ display_test;

    // 32-bit Galois LFSR for per-pixel temporal dither.
    reg [31:0] dith_lfsr = 32'hCAFE_BABE;
    always @(posedge clk)
        dith_lfsr <= {dith_lfsr[0], dith_lfsr[31:1]} ^ ({32{dith_lfsr[0]}} & 32'h80200003);
    wire [7:0] dither = dith_lfsr[7:0];

    // 8bpp framebuffer (128 × 64), continuous walk-and-write at 25 MHz.
    reg [7:0]  fb [0:8191];
    reg [12:0] fb_wr_addr = 0;
    wire [6:0] wr_col = fb_wr_addr[6:0];
    wire [5:0] wr_row = fb_wr_addr[12:7];

    wire in_band0 = (wr_row < 6'd16);
    wire in_band1 = (wr_row >= 6'd16) && (wr_row < 6'd32);
    wire in_band2 = (wr_row >= 6'd32) && (wr_row < 6'd48);
    // band3: wr_row >= 48 (implicit else)

    wire [4:0]  bit_idx     = wr_col[6:2];     // 0..31
    wire        bit_pos_odd = bit_idx[0];
    wire [31:0] band_value  = in_band0 ? display_mul  :
                              in_band1 ? display_gold :
                              in_band2 ? display_test :
                                         display_miss;
    wire        bit_value   = band_value[5'd31 - bit_idx];   // MSB on left
    wire [7:0]  bit_pixel   = bit_pos_odd ? (bit_value ? 8'd255 : 8'd32)
                                          : (bit_value ? 8'd191 : 8'd0);

`ifdef RING_STAGES
    // Top band (rows 0..15) renders 8 BCD digit slots: 4 digits + '.' + 3 digits
    // = 96 px wide, centered cols 16..112. Layout: NNN.NNN MHz with leading-zero
    // suppression on the first 3 integer-position digits.
    localparam integer FC_DIGIT_AREA_START = 16;
    localparam integer FC_DIGIT_AREA_END   = 16 + 8 * 12;  // 112
    wire fc_in_digit_area = (wr_col >= FC_DIGIT_AREA_START[6:0])
                         && (wr_col < FC_DIGIT_AREA_END[6:0]);
    wire [6:0] fc_rel_col = wr_col - FC_DIGIT_AREA_START[6:0];

    reg [2:0] fc_freq_pos;
    reg [3:0] fc_gx_in_cell;
    always @(*) begin
        if      (fc_rel_col < 7'd12) begin fc_freq_pos = 3'd0; fc_gx_in_cell = fc_rel_col[3:0]; end
        else if (fc_rel_col < 7'd24) begin fc_freq_pos = 3'd1; fc_gx_in_cell = (fc_rel_col - 7'd12); end
        else if (fc_rel_col < 7'd36) begin fc_freq_pos = 3'd2; fc_gx_in_cell = (fc_rel_col - 7'd24); end
        else if (fc_rel_col < 7'd48) begin fc_freq_pos = 3'd3; fc_gx_in_cell = (fc_rel_col - 7'd36); end
        else if (fc_rel_col < 7'd60) begin fc_freq_pos = 3'd4; fc_gx_in_cell = (fc_rel_col - 7'd48); end
        else if (fc_rel_col < 7'd72) begin fc_freq_pos = 3'd5; fc_gx_in_cell = (fc_rel_col - 7'd60); end
        else if (fc_rel_col < 7'd84) begin fc_freq_pos = 3'd6; fc_gx_in_cell = (fc_rel_col - 7'd72); end
        else                          begin fc_freq_pos = 3'd7; fc_gx_in_cell = (fc_rel_col - 7'd84); end
    end
    wire [3:0] fc_gy = wr_row[3:0];

    wire fc_suppress_p0 = (display_bcd[27:24] == 4'd0);
    wire fc_suppress_p1 = fc_suppress_p0 && (display_bcd[23:20] == 4'd0);
    wire fc_suppress_p2 = fc_suppress_p1 && (display_bcd[19:16] == 4'd0);

    reg [3:0] fc_freq_slot;
    reg       fc_freq_slot_valid;
    always @(*) begin
        case (fc_freq_pos)
            3'd0: begin fc_freq_slot = display_bcd[27:24]; fc_freq_slot_valid = !fc_suppress_p0; end
            3'd1: begin fc_freq_slot = display_bcd[23:20]; fc_freq_slot_valid = !fc_suppress_p1; end
            3'd2: begin fc_freq_slot = display_bcd[19:16]; fc_freq_slot_valid = !fc_suppress_p2; end
            3'd3: begin fc_freq_slot = display_bcd[15:12]; fc_freq_slot_valid = 1'b1; end
            3'd4: begin fc_freq_slot = 4'd10;              fc_freq_slot_valid = 1'b1; end // '.'
            3'd5: begin fc_freq_slot = display_bcd[11: 8]; fc_freq_slot_valid = 1'b1; end
            3'd6: begin fc_freq_slot = display_bcd[ 7: 4]; fc_freq_slot_valid = 1'b1; end
            3'd7: begin fc_freq_slot = display_bcd[ 3: 0]; fc_freq_slot_valid = 1'b1; end
        endcase
    end

    reg [11:0] fc_slot_offset;
    always @(*) begin
        case (fc_freq_slot)
            4'd0:  fc_slot_offset = 12'd0;
            4'd1:  fc_slot_offset = 12'd192;
            4'd2:  fc_slot_offset = 12'd384;
            4'd3:  fc_slot_offset = 12'd576;
            4'd4:  fc_slot_offset = 12'd768;
            4'd5:  fc_slot_offset = 12'd960;
            4'd6:  fc_slot_offset = 12'd1152;
            4'd7:  fc_slot_offset = 12'd1344;
            4'd8:  fc_slot_offset = 12'd1536;
            4'd9:  fc_slot_offset = 12'd1728;
            4'd10: fc_slot_offset = 12'd1920;
            default: fc_slot_offset = 12'd0;
        endcase
    end
    wire [7:0]  fc_gy_x12     = ({4'd0, fc_gy} << 3) + ({4'd0, fc_gy} << 2);
    wire [11:0] fc_glyph_addr = fc_slot_offset + {4'd0, fc_gy_x12} + {8'd0, fc_gx_in_cell};
    wire [7:0]  fc_glyph_pixel = glyph_rom[fc_glyph_addr];
    wire [7:0]  fc_freq_pixel  = (in_band0 && fc_in_digit_area && fc_freq_slot_valid)
                                 ? fc_glyph_pixel : 8'h00;

    wire [7:0] fb_wr_pixel = in_band0 ? fc_freq_pixel : bit_pixel;
`else
    wire [7:0] fb_wr_pixel = bit_pixel;
`endif

    always @(posedge clk) begin
        fb[fb_wr_addr] <= fb_wr_pixel;
        fb_wr_addr     <= fb_wr_addr + 1;
    end

    // I2C clock-enable (one ce pulse per CLK_DIV ref cycles).
    // CLK_DIV=7 matches working top_extclk.v setting (25 MHz/7 ≈ 3.57 MHz SCL — well above spec).
    localparam OLED_CLK_DIV = 7;
    reg [$clog2(OLED_CLK_DIV)-1:0] oled_cnt = 0;
    wire oled_at_top = (oled_cnt == OLED_CLK_DIV - 1);
    always @(posedge clk) oled_cnt <= oled_at_top ? 0 : oled_cnt + 1;
    reg oled_ce = 0;
    always @(posedge clk) oled_ce <= oled_at_top;

    reg  [7:0] i2c_data;
    reg        i2c_start;
    reg        i2c_send_stop;
    wire       i2c_busy;

    ssd1306_i2c #(.CLK_DIV(OLED_CLK_DIV)) i2c (
        .clk(clk), .rst(~pll_lock),
        .data(i2c_data),
        .start(i2c_start),
        .send_start(1'b0),
        .send_stop(i2c_send_stop),
        .busy(i2c_busy),
        .scl(oled_scl), .sda(oled_sda)
    );

    localparam OLED_I2C_ADDR    = 8'h78;
    localparam OLED_CMD_PREFIX  = 8'h00;
    localparam OLED_DATA_PREFIX = 8'h40;
    localparam OLED_INIT_LEN    = 25;
    reg [7:0] oled_init_cmds [0:OLED_INIT_LEN-1];
    initial begin
        oled_init_cmds[ 0] = 8'hAE; oled_init_cmds[ 1] = 8'hD5;
        oled_init_cmds[ 2] = 8'h80; oled_init_cmds[ 3] = 8'hA8;
        oled_init_cmds[ 4] = 8'h3F; oled_init_cmds[ 5] = 8'hD3;
        oled_init_cmds[ 6] = 8'h00; oled_init_cmds[ 7] = 8'h40;
        oled_init_cmds[ 8] = 8'h8D; oled_init_cmds[ 9] = 8'h14;
        oled_init_cmds[10] = 8'hAD; oled_init_cmds[11] = 8'h8B;
        oled_init_cmds[12] = 8'hA1; oled_init_cmds[13] = 8'hC8;
        oled_init_cmds[14] = 8'hDA; oled_init_cmds[15] = 8'h12;
        oled_init_cmds[16] = 8'h81; oled_init_cmds[17] = 8'hCF;
        oled_init_cmds[18] = 8'hD9; oled_init_cmds[19] = 8'hF1;
        oled_init_cmds[20] = 8'hDB; oled_init_cmds[21] = 8'h40;
        oled_init_cmds[22] = 8'hA4; oled_init_cmds[23] = 8'hA6;
        oled_init_cmds[24] = 8'hAF;
    end

    localparam [2:0]
        OST_RESET   = 3'd0, OST_SEND    = 3'd1, OST_WAIT    = 3'd2,
        OST_NEXT    = 3'd3, OST_BUSFREE = 3'd4, OST_GATHER  = 3'd5;
    localparam [1:0]
        OPH_INIT      = 2'd0, OPH_PAGE_CMD  = 2'd1, OPH_PAGE_DATA = 2'd2;

    reg [2:0]  oled_state       = OST_RESET;
    reg [1:0]  oled_phase       = OPH_INIT;
    reg [19:0] oled_reset_cnt   = 0;
    reg [9:0]  oled_busfree_cnt = 0;
    reg [4:0]  oled_cmd_idx     = 0;
    reg [2:0]  oled_page        = 0;
    reg [2:0]  oled_page_prev   = 0;
    reg [6:0]  oled_col         = 0;
    reg [7:0]  oled_px_byte     = 0;
    reg [3:0]  oled_gather_cnt  = 0;
    reg [7:0]  oled_fb_dout     = 0;

    // Frame-start strobe: pulse on page wrap 7→0 (start of new OLED refresh).
    wire oled_frame_start = (oled_page == 3'd0) && (oled_page_prev == 3'd7);
    always @(posedge clk) if (oled_ce) oled_page_prev <= oled_page;

    always @(posedge clk) if (oled_frame_start) begin
        display_mul  <= display_mul_live;
        display_gold <= display_gold_live;
        display_test <= display_test_live;
    end

    always @(posedge clk) if (oled_ce) begin
        oled_fb_dout <= fb[{oled_page, oled_gather_cnt[2:0], oled_col}];
        i2c_start    <= 0;

        case (oled_state)
            OST_RESET: begin
                oled_reset_cnt <= oled_reset_cnt + 1;
                if (&oled_reset_cnt) begin
                    oled_phase   <= OPH_INIT;
                    oled_cmd_idx <= 0;
                    oled_page    <= 0;
                    oled_col     <= 0;
                    oled_state   <= OST_SEND;
                end
            end
            OST_SEND: begin
                if (!i2c_busy) begin
                    case (oled_phase)
                        OPH_INIT: begin
                            if (oled_cmd_idx == 0) begin
                                i2c_data      <= OLED_I2C_ADDR;
                                i2c_send_stop <= 0;
                            end else if (oled_cmd_idx == 1) begin
                                i2c_data      <= OLED_CMD_PREFIX;
                                i2c_send_stop <= 0;
                            end else begin
                                i2c_data      <= oled_init_cmds[oled_cmd_idx - 2];
                                i2c_send_stop <= (oled_cmd_idx == OLED_INIT_LEN + 1);
                            end
                        end
                        OPH_PAGE_CMD: begin
                            case (oled_cmd_idx[2:0])
                                3'd0: begin i2c_data <= OLED_I2C_ADDR;             i2c_send_stop <= 0; end
                                3'd1: begin i2c_data <= OLED_CMD_PREFIX;           i2c_send_stop <= 0; end
                                3'd2: begin i2c_data <= 8'hB0 | {5'd0, oled_page}; i2c_send_stop <= 0; end
                                3'd3: begin i2c_data <= 8'h02;                     i2c_send_stop <= 0; end
                                3'd4: begin i2c_data <= 8'h10;                     i2c_send_stop <= 1; end
                                default: ;
                            endcase
                        end
                        OPH_PAGE_DATA: begin
                            if (oled_cmd_idx == 0) begin
                                i2c_data      <= OLED_I2C_ADDR;
                                i2c_send_stop <= 0;
                            end else if (oled_cmd_idx == 1) begin
                                i2c_data      <= OLED_DATA_PREFIX;
                                i2c_send_stop <= 0;
                            end else begin
                                i2c_data      <= oled_px_byte;
                                i2c_send_stop <= (oled_col == 7'd127);
                            end
                        end
                    endcase
                    i2c_start  <= 1;
                    oled_state <= OST_WAIT;
                end
            end
            OST_WAIT: begin
                if (i2c_busy) oled_state <= OST_NEXT;
            end
            OST_NEXT: begin
                if (!i2c_busy) begin
                    case (oled_phase)
                        OPH_INIT: begin
                            if (oled_cmd_idx == OLED_INIT_LEN + 1) begin
                                oled_phase   <= OPH_PAGE_CMD;
                                oled_cmd_idx <= 0;
                                oled_page    <= 0;
                                oled_state   <= OST_BUSFREE;
                            end else begin
                                oled_cmd_idx <= oled_cmd_idx + 1;
                                oled_state   <= OST_SEND;
                            end
                        end
                        OPH_PAGE_CMD: begin
                            if (oled_cmd_idx == 4) begin
                                oled_phase      <= OPH_PAGE_DATA;
                                oled_cmd_idx    <= 0;
                                oled_col        <= 0;
                                oled_gather_cnt <= 0;
                                oled_state      <= OST_BUSFREE;
                            end else begin
                                oled_cmd_idx <= oled_cmd_idx + 1;
                                oled_state   <= OST_SEND;
                            end
                        end
                        OPH_PAGE_DATA: begin
                            if (oled_cmd_idx < 2) begin
                                oled_cmd_idx <= oled_cmd_idx + 1;
                                if (oled_cmd_idx == 1) begin
                                    oled_gather_cnt <= 0;
                                    oled_state      <= OST_GATHER;
                                end else begin
                                    oled_state <= OST_SEND;
                                end
                            end else if (oled_col == 7'd127) begin
                                oled_phase   <= OPH_PAGE_CMD;
                                oled_cmd_idx <= 0;
                                oled_page    <= (oled_page == 3'd7) ? 3'd0 : oled_page + 1;
                                oled_state   <= OST_BUSFREE;
                            end else begin
                                oled_col        <= oled_col + 1;
                                oled_gather_cnt <= 0;
                                oled_state      <= OST_GATHER;
                            end
                        end
                    endcase
                end
            end
            OST_BUSFREE: begin
                oled_busfree_cnt <= oled_busfree_cnt + 1;
                if (&oled_busfree_cnt) begin
                    oled_busfree_cnt <= 0;
                    oled_state <= OST_SEND;
                end
            end
            OST_GATHER: begin
                oled_gather_cnt <= oled_gather_cnt + 1;
                if (oled_gather_cnt >= 4'd1)
                    oled_px_byte <= {(oled_fb_dout > dither), oled_px_byte[7:1]};
                if (oled_gather_cnt == 4'd8) begin
                    oled_gather_cnt <= 0;
                    oled_state      <= OST_SEND;
                end
            end
        endcase
    end
`endif

endmodule
