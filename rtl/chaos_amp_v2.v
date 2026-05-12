// =============================================================================
// chaos_amp_v2.v — PIPE chaos amplifier v2 (Dragonfly v2)
// =============================================================================
//
// Bit-exact silicon implementation of `pipe::chaos_amp_v2::chaos_amp_v2`. See PROTOCOL.md and enclave/src/chaos_amp_v2.rs for the algorithmic spec.
//
// Where v1 burned ~22k LUT4 on parallel AES S-box decode, v2 uses a 32-op data-dependent ALU menu serialized one bucket at a time. The 32-way mux happens in one shared instance feeding the regfile rather than 16 parallel copies — trades cycles for area.
//
// State: 16 buckets × 24 bits (F16E8: 16-bit fraction + 8-bit exponent). Total state = 384 bits, stored as a packed `[23:0]` array.
//
// FSM (serial, 1 bucket/cycle):
//   IDLE     → wait for `start`
//   LOAD     → absorb 64-byte in_data into 16 buckets (1 cycle)
//   PHASE1   → 16 cycles: for each bucket, compute op_apply result, store tmp
//   PHASE2   → 16 cycles: for each bucket, compute ARX mix, store back to state
//   (PHASE1+PHASE2 loop 16 rounds = 16×32 = 512 cycles for the rounds)
//   FINISH   → assert `done`, return to IDLE
//
// Total cycles per chaos_amp_v2 call: 1 + 512 + 1 = 514 cycles. At ring-osc-divided 50 MHz that's ~10 µs — negligible at PIPE protocol rates.
// =============================================================================

