// =============================================================================
// chaos_amp.v — PIPE chaos amplifier v1 (Dragonfly)
// =============================================================================
//
// Bit-exact silicon implementation of `pipe::chaos_amp::chaos_amp`. The Rust crate at /mnt/Harbor/Code/pipe/enclave/src/chaos_amp.rs is the single source of algorithmic truth; this module's outputs MUST match the Rust reference for every input. The testbench at sim/tb_chaos_amp.v validates this against vectors emitted by `cargo run --bin gen-test-vectors`.
//
// =============================================================================
// Algorithm (12 rounds, 5 phases per round)
// =============================================================================
//
//   round[r], r = 0..11:
//     SUBSTITUTE   — each state byte thru AES S-box
//     MIX          — ARX with data-dependent rotation, near and far neighbors
//     INTERLEAVE   — swap upper halves between bucket pairs (i, i+8)
//     LOSE         — destroy 6 bits in one bucket via popcount mixing
//     SEASON       — XOR Dragonfly round constant into bucket 0
//
// Path entropy: 16 × 5 bits/round × 12 rounds = 960 bits ≈ 10^289 paths. Information loss: 6 bits/round × 12 rounds = 72 bits irrecoverable.
//
// =============================================================================
// Microarchitecture
// =============================================================================
//
// One full round per clock. Total latency = 12 cycles from `start` pulse to `done` assertion. State is held in 16 × 32-bit registers; the next-state function is a flat combinational block computing all five phases in series.
//
// At a 25 MHz enclave_clk the 12-round critical path of S-box + add + variable rotate + popcount is the timing bottleneck; should close comfortably below the 125 MHz BLAKE3 silicon Fmax measured in Phase C.
//
// =============================================================================
// I/O conventions
// =============================================================================
//
// `in_data` and `state_out` are 512-bit packed vectors. Bucket i occupies bits [i*32 +: 32], stored little-endian with respect to the byte stream (input[i*4 + 0] = bucket[7:0]). Same convention as Rust's `chaos_amp::state_to_bytes` / input absorption.
//
// =============================================================================

