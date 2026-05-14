// =============================================================================
// blake3_tree.v — Full BLAKE3 hash over the 8192-byte TRNG buffer
// =============================================================================
//
// Wraps the single-block `blake3.v` compression core into a complete BLAKE3
// tree hash for the trng.v output buffer. The buffer is exactly 8 KB =
// 8 chunks × 1024 bytes; each chunk is 16 message blocks of 64 bytes. The
// tree has three parent levels: 8 → 4 → 2 → 1 root.
//
// Per BLAKE3 spec:
//   - Chunk blocks chain through CV; block 0 has CHUNK_START flag, block 15
//     has CHUNK_END flag. Counter = chunk index, same for every block within
//     the chunk. Numbytes = 64 (all blocks full).
//   - Parent compressions take {left_cv, right_cv} as the 64-byte mblock,
//     i_chain = IV, counter = 0, flags = PARENT.
//   - The root (top parent) additionally sets the ROOT flag. With 8 chunks,
//     the root is the level-3 parent compressing the two level-2 outputs;
//     no chunk has the ROOT flag in this geometry.
//
// 135 total compressions (128 chunk blocks + 4 + 2 + 1 parents). Each
// compression takes ~30 enclave_clk cycles inside the core, plus ~65 cycles
// loading a chunk block from the byte-wide trng buffer. Parents skip the
// load (their mblock is composed from stored CVs). Total: ~12 k cycles at
// 600 kHz ≈ 20 ms — invisible against KOHI's ~110 ms gather time.
//
// CV storage: a single 8 × 256-bit register file. Level 0 fills positions
// 0..7 with chunk CVs; level 1 overwrites 0..3 with parent CVs; level 2
// overwrites 0..1. No double buffering needed because each level reads
// pairs (2i, 2i+1) and writes to position i — the write always lags the
// read it depends on.
//
// =============================================================================

