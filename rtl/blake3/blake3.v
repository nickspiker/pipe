// =============================================================================
// blake3.v  —  BLAKE3 Compression Function (2-stage pipelined G)
// =============================================================================
// Translated to Verilog-2001 from:
//   github.com/6a-62/blake3_vhdl  (BSD-3-Clause, Copyright 6a-62)
// Translation copyright released under same BSD-3-Clause terms.
//
// Implements the BLAKE3 compression function ONLY.
// Tree structure, chunking, padding, and root finalization are the caller's responsibility.
//
// Port description:
//   i_chain    [255:0]  Chaining value: 8 x 32-bit words, word 0 in [31:0]
//   i_mblock   [511:0]  Message block: 16 x 32-bit words, word 0 in [31:0]
//   i_counter  [63:0]   Block counter (low 32 in [31:0])
//   i_numbytes [31:0]   Number of bytes in this block (0..64)
//   i_dflags   [31:0]   Domain separation flags:
//                         CHUNK_START        = 32'h01
//                         CHUNK_END          = 32'h02
//                         PARENT             = 32'h04
//                         ROOT               = 32'h08
//                         KEYED_HASH         = 32'h10
//                         DERIVE_KEY_CONTEXT = 32'h20
//                         DERIVE_KEY_MATERIAL= 32'h40
//   i_valid             Strobe: assert for one cycle to load inputs
//   o_hash    [511:0]   Compression output (512 bits = two 256-bit halves)
//   o_valid             High when o_hash is valid and core is idle
//
// Latency: 30 clock cycles from i_valid strobe to o_valid
//   1 (PREPARE) + 7 × (GCOL1 + GCOL2 + GDIAG1 + GDIAG2) + 1 (OUTPUT)
//
// Reset: asynchronous, active-low (i_reset = 0 resets)
//
// Notes:
//   - G quarter-round split into two pipeline stages (half1: mx, half2: my)
//     to halve the critical path (2 adds per stage instead of 4)
//   - All arithmetic is 32-bit unsigned modular (wrapping)
//   - Message words and chaining value words are little-endian per BLAKE3 spec
// =============================================================================