`timescale 1ns / 1ps

module chaos_amp (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         start,        // pulse: latch in_data and run 12 rounds
    input  wire [511:0] in_data,      // 16 × LE u32, packed
    output reg  [511:0] state_out,    // valid while done = 1
    output reg          done          // single-cycle pulse on completion
);

    localparam integer N_BUCKETS = 16;
    localparam integer ROUNDS    = 12;

    // =========================================================================
    // AES S-box (8 → 8 bijection). Compiled to LUT logic — yosys with wide-LUT mode (synth_ecp5 *without* -nowidelut) packs the 8-input function into ~16 LUT4-equivalent per byte using LUT5/LUT6/LUT7 SLICE combiners. With 64 parallel byte reads (16 buckets × 4 bytes) that's roughly 1 k LUT4 for the S-box layer — fits comfortably. `ram_style = "block"` would map to BRAM but requires clocked read ports; chaos_amp's round logic uses combinational reads so BRAM mapping is incompatible without pipelining the substitute phase into its own cycle.
    // =========================================================================
    reg [7:0] sbox [0:255];
    initial begin
        sbox[  0]=8'h63; sbox[  1]=8'h7c; sbox[  2]=8'h77; sbox[  3]=8'h7b;
        sbox[  4]=8'hf2; sbox[  5]=8'h6b; sbox[  6]=8'h6f; sbox[  7]=8'hc5;
        sbox[  8]=8'h30; sbox[  9]=8'h01; sbox[ 10]=8'h67; sbox[ 11]=8'h2b;
        sbox[ 12]=8'hfe; sbox[ 13]=8'hd7; sbox[ 14]=8'hab; sbox[ 15]=8'h76;
        sbox[ 16]=8'hca; sbox[ 17]=8'h82; sbox[ 18]=8'hc9; sbox[ 19]=8'h7d;
        sbox[ 20]=8'hfa; sbox[ 21]=8'h59; sbox[ 22]=8'h47; sbox[ 23]=8'hf0;
        sbox[ 24]=8'had; sbox[ 25]=8'hd4; sbox[ 26]=8'ha2; sbox[ 27]=8'haf;
        sbox[ 28]=8'h9c; sbox[ 29]=8'ha4; sbox[ 30]=8'h72; sbox[ 31]=8'hc0;
        sbox[ 32]=8'hb7; sbox[ 33]=8'hfd; sbox[ 34]=8'h93; sbox[ 35]=8'h26;
        sbox[ 36]=8'h36; sbox[ 37]=8'h3f; sbox[ 38]=8'hf7; sbox[ 39]=8'hcc;
        sbox[ 40]=8'h34; sbox[ 41]=8'ha5; sbox[ 42]=8'he5; sbox[ 43]=8'hf1;
        sbox[ 44]=8'h71; sbox[ 45]=8'hd8; sbox[ 46]=8'h31; sbox[ 47]=8'h15;
        sbox[ 48]=8'h04; sbox[ 49]=8'hc7; sbox[ 50]=8'h23; sbox[ 51]=8'hc3;
        sbox[ 52]=8'h18; sbox[ 53]=8'h96; sbox[ 54]=8'h05; sbox[ 55]=8'h9a;
        sbox[ 56]=8'h07; sbox[ 57]=8'h12; sbox[ 58]=8'h80; sbox[ 59]=8'he2;
        sbox[ 60]=8'heb; sbox[ 61]=8'h27; sbox[ 62]=8'hb2; sbox[ 63]=8'h75;
        sbox[ 64]=8'h09; sbox[ 65]=8'h83; sbox[ 66]=8'h2c; sbox[ 67]=8'h1a;
        sbox[ 68]=8'h1b; sbox[ 69]=8'h6e; sbox[ 70]=8'h5a; sbox[ 71]=8'ha0;
        sbox[ 72]=8'h52; sbox[ 73]=8'h3b; sbox[ 74]=8'hd6; sbox[ 75]=8'hb3;
        sbox[ 76]=8'h29; sbox[ 77]=8'he3; sbox[ 78]=8'h2f; sbox[ 79]=8'h84;
        sbox[ 80]=8'h53; sbox[ 81]=8'hd1; sbox[ 82]=8'h00; sbox[ 83]=8'hed;
        sbox[ 84]=8'h20; sbox[ 85]=8'hfc; sbox[ 86]=8'hb1; sbox[ 87]=8'h5b;
        sbox[ 88]=8'h6a; sbox[ 89]=8'hcb; sbox[ 90]=8'hbe; sbox[ 91]=8'h39;
        sbox[ 92]=8'h4a; sbox[ 93]=8'h4c; sbox[ 94]=8'h58; sbox[ 95]=8'hcf;
        sbox[ 96]=8'hd0; sbox[ 97]=8'hef; sbox[ 98]=8'haa; sbox[ 99]=8'hfb;
        sbox[100]=8'h43; sbox[101]=8'h4d; sbox[102]=8'h33; sbox[103]=8'h85;
        sbox[104]=8'h45; sbox[105]=8'hf9; sbox[106]=8'h02; sbox[107]=8'h7f;
        sbox[108]=8'h50; sbox[109]=8'h3c; sbox[110]=8'h9f; sbox[111]=8'ha8;
        sbox[112]=8'h51; sbox[113]=8'ha3; sbox[114]=8'h40; sbox[115]=8'h8f;
        sbox[116]=8'h92; sbox[117]=8'h9d; sbox[118]=8'h38; sbox[119]=8'hf5;
        sbox[120]=8'hbc; sbox[121]=8'hb6; sbox[122]=8'hda; sbox[123]=8'h21;
        sbox[124]=8'h10; sbox[125]=8'hff; sbox[126]=8'hf3; sbox[127]=8'hd2;
        sbox[128]=8'hcd; sbox[129]=8'h0c; sbox[130]=8'h13; sbox[131]=8'hec;
        sbox[132]=8'h5f; sbox[133]=8'h97; sbox[134]=8'h44; sbox[135]=8'h17;
        sbox[136]=8'hc4; sbox[137]=8'ha7; sbox[138]=8'h7e; sbox[139]=8'h3d;
        sbox[140]=8'h64; sbox[141]=8'h5d; sbox[142]=8'h19; sbox[143]=8'h73;
        sbox[144]=8'h60; sbox[145]=8'h81; sbox[146]=8'h4f; sbox[147]=8'hdc;
        sbox[148]=8'h22; sbox[149]=8'h2a; sbox[150]=8'h90; sbox[151]=8'h88;
        sbox[152]=8'h46; sbox[153]=8'hee; sbox[154]=8'hb8; sbox[155]=8'h14;
        sbox[156]=8'hde; sbox[157]=8'h5e; sbox[158]=8'h0b; sbox[159]=8'hdb;
        sbox[160]=8'he0; sbox[161]=8'h32; sbox[162]=8'h3a; sbox[163]=8'h0a;
        sbox[164]=8'h49; sbox[165]=8'h06; sbox[166]=8'h24; sbox[167]=8'h5c;
        sbox[168]=8'hc2; sbox[169]=8'hd3; sbox[170]=8'hac; sbox[171]=8'h62;
        sbox[172]=8'h91; sbox[173]=8'h95; sbox[174]=8'he4; sbox[175]=8'h79;
        sbox[176]=8'he7; sbox[177]=8'hc8; sbox[178]=8'h37; sbox[179]=8'h6d;
        sbox[180]=8'h8d; sbox[181]=8'hd5; sbox[182]=8'h4e; sbox[183]=8'ha9;
        sbox[184]=8'h6c; sbox[185]=8'h56; sbox[186]=8'hf4; sbox[187]=8'hea;
        sbox[188]=8'h65; sbox[189]=8'h7a; sbox[190]=8'hae; sbox[191]=8'h08;
        sbox[192]=8'hba; sbox[193]=8'h78; sbox[194]=8'h25; sbox[195]=8'h2e;
        sbox[196]=8'h1c; sbox[197]=8'ha6; sbox[198]=8'hb4; sbox[199]=8'hc6;
        sbox[200]=8'he8; sbox[201]=8'hdd; sbox[202]=8'h74; sbox[203]=8'h1f;
        sbox[204]=8'h4b; sbox[205]=8'hbd; sbox[206]=8'h8b; sbox[207]=8'h8a;
        sbox[208]=8'h70; sbox[209]=8'h3e; sbox[210]=8'hb5; sbox[211]=8'h66;
        sbox[212]=8'h48; sbox[213]=8'h03; sbox[214]=8'hf6; sbox[215]=8'h0e;
        sbox[216]=8'h61; sbox[217]=8'h35; sbox[218]=8'h57; sbox[219]=8'hb9;
        sbox[220]=8'h86; sbox[221]=8'hc1; sbox[222]=8'h1d; sbox[223]=8'h9e;
        sbox[224]=8'he1; sbox[225]=8'hf8; sbox[226]=8'h98; sbox[227]=8'h11;
        sbox[228]=8'h69; sbox[229]=8'hd9; sbox[230]=8'h8e; sbox[231]=8'h94;
        sbox[232]=8'h9b; sbox[233]=8'h1e; sbox[234]=8'h87; sbox[235]=8'he9;
        sbox[236]=8'hce; sbox[237]=8'h55; sbox[238]=8'h28; sbox[239]=8'hdf;
        sbox[240]=8'h8c; sbox[241]=8'ha1; sbox[242]=8'h89; sbox[243]=8'h0d;
        sbox[244]=8'hbf; sbox[245]=8'he6; sbox[246]=8'h42; sbox[247]=8'h68;
        sbox[248]=8'h41; sbox[249]=8'h99; sbox[250]=8'h2d; sbox[251]=8'h0f;
        sbox[252]=8'hb0; sbox[253]=8'h54; sbox[254]=8'hbb; sbox[255]=8'h16;
    end

    // =========================================================================
    // Round constants — blake3("PIPE chaos amp v1 - Dragonfly") (verified bit- exact by enclave/src/chaos_amp.rs::round_consts_match_blake3).
    // =========================================================================
    reg [31:0] round_const [0:11];
    initial begin
        round_const[ 0] = 32'hb49cfd47;
        round_const[ 1] = 32'h1ad8cacb;
        round_const[ 2] = 32'h7cee4209;
        round_const[ 3] = 32'h45c2c3ba;
        round_const[ 4] = 32'hda61bf21;
        round_const[ 5] = 32'h1ae39132;
        round_const[ 6] = 32'h0f7a9015;
        round_const[ 7] = 32'hbb017f89;
        round_const[ 8] = 32'h457b8fd0;
        round_const[ 9] = 32'hd9abdd9e;
        round_const[10] = 32'heaf22790;
        round_const[11] = 32'h17b72570;
    end

    // =========================================================================
    // State + control
    // =========================================================================
    reg [31:0] state [0:N_BUCKETS-1];
    reg [3:0]  round;       // 0..11
    reg        running;

    // =========================================================================
    // Combinational round: state → next_state via 5 phases.
    // =========================================================================

    // SUBSTITUTE: each byte of each bucket thru the S-box.
    wire [31:0] sub_state [0:N_BUCKETS-1];
    genvar gi;
    generate
        for (gi = 0; gi < N_BUCKETS; gi = gi + 1) begin : sub_g
            assign sub_state[gi] = {
                sbox[state[gi][31:24]],
                sbox[state[gi][23:16]],
                sbox[state[gi][15: 8]],
                sbox[state[gi][ 7: 0]]
            };
        end
    endgenerate

    // MIX: ARX, near (+1) and far (+11) neighbors, data-dependent rot.
    //   state'[i] = rotl(snap[i] + snap[(i+1)&15], snap[(i+1)&15] & 31)
    //               ^ rotr(snap[(i+11)&15], 7)
    function automatic [31:0] rotl;
        input [31:0] v;
        input [4:0]  n;
        begin
            // n=0: (v<<0)|(v>>32) = v|0 = v in Verilog (>>32 of a 32-bit reg = 0)
            rotl = (v << n) | (v >> (6'd32 - n));
        end
    endfunction
    function automatic [31:0] rotr_const7;
        input [31:0] v;
        begin
            rotr_const7 = (v >> 7) | (v << 25);
        end
    endfunction

    wire [31:0] mix_state [0:N_BUCKETS-1];
    generate
        for (gi = 0; gi < N_BUCKETS; gi = gi + 1) begin : mix_g
            wire [31:0] near = sub_state[(gi + 1)  & (N_BUCKETS - 1)];
            wire [31:0] far  = sub_state[(gi + 11) & (N_BUCKETS - 1)];
            wire [4:0]  rot  = near[4:0];
            assign mix_state[gi] = rotl(sub_state[gi] + near, rot) ^ rotr_const7(far);
        end
    endgenerate

    // INTERLEAVE: swap upper halves between (i, i+8).
    //   inter[i]   = {mix[i][31:16],   mix[i+8][15:0]}
    //   inter[i+8] = {mix[i+8][31:16], mix[i][15:0]}
    wire [31:0] inter_state [0:N_BUCKETS-1];
    generate
        for (gi = 0; gi < N_BUCKETS/2; gi = gi + 1) begin : inter_g
            assign inter_state[gi]                 = {mix_state[gi][31:16],
                                                      mix_state[gi + N_BUCKETS/2][15:0]};
            assign inter_state[gi + N_BUCKETS/2]   = {mix_state[gi + N_BUCKETS/2][31:16],
                                                      mix_state[gi][15:0]};
        end
    endgenerate

    // LOSE: target = (round * 7) & 15. For target bucket only, replace top 6 bits with popcount(v ^ neighbor). Other buckets unchanged.
    wire [3:0] lose_target = (round * 4'd7) & 4'hF;

    function automatic [5:0] popcount32;
        input [31:0] v;
        integer p;
        begin
            popcount32 = 6'd0;
            for (p = 0; p < 32; p = p + 1)
                popcount32 = popcount32 + {5'd0, v[p]};
        end
    endfunction

    wire [31:0] lose_state [0:N_BUCKETS-1];
    generate
        for (gi = 0; gi < N_BUCKETS; gi = gi + 1) begin : lose_g
            wire [31:0] v = inter_state[gi];
            wire [31:0] neigh = inter_state[(gi + 1) & (N_BUCKETS - 1)];
            wire [5:0]  pc = popcount32(v ^ neigh);
            assign lose_state[gi] = (gi[3:0] == lose_target)
                ? {pc, v[25:0]}
                : v;
        end
    endgenerate

    // SEASON: XOR round constant into bucket 0 only.
    wire [31:0] next_state [0:N_BUCKETS-1];
    generate
        for (gi = 0; gi < N_BUCKETS; gi = gi + 1) begin : season_g
            if (gi == 0) begin : s0
                assign next_state[gi] = lose_state[gi] ^ round_const[round];
            end else begin : sn
                assign next_state[gi] = lose_state[gi];
            end
        end
    endgenerate

    // =========================================================================
    // Sequencer
    // =========================================================================
    integer k;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            round   <= 4'd0;
            running <= 1'b0;
            done    <= 1'b0;
            for (k = 0; k < N_BUCKETS; k = k + 1)
                state[k] <= 32'd0;
        end else begin
            done <= 1'b0;
            if (start && !running) begin
                for (k = 0; k < N_BUCKETS; k = k + 1)
                    state[k] <= in_data[k*32 +: 32];
                round   <= 4'd0;
                running <= 1'b1;
            end else if (running) begin
                for (k = 0; k < N_BUCKETS; k = k + 1)
                    state[k] <= next_state[k];
                if (round == ROUNDS - 1) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                end
                round <= round + 4'd1;
            end
        end
    end

    // Pack state array into the output port.
    integer m;
    always @(*) begin
        for (m = 0; m < N_BUCKETS; m = m + 1)
            state_out[m*32 +: 32] = state[m];
    end

endmodule