`timescale 1ns / 1ps

module blake3_tree (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         start,           // 1-cycle pulse to begin hashing

    // trng.v buffer read interface (byte-wide).
    // buf_raddr is COMBINATIONAL (driven from the load counter) so the
    // 1-cycle synchronous-BRAM read inside trng.v has its address ready at
    // the same posedge — without this, addr+BRAM stack to 2 cycles of
    // pipeline and capture lags by one byte. Same idiom as oled_greyscale_driver.v.
    output wire [12:0]  buf_raddr,
    input  wire  [7:0]  buf_rdata,

    output reg  [255:0] ira,             // final 256-bit conditioned output
    output reg          ira_valid,       // 1-cycle strobe when ira is ready
    output reg          busy             // high while hashing
);

    // -------------------------------------------------------------------------
    // BLAKE3 IV (initial chaining value). word 0 occupies [31:0]. Per
    // blake3.v header: little-endian word ordering in the 256-bit chain.
    // -------------------------------------------------------------------------
    localparam [255:0] BLAKE3_IV = {
        32'h5be0cd19, 32'h1f83d9ab, 32'h9b05688c, 32'h510e527f,
        32'ha54ff53a, 32'h3c6ef372, 32'hbb67ae85, 32'h6a09e667
    };

    // BLAKE3 domain-separation flags
    localparam [31:0] FLG_CHUNK_START = 32'h01;
    localparam [31:0] FLG_CHUNK_END   = 32'h02;
    localparam [31:0] FLG_PARENT      = 32'h04;
    localparam [31:0] FLG_ROOT        = 32'h08;

    // -------------------------------------------------------------------------
    // BLAKE3 core instance
    // -------------------------------------------------------------------------
    reg          b3_valid;
    reg  [255:0] b3_chain;
    reg  [511:0] b3_mblock;
    reg   [63:0] b3_counter;
    reg   [31:0] b3_numbytes;
    reg   [31:0] b3_dflags;
    wire [511:0] b3_hash;
    wire         b3_done;

    blake3 u_blake3 (
        .i_clk     (clk),
        .i_reset   (reset_n),
        .i_ce      (1'b1),
        .i_chain   (b3_chain),
        .i_mblock  (b3_mblock),
        .i_counter (b3_counter),
        .i_numbytes(b3_numbytes),
        .i_dflags  (b3_dflags),
        .i_valid   (b3_valid),
        .o_hash    (b3_hash),
        .o_valid   (b3_done)
    );

    // -------------------------------------------------------------------------
    // CV register file — 8 × 256 bits = 2048 bits of state.
    // Level 0 (chunks) fills slots 0..7; level 1 overwrites slots 0..3 with
    // its 4 parents; level 2 overwrites 0..1; root is captured directly to
    // `ira` without going through cv_buf.
    // -------------------------------------------------------------------------
    reg [255:0] cv_buf [0:7];

    // Chain register used during chunk compression — updated after every
    // non-final block to feed the next block in the same chunk.
    reg [255:0] chunk_chain;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [3:0]
        ST_IDLE        = 4'd0,
        ST_LOAD        = 4'd1,   // streaming 64 bytes from trng buf into b3_mblock
        ST_PARENT_PREP = 4'd2,   // composing parent mblock from cv_buf
        ST_FIRE        = 4'd3,   // strobing b3_valid for one cycle
        ST_WAIT_GO     = 4'd4,   // waiting for blake3 core to leave idle
        ST_WAIT_DONE   = 4'd5,   // waiting for blake3 core to assert o_valid
        ST_NEXT        = 4'd6,   // deciding what to compress next
        ST_DONE        = 4'd7;

    reg [3:0] state;

    reg [2:0] chunk_idx;         // 0..7  — current chunk being hashed
    reg [3:0] block_idx;         // 0..15 — current block within chunk
    reg [6:0] load_cnt;          // 0..64 — cycle counter inside ST_LOAD
    reg [1:0] tree_level;        // 0=chunks, 1=L1 parents, 2=L2 parents, 3=root
    reg [1:0] parent_idx;        // 0..3  — which parent in the current level

    // Convenience: combined byte address for current chunk-block in buffer.
    // chunk_idx * 1024 + block_idx * 64 + byte_offset.
    wire [12:0] block_base = {chunk_idx, block_idx, 6'b0};

    // Combinational address: presents the byte to read on every cycle of
    // ST_LOAD. With trng.v's 1-cycle BRAM read latency, the captured byte
    // appears at buf_rdata one cycle after load_cnt advances — the ST_LOAD
    // logic captures load_cnt[6:0]-1 at each cycle ≥ 1.
    assign buf_raddr = block_base + {6'b0, load_cnt[6:0]};

    // -------------------------------------------------------------------------
    // Per-compression input composition
    //
    // Chunk blocks:
    //   chain    = IV (block 0) or chunk_chain (otherwise)
    //   counter  = chunk_idx (zero-extended)
    //   numbytes = 64
    //   dflags   = (block_idx==0 ? CHUNK_START : 0) | (block_idx==15 ? CHUNK_END : 0)
    //
    // Parents:
    //   chain    = IV
    //   counter  = 0
    //   numbytes = 64
    //   dflags   = PARENT (+ ROOT iff this is the very last compression)
    // -------------------------------------------------------------------------
    integer i;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= ST_IDLE;
            chunk_idx   <= 3'b0;
            block_idx   <= 4'b0;
            load_cnt    <= 7'b0;
            tree_level  <= 2'b0;
            parent_idx  <= 2'b0;
            b3_valid    <= 1'b0;
            b3_chain    <= 256'b0;
            b3_mblock   <= 512'b0;
            b3_counter  <= 64'b0;
            b3_numbytes <= 32'b0;
            b3_dflags   <= 32'b0;
            chunk_chain <= 256'b0;
            ira         <= 256'b0;
            ira_valid   <= 1'b0;
            busy        <= 1'b0;
            for (i = 0; i < 8; i = i + 1) cv_buf[i] <= 256'b0;
        end else begin
            b3_valid  <= 1'b0;
            ira_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        chunk_idx   <= 3'b0;
                        block_idx   <= 4'b0;
                        load_cnt    <= 7'b0;
                        tree_level  <= 2'b0;
                        parent_idx  <= 2'b0;
                        chunk_chain <= BLAKE3_IV;
                        busy        <= 1'b1;
                        state       <= ST_LOAD;
                    end
                end

                // -------------------------------------------------------------
                // Load one 64-byte block from the trng buffer into b3_mblock.
                //   cycle 0: present addr 0
                //   cycle k (1..63): capture byte (k-1), present addr k
                //   cycle 64: capture byte 63 — done, go to ST_FIRE
                // -------------------------------------------------------------
                ST_LOAD: begin
                    // Address is driven combinationally from load_cnt; the
                    // 1-cycle BRAM read means buf_rdata at cycle K holds
                    // byte (K-1), valid for capture once load_cnt >= 1.
                    if (load_cnt >= 7'd1 && load_cnt <= 7'd64) begin
                        b3_mblock[8*(load_cnt-7'd1) +: 8] <= buf_rdata;
                    end
                    if (load_cnt == 7'd64) begin
                        load_cnt <= 7'b0;
                        state    <= ST_FIRE;
                    end else begin
                        load_cnt <= load_cnt + 7'd1;
                    end
                end

                // -------------------------------------------------------------
                // Compose parent mblock from two adjacent CVs.
                // For level 1: pairs are (cv_buf[2*i], cv_buf[2*i+1]) — left
                // child in low half, right child in high half.
                // -------------------------------------------------------------
                ST_PARENT_PREP: begin
                    b3_mblock <= {cv_buf[{parent_idx, 1'b1}],
                                  cv_buf[{parent_idx, 1'b0}]};
                    state     <= ST_FIRE;
                end

                // -------------------------------------------------------------
                // Drive blake3 inputs and strobe i_valid for one cycle.
                // The next-state logic in ST_NEXT decides what level/index
                // is in play — ST_FIRE just sets up the constants for the
                // already-determined operation.
                // -------------------------------------------------------------
                ST_FIRE: begin
                    if (tree_level == 2'd0) begin
                        // Chunk block
                        b3_chain    <= (block_idx == 4'd0) ? BLAKE3_IV : chunk_chain;
                        b3_counter  <= {61'b0, chunk_idx};
                        b3_numbytes <= 32'd64;
                        b3_dflags   <= ((block_idx == 4'd0)  ? FLG_CHUNK_START : 32'b0)
                                     | ((block_idx == 4'd15) ? FLG_CHUNK_END   : 32'b0);
                    end else begin
                        // Parent compression (b3_mblock already composed in ST_PARENT_PREP)
                        b3_chain    <= BLAKE3_IV;
                        b3_counter  <= 64'b0;
                        b3_numbytes <= 32'd64;
                        // ROOT flag set only on the very last compression
                        // (level 3 in our 8-chunk geometry).
                        b3_dflags   <= FLG_PARENT
                                     | ((tree_level == 2'd3) ? FLG_ROOT : 32'b0);
                    end
                    b3_valid <= 1'b1;
                    state    <= ST_WAIT_GO;
                end

                // Wait for the core to acknowledge i_valid by going non-idle.
                ST_WAIT_GO: begin
                    if (!b3_done) state <= ST_WAIT_DONE;
                end

                // Wait for the core to finish (o_valid high again).
                ST_WAIT_DONE: begin
                    if (b3_done) state <= ST_NEXT;
                end

                // -------------------------------------------------------------
                // Compression complete — capture o_hash[255:0] and decide the
                // next compression (or finish). This is the only place that
                // mutates chunk_idx / block_idx / parent_idx / tree_level.
                // -------------------------------------------------------------
                ST_NEXT: begin
                    if (tree_level == 2'd0) begin
                        // Chunk-block result.
                        if (block_idx == 4'd15) begin
                            // Last block of this chunk — store chunk CV.
                            cv_buf[chunk_idx] <= b3_hash[255:0];
                            block_idx         <= 4'b0;
                            chunk_chain       <= BLAKE3_IV;
                            if (chunk_idx == 3'd7) begin
                                // All 8 chunks done — start level 1 parents.
                                tree_level <= 2'd1;
                                parent_idx <= 2'b0;
                                state      <= ST_PARENT_PREP;
                            end else begin
                                chunk_idx <= chunk_idx + 3'd1;
                                state     <= ST_LOAD;
                            end
                        end else begin
                            // Mid-chunk: feed CV forward to next block.
                            chunk_chain <= b3_hash[255:0];
                            block_idx   <= block_idx + 4'd1;
                            state       <= ST_LOAD;
                        end
                    end else begin
                        // Parent result.
                        if (tree_level == 2'd1) begin
                            // Level 1: 4 parents, write to cv_buf[0..3].
                            cv_buf[{1'b0, parent_idx[1:0]}] <= b3_hash[255:0];
                            if (parent_idx == 2'd3) begin
                                tree_level <= 2'd2;
                                parent_idx <= 2'b0;
                                state      <= ST_PARENT_PREP;
                            end else begin
                                parent_idx <= parent_idx + 2'd1;
                                state      <= ST_PARENT_PREP;
                            end
                        end else if (tree_level == 2'd2) begin
                            // Level 2: 2 parents, write to cv_buf[0..1].
                            cv_buf[{2'b00, parent_idx[0]}] <= b3_hash[255:0];
                            if (parent_idx == 2'd1) begin
                                tree_level <= 2'd3;
                                parent_idx <= 2'b0;
                                state      <= ST_PARENT_PREP;
                            end else begin
                                parent_idx <= parent_idx + 2'd1;
                                state      <= ST_PARENT_PREP;
                            end
                        end else begin
                            // Level 3 root: final result.
                            ira       <= b3_hash[255:0];
                            ira_valid <= 1'b1;
                            state     <= ST_DONE;
                        end
                    end
                end

                ST_DONE: begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