`timescale 1ns / 1ps

module chaos_amp_v2 (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         start,          // pulse: load in_data and run
    input  wire [511:0] in_data,        // 16 × LE u32 (top byte of each u32 XOR-folded into low byte during absorb)
    output reg  [383:0] state_out,      // 16 × 24-bit packed (valid while done = 1)
    output reg          done            // single-cycle pulse on completion
);

    localparam integer BUCKETS = 16;
    localparam integer ROUNDS  = 16;

    // =========================================================================
    // Round constants — `blake3("PIPE chaos amp v2 - Dragonfly")` first 12 + `blake3("PIPE chaos amp v2 - Dragonfly - more")` next 4. Verified bit- exact by enclave/src/chaos_amp_v2.rs::round_consts_match_blake3. Stored as 32-bit values; only low 24 bits feed the round XOR.
    // =========================================================================
    reg [31:0] round_const [0:ROUNDS-1];
    initial begin
        round_const[ 0] = 32'h6344f5d9;
        round_const[ 1] = 32'h9a9b6f24;
        round_const[ 2] = 32'hac41a271;
        round_const[ 3] = 32'hc373c1f2;
        round_const[ 4] = 32'h261b7279;
        round_const[ 5] = 32'h6f4d3ec7;
        round_const[ 6] = 32'h23f83617;
        round_const[ 7] = 32'h1816c525;
        round_const[ 8] = 32'h1fa89706;
        round_const[ 9] = 32'hb8278130;
        round_const[10] = 32'h12c98cb4;
        round_const[11] = 32'h755dd5a8;
        round_const[12] = 32'h5b4b9635;
        round_const[13] = 32'h3f76d80f;
        round_const[14] = 32'h033b166b;
        round_const[15] = 32'hcd721263;
    end

    // =========================================================================
    // State storage
    // =========================================================================
    reg [23:0] state [0:BUCKETS-1];   // current state (snap for phase 1)
    reg [23:0] tmp   [0:BUCKETS-1];   // intermediate between phase 1 and 2

    reg [4:0]  round_idx;             // 0..15
    reg [4:0]  bucket_idx;            // 0..15
    reg [2:0]  fsm_state;             // see localparam below
    localparam S_IDLE   = 3'd0;
    localparam S_LOAD   = 3'd1;
    localparam S_PHASE1 = 3'd2;
    localparam S_PHASE2 = 3'd3;
    localparam S_FINISH = 3'd4;

    // =========================================================================
    // Helper functions
    // =========================================================================

    // pos_const(i, r) = ((i * 0x9E3779B9) ^ (r * 0x517CC1B7)) & 0x00FFFFFF. Cheap arithmetic; yosys reduces multiply by constant to shift+add chain.
    function [23:0] pos_const;
        input [4:0] i;
        input [4:0] r;
        reg [31:0] term_i;
        reg [31:0] term_r;
        begin
            term_i = {27'b0, i} * 32'h9E3779B9;
            term_r = {27'b0, r} * 32'h517CC1B7;
            pos_const = (term_i ^ term_r) & 24'hFFFFFF;
        end
    endfunction

    // 16-bit popcount.
    function [4:0] popcount16;
        input [15:0] x;
        integer p;
        begin
            popcount16 = 5'd0;
            for (p = 0; p < 16; p = p + 1)
                popcount16 = popcount16 + {4'd0, x[p]};
        end
    endfunction

    // 8-bit popcount.
    function [3:0] popcount8;
        input [7:0] x;
        integer p;
        begin
            popcount8 = 4'd0;
            for (p = 0; p < 8; p = p + 1)
                popcount8 = popcount8 + {3'd0, x[p]};
        end
    endfunction

    // 16-bit bit-reverse.
    function [15:0] revbits16;
        input [15:0] x;
        integer p;
        begin
            for (p = 0; p < 16; p = p + 1)
                revbits16[p] = x[15 - p];
        end
    endfunction

    // i16 saturating add.
    function [15:0] sat_add16;
        input signed [15:0] a;
        input signed [15:0] b;
        reg signed [16:0] sum;
        begin
            sum = {a[15], a} + {b[15], b};
            if (sum > 17'sd32767)        sat_add16 = 16'h7FFF;
            else if (sum < -17'sd32768)  sat_add16 = 16'h8000;
            else                          sat_add16 = sum[15:0];
        end
    endfunction

    // i16 saturating sub.
    function [15:0] sat_sub16;
        input signed [15:0] a;
        input signed [15:0] b;
        reg signed [16:0] diff;
        begin
            diff = {a[15], a} - {b[15], b};
            if (diff > 17'sd32767)        sat_sub16 = 16'h7FFF;
            else if (diff < -17'sd32768)  sat_sub16 = 16'h8000;
            else                           sat_sub16 = diff[15:0];
        end
    endfunction

    // i8 saturating add.
    function [7:0] sat_add8;
        input signed [7:0] a;
        input signed [7:0] b;
        reg signed [8:0] sum;
        begin
            sum = {a[7], a} + {b[7], b};
            if (sum > 9'sd127)        sat_add8 = 8'h7F;
            else if (sum < -9'sd128)  sat_add8 = 8'h80;
            else                       sat_add8 = sum[7:0];
        end
    endfunction

    // i8 saturating sub.
    function [7:0] sat_sub8;
        input signed [7:0] a;
        input signed [7:0] b;
        reg signed [8:0] diff;
        begin
            diff = {a[7], a} - {b[7], b};
            if (diff > 9'sd127)        sat_sub8 = 8'h7F;
            else if (diff < -9'sd128)  sat_sub8 = 8'h80;
            else                        sat_sub8 = diff[7:0];
        end
    endfunction

    // GF(2^8) multiply with AES irreducible polynomial 0x11B (truncated to 0x1B with implicit x^8).
    function [7:0] gf_mul;
        input [7:0] a;
        input [7:0] b;
        reg [7:0] p;
        reg [7:0] ai;
        reg [7:0] bi;
        integer k;
        begin
            p = 8'd0;
            ai = a;
            bi = b;
            for (k = 0; k < 8; k = k + 1) begin
                if (bi[0]) p = p ^ ai;
                if (ai[7]) ai = (ai << 1) ^ 8'h1B;
                else       ai = ai << 1;
                bi = bi >> 1;
            end
            gf_mul = p;
        end
    endfunction

    // ZIP: interleave low bytes of a and b.
    function [15:0] zip_lo;
        input [7:0] a;
        input [7:0] b;
        integer z;
        begin
            zip_lo = 16'd0;
            for (z = 0; z < 8; z = z + 1) begin
                zip_lo[2 * z]       = a[z];
                zip_lo[2 * z + 1]   = b[z];
            end
        end
    endfunction

    // =========================================================================
    // 32-op ALU — combinational on (op_idx, val, secondary). Matches enclave/src/chaos_amp_v2.rs::op_apply.
    // =========================================================================
    function [23:0] op_apply;
        input [4:0] op_idx;
        input [23:0] val;
        input [23:0] secondary;

        reg signed [15:0] frac_a;
        reg signed [15:0] frac_b;
        reg        [15:0] ufa;
        reg        [15:0] ufb;
        reg signed [7:0]  exp_a;
        reg signed [7:0]  exp_b;
        reg        [7:0]  uea;
        reg        [7:0]  ueb;
        reg        [3:0]  sh;
        reg        [3:0]  sh_self;
        reg signed [15:0] new_frac;
        reg signed [7:0]  new_exp;
        reg signed [16:0] sum_avg_frac;
        reg signed [8:0]  sum_avg_exp;
        reg        [15:0] lo_nib;
        reg        [15:0] hi_nib;
        reg               parity_bit;
        reg        [15:0] paint16;
        reg        [7:0]  paint8;
        reg        [7:0]  squeeze_byte;
        reg        [15:0] lfsr_stepped;
        begin
            frac_a   = val[15:0];
            frac_b   = secondary[15:0];
            ufa      = val[15:0];
            ufb      = secondary[15:0];
            exp_a    = val[23:16];
            exp_b    = secondary[23:16];
            uea      = val[23:16];
            ueb      = secondary[23:16];
            sh       = secondary[3:0];
            sh_self  = val[3:0];

            // defaults — overridden in case branches
            new_frac = 16'd0;
            new_exp  = 8'd0;

            case (op_idx)
                // ============ Spirix-shaped (0..15) ============
                5'd0:  begin new_frac = frac_a + frac_b;             new_exp = exp_a + exp_b;            end // ADD
                5'd1:  begin new_frac = frac_a - frac_b;             new_exp = exp_a - exp_b;            end // SUB
                5'd2:  begin new_frac = frac_a * frac_b;             new_exp = exp_a * exp_b;            end // MUL_LO
                5'd3:  begin new_frac = frac_a & frac_b;             new_exp = exp_a & exp_b;            end // AND
                5'd4:  begin new_frac = frac_a | frac_b;             new_exp = exp_a | exp_b;            end // OR
                5'd5:  begin new_frac = frac_a ^ frac_b;             new_exp = exp_a ^ exp_b;            end // XOR
                5'd6:  begin new_frac = ufa & ~ufb;                   new_exp = uea & ~ueb;               end // ANDN
                5'd7:  begin new_frac = (~ufa) ^ ufb;                 new_exp = (~uea) ^ ueb;             end // NOT
                5'd8:  begin new_frac = (ufa << sh) ^ ufb;            new_exp = uea ^ ueb;                end // SHL
                5'd9:  begin new_frac = (ufa >> sh) ^ ufb;            new_exp = uea ^ ueb;                end // SHR
                5'd10: begin new_frac = ((ufa << sh) | (ufa >> (16 - sh))) ^ ufb; new_exp = uea ^ ueb;   end // ROL_B
                5'd11: begin new_frac = ((ufa >> sh) | (ufa << (16 - sh))) ^ ufb; new_exp = uea ^ ueb;   end // ROR_B
                5'd12: begin new_frac = ((ufa << sh_self) | (ufa >> (16 - sh_self))) ^ ufb; new_exp = uea ^ ueb; end // ROL_S
                5'd13: begin new_frac = (-frac_a) ^ frac_b;          new_exp = (-exp_a) ^ exp_b;         end // NEG
                5'd14: begin
                    // ABS — i16::MIN stays i16::MIN under wrapping_abs.
                    if (frac_a[15]) new_frac = (-frac_a) + frac_b;
                    else            new_frac = frac_a + frac_b;
                    if (exp_a[7])   new_exp  = (-exp_a) + exp_b;
                    else            new_exp  = exp_a + exp_b;
                end                                                                                       // ABS
                5'd15: begin new_frac = {ufa[7:0], ufa[15:8]} ^ ufb; new_exp = uea ^ ueb;                end // BSWAP

                // ============ Chaos-specific (16..31) ============
                5'd16: begin                                                                              // MIN
                    new_frac = (frac_a < frac_b) ? frac_a : frac_b;
                    new_exp  = (exp_a  < exp_b)  ? exp_a  : exp_b;
                end
                5'd17: begin                                                                              // MAX
                    new_frac = (frac_a > frac_b) ? frac_a : frac_b;
                    new_exp  = (exp_a  > exp_b)  ? exp_a  : exp_b;
                end
                5'd18: begin                                                                              // POPCNT
                    // Low byte = popcount(ufa ^ ufb), high byte = (ufa ^ ufb) high byte.
                    new_frac = {(ufa[15:8] ^ ufb[15:8]), {3'd0, popcount16(ufa ^ ufb)}};
                    new_exp  = uea ^ ueb;
                end
                5'd19: begin                                                                              // SAT_ADD
                    new_frac = sat_add16(frac_a, frac_b);
                    new_exp  = sat_add8(exp_a, exp_b);
                end
                5'd20: begin                                                                              // SAT_SUB
                    new_frac = sat_sub16(frac_a, frac_b);
                    new_exp  = sat_sub8(exp_a, exp_b);
                end
                5'd21: begin                                                                              // CSWAP
                    if (frac_a < frac_b) begin
                        new_frac = {ufb[7:0], ufb[15:8]} ^ frac_a;
                        new_exp  = exp_b ^ exp_a;
                    end else begin
                        new_frac = frac_a ^ frac_b;
                        new_exp  = exp_a ^ exp_b;
                    end
                end
                5'd22: begin                                                                              // GFMUL
                    new_frac = {ufa[15:8], gf_mul(ufa[7:0], ufb[7:0])} ^ ufb;
                    new_exp  = uea ^ ueb;
                end
                5'd23: begin                                                                              // PARITY
                    parity_bit = (popcount16(ufa) + {4'd0, popcount8(uea)}) & 5'd1;
                    paint16    = parity_bit ? 16'hFFFF : 16'h0000;
                    paint8     = parity_bit ? 8'hFF    : 8'h00;
                    new_frac   = paint16 ^ ufb;
                    new_exp    = paint8  ^ ueb;
                end
                5'd24: begin                                                                              // BREV
                    new_frac = revbits16(ufa) ^ ufb;
                    new_exp  = uea ^ ueb;
                end
                5'd25: begin                                                                              // NREV
                    lo_nib  = ((ufa & 16'h000F) << 4) | ((ufa & 16'h00F0) >> 4);
                    hi_nib  = ((ufa & 16'h0F00) << 4) | ((ufa & 16'hF000) >> 4);
                    new_frac = (lo_nib | hi_nib) ^ ufb;
                    new_exp  = uea ^ ueb;
                end
                5'd26: begin                                                                              // AVG
                    sum_avg_frac = {frac_a[15], frac_a} + {frac_b[15], frac_b} + 17'd1;
                    sum_avg_exp  = {exp_a[7],   exp_a}  + {exp_b[7],   exp_b}  + 9'd1;
                    new_frac     = sum_avg_frac[16:1];
                    new_exp      = sum_avg_exp[8:1];
                end
                5'd27: begin                                                                              // LFSR_TICK
                    lfsr_stepped = (ufa >> 1) ^ (ufa[0] ? 16'hB400 : 16'h0000);
                    new_frac     = lfsr_stepped ^ ufb;
                    new_exp      = uea ^ ueb;
                end
                5'd28: begin                                                                              // EXPAND_LO
                    new_frac = {ufa[7:0], ufa[7:0]} ^ ufb;
                    new_exp  = uea ^ ueb;
                end
                5'd29: begin                                                                              // SQUEEZE
                    squeeze_byte = (ufa[7:0] ^ ufa[15:8]) ^ (ufb[7:0] ^ ufb[15:8]) ^ uea ^ ueb;
                    new_frac     = {squeeze_byte, squeeze_byte};
                    new_exp      = squeeze_byte;
                end
                5'd30: begin                                                                              // ZIP
                    new_frac = zip_lo(ufa[7:0], ufb[7:0]);
                    new_exp  = uea ^ ueb;
                end
                5'd31: begin                                                                              // PCNT_REPLACE
                    // Each popcount16 returns 5 bits; zero-extend to 8 so two byte fields concat cleanly into a 16-bit frac. The exp popcount must include the 9th bit of (uea + ueb) — Rust does the add in u16 first then popcounts, so we add in 9-bit context (1 carry bit) then popcount the full 9 bits.
                    new_frac = {{3'd0, popcount16(ufb)}, {3'd0, popcount16(ufa)}};
                    new_exp  = {3'd0, popcount16({7'b0, uea} + {7'b0, ueb})};
                end

                default: begin new_frac = 16'd0; new_exp = 8'd0; end
            endcase

            op_apply = {new_exp[7:0], new_frac[15:0]};
        end
    endfunction

    // =========================================================================
    // Combinational round logic
    // =========================================================================
    wire [23:0] val_p1     = state[bucket_idx];
    wire [23:0] sec_p1     = state[(bucket_idx + 5'd11) & 5'd15];
    wire [4:0]  op_idx     = val_p1[4:0];
    wire [23:0] op_result  = op_apply(op_idx, val_p1, sec_p1);
    wire [23:0] rc24       = round_const[round_idx][23:0];
    wire [23:0] p1_result  = (op_result ^ rc24 ^ pos_const(bucket_idx, round_idx));

    wire [23:0] near_p2    = tmp[(bucket_idx + 5'd1) & 5'd15];
    wire [23:0] far_p2     = tmp[(bucket_idx + 5'd7) & 5'd15];
    wire [23:0] far_rot    = ((far_p2 << 5) | (far_p2 >> 19));
    wire [25:0] sum_p2     = {2'd0, tmp[bucket_idx]} + {2'd0, near_p2} + {2'd0, far_rot};
    wire [23:0] p2_result  = sum_p2[23:0];

    // =========================================================================
    // FSM
    // =========================================================================
    integer k;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fsm_state  <= S_IDLE;
            done       <= 1'b0;
            round_idx  <= 5'd0;
            bucket_idx <= 5'd0;
            for (k = 0; k < BUCKETS; k = k + 1) begin
                state[k] <= 24'd0;
                tmp[k]   <= 24'd0;
            end
        end else begin
            done <= 1'b0;
            case (fsm_state)
                S_IDLE: begin
                    if (start) begin
                        round_idx  <= 5'd0;
                        bucket_idx <= 5'd0;
                        fsm_state  <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    // Absorb 64-byte input: bucket i = LE u32 from input[i*4..i*4+4], with top byte XOR-folded into bottom byte, masked to 24 bits.
                    for (k = 0; k < BUCKETS; k = k + 1) begin
                        state[k] <= {
                            in_data[k*32 + 23 -: 8],                          // byte 2 → bits[23:16]
                            in_data[k*32 + 15 -: 8],                          // byte 1 → bits[15:8]
                            (in_data[k*32 + 7 -: 8] ^ in_data[k*32 + 31 -: 8]) // byte 0 XOR byte 3 → bits[7:0]
                        };
                    end
                    bucket_idx <= 5'd0;
                    fsm_state  <= S_PHASE1;
                end
                S_PHASE1: begin
                    tmp[bucket_idx] <= p1_result;
                    if (bucket_idx == 5'd15) begin
                        bucket_idx <= 5'd0;
                        fsm_state  <= S_PHASE2;
                    end else begin
                        bucket_idx <= bucket_idx + 5'd1;
                    end
                end
                S_PHASE2: begin
                    state[bucket_idx] <= p2_result;
                    if (bucket_idx == 5'd15) begin
                        bucket_idx <= 5'd0;
                        if (round_idx == ROUNDS - 1) begin
                            fsm_state <= S_FINISH;
                        end else begin
                            round_idx <= round_idx + 5'd1;
                            fsm_state <= S_PHASE1;
                        end
                    end else begin
                        bucket_idx <= bucket_idx + 5'd1;
                    end
                end
                S_FINISH: begin
                    done      <= 1'b1;
                    fsm_state <= S_IDLE;
                end
                default: fsm_state <= S_IDLE;
            endcase
        end
    end

    // Pack output
    integer m;
    always @(*) begin
        for (m = 0; m < BUCKETS; m = m + 1)
            state_out[m*24 +: 24] = state[m];
    end

endmodule