`timescale 1ns / 1ps

module blake3 (
    input  wire         i_clk,
    input  wire         i_reset,      // Active-low asynchronous reset
    input  wire         i_ce,         // Clock enable (1=advance, 0=hold)

    // Inputs
    input  wire [255:0] i_chain,      // Input chaining value
    input  wire [511:0] i_mblock,     // Message block
    input  wire  [63:0] i_counter,    // Block counter
    input  wire  [31:0] i_numbytes,   // Number of input bytes
    input  wire  [31:0] i_dflags,     // Domain separation flags
    input  wire         i_valid,      // Strobe: inputs ready to sample

    // Outputs
    output reg  [511:0] o_hash,       // 512-bit compression output
    output reg          o_valid       // Output valid / core idle
);

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------
localparam [2:0]
    S_IDLE    = 3'd0,
    S_PREPARE = 3'd1,
    S_GCOL1   = 3'd2,
    S_GCOL2   = 3'd3,
    S_GDIAG1  = 3'd4,
    S_GDIAG2  = 3'd5,
    S_OUTPUT  = 3'd6;

reg [2:0] r_state;

// ---------------------------------------------------------------------------
// BLAKE3 / BLAKE2s IV constants
// ---------------------------------------------------------------------------
localparam [31:0]
    IV0 = 32'h6a09e667,
    IV1 = 32'hbb67ae85,
    IV2 = 32'h3c6ef372,
    IV3 = 32'ha54ff53a,
    IV4 = 32'h510e527f,   // not used inside compression function
    IV5 = 32'h9b05688c,   // not used inside compression function
    IV6 = 32'h1f83d9ab,   // not used inside compression function
    IV7 = 32'h5be0cd19;   // not used inside compression function

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------
reg [31:0]  r_v [0:15];   // 16-word compression state
reg [511:0] r_mblock;     // Current round's message words (permuted each round)
reg  [2:0]  r_round;      // Round counter: 0..6  (7 rounds total)

// ---------------------------------------------------------------------------
// G quarter-round — first half (uses mx)
//
//   a' = a + b + mx
//   d' = (d ^ a') >>> 16
//   c' = c + d'
//   b' = (b ^ c') >>> 12
//
// Returns {a'[127:96], b'[95:64], c'[63:32], d'[31:0]}
// ---------------------------------------------------------------------------
function [127:0] G_half1;
    input [31:0] a, b, c, d, mx;
    reg   [31:0] ta, tb, tc, td, t;
    begin
        ta = a  + b  + mx;
        t  = d  ^ ta;  td = {t[15:0], t[31:16]};   // ROR 16
        tc = c  + td;
        t  = b  ^ tc;  tb = {t[11:0], t[31:12]};   // ROR 12
        G_half1 = {ta, tb, tc, td};
    end
endfunction

// ---------------------------------------------------------------------------
// G quarter-round — second half (uses my)
//
//   a'' = a' + b' + my
//   d'' = (d' ^ a'') >>> 8
//   c'' = c' + d''
//   b'' = (b' ^ c'') >>> 7
//
// Returns {a''[127:96], b''[95:64], c''[63:32], d''[31:0]}
// ---------------------------------------------------------------------------
function [127:0] G_half2;
    input [31:0] a, b, c, d, my;
    reg   [31:0] ta, tb, tc, td, t;
    begin
        ta = a  + b  + my;
        t  = d  ^ ta;  td = {t[7:0],  t[31:8]};    // ROR  8
        tc = c  + td;
        t  = b  ^ tc;  tb = {t[6:0],  t[31:7]};    // ROR  7
        G_half2 = {ta, tb, tc, td};
    end
endfunction

// ---------------------------------------------------------------------------
// Combinatorial G_half1 instances — columns
//   Col 0: v[0], v[4],  v[8],  v[12], m[0]
//   Col 1: v[1], v[5],  v[9],  v[13], m[2]
//   Col 2: v[2], v[6],  v[10], v[14], m[4]
//   Col 3: v[3], v[7],  v[11], v[15], m[6]
// ---------------------------------------------------------------------------
wire [127:0] gc1_0, gc1_1, gc1_2, gc1_3;

assign gc1_0 = G_half1(r_v[0], r_v[4],  r_v[8],  r_v[12], r_mblock[0*32 +: 32]);
assign gc1_1 = G_half1(r_v[1], r_v[5],  r_v[9],  r_v[13], r_mblock[2*32 +: 32]);
assign gc1_2 = G_half1(r_v[2], r_v[6],  r_v[10], r_v[14], r_mblock[4*32 +: 32]);
assign gc1_3 = G_half1(r_v[3], r_v[7],  r_v[11], r_v[15], r_mblock[6*32 +: 32]);

// ---------------------------------------------------------------------------
// Combinatorial G_half2 instances — columns
//   Col 0: v[0], v[4],  v[8],  v[12], m[1]   (after half1 registered)
//   Col 1: v[1], v[5],  v[9],  v[13], m[3]
//   Col 2: v[2], v[6],  v[10], v[14], m[5]
//   Col 3: v[3], v[7],  v[11], v[15], m[7]
// ---------------------------------------------------------------------------
wire [127:0] gc2_0, gc2_1, gc2_2, gc2_3;

assign gc2_0 = G_half2(r_v[0], r_v[4],  r_v[8],  r_v[12], r_mblock[1*32 +: 32]);
assign gc2_1 = G_half2(r_v[1], r_v[5],  r_v[9],  r_v[13], r_mblock[3*32 +: 32]);
assign gc2_2 = G_half2(r_v[2], r_v[6],  r_v[10], r_v[14], r_mblock[5*32 +: 32]);
assign gc2_3 = G_half2(r_v[3], r_v[7],  r_v[11], r_v[15], r_mblock[7*32 +: 32]);

// ---------------------------------------------------------------------------
// Combinatorial G_half1 instances — diagonals
//   Diag 0: v[0], v[5],  v[10], v[15], m[8]
//   Diag 1: v[1], v[6],  v[11], v[12], m[10]
//   Diag 2: v[2], v[7],  v[8],  v[13], m[12]
//   Diag 3: v[3], v[4],  v[9],  v[14], m[14]
// ---------------------------------------------------------------------------
wire [127:0] gd1_0, gd1_1, gd1_2, gd1_3;

assign gd1_0 = G_half1(r_v[0], r_v[5],  r_v[10], r_v[15], r_mblock[8*32  +: 32]);
assign gd1_1 = G_half1(r_v[1], r_v[6],  r_v[11], r_v[12], r_mblock[10*32 +: 32]);
assign gd1_2 = G_half1(r_v[2], r_v[7],  r_v[8],  r_v[13], r_mblock[12*32 +: 32]);
assign gd1_3 = G_half1(r_v[3], r_v[4],  r_v[9],  r_v[14], r_mblock[14*32 +: 32]);

// ---------------------------------------------------------------------------
// Combinatorial G_half2 instances — diagonals
//   Diag 0: v[0], v[5],  v[10], v[15], m[9]   (after half1 registered)
//   Diag 1: v[1], v[6],  v[11], v[12], m[11]
//   Diag 2: v[2], v[7],  v[8],  v[13], m[13]
//   Diag 3: v[3], v[4],  v[9],  v[14], m[15]
// ---------------------------------------------------------------------------
wire [127:0] gd2_0, gd2_1, gd2_2, gd2_3;

assign gd2_0 = G_half2(r_v[0], r_v[5],  r_v[10], r_v[15], r_mblock[9*32  +: 32]);
assign gd2_1 = G_half2(r_v[1], r_v[6],  r_v[11], r_v[12], r_mblock[11*32 +: 32]);
assign gd2_2 = G_half2(r_v[2], r_v[7],  r_v[8],  r_v[13], r_mblock[13*32 +: 32]);
assign gd2_3 = G_half2(r_v[3], r_v[4],  r_v[9],  r_v[14], r_mblock[15*32 +: 32]);

// ---------------------------------------------------------------------------
// State machine — sequential logic
// ---------------------------------------------------------------------------
integer ii;

always @(posedge i_clk or negedge i_reset) begin
    if (!i_reset) begin
        r_state <= S_IDLE;
        o_valid <= 1'b1;
        o_hash  <= 512'b0;
        r_round <= 3'd0;
    end else if (i_ce) begin
        case (r_state)

        // ------------------------------------------------------------------
        S_IDLE: begin
            if (i_valid) begin
                o_valid <= 1'b0;
                r_state <= S_PREPARE;
            end
        end

        // ------------------------------------------------------------------
        S_PREPARE: begin
            for (ii = 0; ii < 8; ii = ii + 1)
                r_v[ii] <= i_chain[ii*32 +: 32];
            r_v[8]  <= IV0;
            r_v[9]  <= IV1;
            r_v[10] <= IV2;
            r_v[11] <= IV3;
            r_v[12] <= i_counter[31:0];
            r_v[13] <= i_counter[63:32];
            r_v[14] <= i_numbytes;
            r_v[15] <= i_dflags;
            r_mblock <= i_mblock;
            r_round  <= 3'd0;
            r_state  <= S_GCOL1;
        end

        // ------------------------------------------------------------------
        // Column half 1: G_half1 for all 4 columns → register intermediates
        // ------------------------------------------------------------------
        S_GCOL1: begin
            r_v[0]  <= gc1_0[127:96];  r_v[4]  <= gc1_0[95:64];
            r_v[8]  <= gc1_0[63:32];   r_v[12] <= gc1_0[31:0];

            r_v[1]  <= gc1_1[127:96];  r_v[5]  <= gc1_1[95:64];
            r_v[9]  <= gc1_1[63:32];   r_v[13] <= gc1_1[31:0];

            r_v[2]  <= gc1_2[127:96];  r_v[6]  <= gc1_2[95:64];
            r_v[10] <= gc1_2[63:32];   r_v[14] <= gc1_2[31:0];

            r_v[3]  <= gc1_3[127:96];  r_v[7]  <= gc1_3[95:64];
            r_v[11] <= gc1_3[63:32];   r_v[15] <= gc1_3[31:0];

            r_state <= S_GCOL2;
        end

        // ------------------------------------------------------------------
        // Column half 2: G_half2 for all 4 columns → register finals
        // ------------------------------------------------------------------
        S_GCOL2: begin
            r_v[0]  <= gc2_0[127:96];  r_v[4]  <= gc2_0[95:64];
            r_v[8]  <= gc2_0[63:32];   r_v[12] <= gc2_0[31:0];

            r_v[1]  <= gc2_1[127:96];  r_v[5]  <= gc2_1[95:64];
            r_v[9]  <= gc2_1[63:32];   r_v[13] <= gc2_1[31:0];

            r_v[2]  <= gc2_2[127:96];  r_v[6]  <= gc2_2[95:64];
            r_v[10] <= gc2_2[63:32];   r_v[14] <= gc2_2[31:0];

            r_v[3]  <= gc2_3[127:96];  r_v[7]  <= gc2_3[95:64];
            r_v[11] <= gc2_3[63:32];   r_v[15] <= gc2_3[31:0];

            r_state <= S_GDIAG1;
        end

        // ------------------------------------------------------------------
        // Diagonal half 1: G_half1 for all 4 diagonals → register intermediates
        // ------------------------------------------------------------------
        S_GDIAG1: begin
            r_v[0]  <= gd1_0[127:96];  r_v[5]  <= gd1_0[95:64];
            r_v[10] <= gd1_0[63:32];   r_v[15] <= gd1_0[31:0];

            r_v[1]  <= gd1_1[127:96];  r_v[6]  <= gd1_1[95:64];
            r_v[11] <= gd1_1[63:32];   r_v[12] <= gd1_1[31:0];

            r_v[2]  <= gd1_2[127:96];  r_v[7]  <= gd1_2[95:64];
            r_v[8]  <= gd1_2[63:32];   r_v[13] <= gd1_2[31:0];

            r_v[3]  <= gd1_3[127:96];  r_v[4]  <= gd1_3[95:64];
            r_v[9]  <= gd1_3[63:32];   r_v[14] <= gd1_3[31:0];

            r_state <= S_GDIAG2;
        end

        // ------------------------------------------------------------------
        // Diagonal half 2: G_half2 for all 4 diagonals → register finals
        // + message permutation σ on non-last rounds
        // ------------------------------------------------------------------
        S_GDIAG2: begin
            r_v[0]  <= gd2_0[127:96];  r_v[5]  <= gd2_0[95:64];
            r_v[10] <= gd2_0[63:32];   r_v[15] <= gd2_0[31:0];

            r_v[1]  <= gd2_1[127:96];  r_v[6]  <= gd2_1[95:64];
            r_v[11] <= gd2_1[63:32];   r_v[12] <= gd2_1[31:0];

            r_v[2]  <= gd2_2[127:96];  r_v[7]  <= gd2_2[95:64];
            r_v[8]  <= gd2_2[63:32];   r_v[13] <= gd2_2[31:0];

            r_v[3]  <= gd2_3[127:96];  r_v[4]  <= gd2_3[95:64];
            r_v[9]  <= gd2_3[63:32];   r_v[14] <= gd2_3[31:0];

            r_round <= r_round + 3'd1;

            if (r_round == 3'd6) begin
                r_round <= 3'd0;
                r_state <= S_OUTPUT;
            end else begin
                // Apply message permutation σ before next round.
                // σ = {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8}
                r_mblock[ 0*32 +: 32] <= r_mblock[ 2*32 +: 32];
                r_mblock[ 1*32 +: 32] <= r_mblock[ 6*32 +: 32];
                r_mblock[ 2*32 +: 32] <= r_mblock[ 3*32 +: 32];
                r_mblock[ 3*32 +: 32] <= r_mblock[10*32 +: 32];
                r_mblock[ 4*32 +: 32] <= r_mblock[ 7*32 +: 32];
                r_mblock[ 5*32 +: 32] <= r_mblock[ 0*32 +: 32];
                r_mblock[ 6*32 +: 32] <= r_mblock[ 4*32 +: 32];
                r_mblock[ 7*32 +: 32] <= r_mblock[13*32 +: 32];
                r_mblock[ 8*32 +: 32] <= r_mblock[ 1*32 +: 32];
                r_mblock[ 9*32 +: 32] <= r_mblock[11*32 +: 32];
                r_mblock[10*32 +: 32] <= r_mblock[12*32 +: 32];
                r_mblock[11*32 +: 32] <= r_mblock[ 5*32 +: 32];
                r_mblock[12*32 +: 32] <= r_mblock[ 9*32 +: 32];
                r_mblock[13*32 +: 32] <= r_mblock[14*32 +: 32];
                r_mblock[14*32 +: 32] <= r_mblock[15*32 +: 32];
                r_mblock[15*32 +: 32] <= r_mblock[ 8*32 +: 32];
                r_state <= S_GCOL1;
            end
        end

        // ------------------------------------------------------------------
        S_OUTPUT: begin
            for (ii = 0; ii < 8; ii = ii + 1) begin
                o_hash[ ii    *32 +: 32] <= r_v[ii]   ^ r_v[ii+8];
                o_hash[(ii+8) *32 +: 32] <= r_v[ii+8] ^ i_chain[ii*32 +: 32];
            end
            o_valid <= 1'b1;
            r_state <= S_IDLE;
        end

        // ------------------------------------------------------------------
        default: r_state <= S_IDLE;

        endcase
    end
end

endmodule
