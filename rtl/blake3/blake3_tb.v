`timescale 1ns / 1ps

module blake3_tb;

    reg         clk = 0;
    reg         reset_n = 0;
    reg [255:0] chain;
    reg [511:0] mblock;
    reg  [63:0] counter;
    reg  [31:0] numbytes;
    reg  [31:0] dflags;
    reg         valid = 0;

    wire [511:0] hash;
    wire         hash_valid;

    blake3 uut (
        .i_clk(clk),
        .i_reset(reset_n),
        .i_ce(1'b1),
        .i_chain(chain),
        .i_mblock(mblock),
        .i_counter(counter),
        .i_numbytes(numbytes),
        .i_dflags(dflags),
        .i_valid(valid),
        .o_hash(hash),
        .o_valid(hash_valid)
    );

    always #5 clk = ~clk;  // 100 MHz

    // Expected hash of b"": af1349b9 f5f9a1a6 a0404dea 36dcc949
    //                        9bcb25c9 adc112b7 cc9a93ca e41f3262
    // In little-endian 32-bit words (module format):
    localparam [255:0] EXPECTED_LO = {
        32'h62321fe4,  // word 7: e41f3262 → LE
        32'hca939acc,  // word 6: cc9a93ca → LE
        32'hb712c1ad,  // word 5: adc112b7 → LE
        32'hc925cb9b,  // word 4: 9bcb25c9 → LE
        32'h49c9dc36,  // word 3: 36dcc949 → LE
        32'hea4d40a0,  // word 2: a0404dea → LE  (corrected)
        32'ha6a1f9f5,  // word 1: f5f9a1a6 → LE
        32'hb94913af   // word 0: af1349b9 → LE
    };

    // Second half: e00f03e7 b69af26b 7faaf09f cd333050
    //              338ddfe0 85b8cc86 9ca98b20 6c08243a
    localparam [255:0] EXPECTED_HI = {
        32'h3a24086c,  // word 15
        32'h208ba99c,  // word 14
        32'h86ccb885,  // word 13
        32'he0df8d33,  // word 12
        32'h503033cd,  // word 11
        32'h9ff0aa7f,  // word 10
        32'h6bf29ab6,  // word 9
        32'he7030fe0   // word 8
    };

    integer i;
    reg [31:0] word;

    initial begin
        // IV as chaining value (word 0 in bits [31:0])
        chain = {
            32'h5BE0CD19,  // IV7
            32'h1F83D9AB,  // IV6
            32'h9B05688C,  // IV5
            32'h510E527F,  // IV4
            32'hA54FF53A,  // IV3
            32'h3C6EF372,  // IV2
            32'hBB67AE85,  // IV1
            32'h6A09E667   // IV0
        };
        mblock   = 512'b0;       // empty message
        counter  = 64'b0;
        numbytes = 32'd0;
        dflags   = 32'h0B;       // CHUNK_START | CHUNK_END | ROOT

        // Release reset
        #20 reset_n = 1;
        #10;

        // Strobe valid for 1 cycle
        @(posedge clk);
        valid = 1;
        @(posedge clk);
        valid = 0;

        // Wait for completion
        wait(hash_valid);
        @(posedge clk);

        $display("=== BLAKE3 hash(b\"\") test ===");
        $display("");

        // Print output words
        $display("Output (lower 256 bits = hash):");
        for (i = 0; i < 8; i = i + 1) begin
            word = hash[i*32 +: 32];
            $display("  word[%0d] = %08h", i, word);
        end
        $display("");
        $display("Output (upper 256 bits):");
        for (i = 8; i < 16; i = i + 1) begin
            word = hash[i*32 +: 32];
            $display("  word[%0d] = %08h", i, word);
        end

        $display("");

        // Check
        if (hash[255:0] == EXPECTED_LO && hash[511:256] == EXPECTED_HI) begin
            $display("PASS: hash matches expected value");
        end else begin
            $display("FAIL: hash mismatch");
            $display("  got lo:  %064h", hash[255:0]);
            $display("  exp lo:  %064h", EXPECTED_LO);
            $display("  got hi:  %064h", hash[511:256]);
            $display("  exp hi:  %064h", EXPECTED_HI);
        end

        #20 $finish;
    end

endmodule
