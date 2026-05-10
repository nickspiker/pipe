// =============================================================================
// tb_trng.v — exercise the TRNG plumbing
// =============================================================================
// Tests:
//   1. After reset: entropy=0, valid=0
//   2. After ~256 clk_slow edges: full asserts, sync propagates, valid asserts
//   3. entropy is non-zero (samples were captured)
//   4. After more clk_slow edges past full: entropy unchanged (locked)
//   5. POR clears: entropy=0, valid=0, counter reset
//   6. Post-POR re-collection works (full re-asserts after another 256 edges)
//
// SIM ENTROPY CAVEAT: clk_fast and clk_slow are deterministic behavioral
// clocks here, so the captured bit pattern is deterministic. We assert
// "non-zero" only — entropy QUALITY validation is hardware-only.
// =============================================================================

`timescale 1ns / 1ps

module tb_trng;

    reg          clk_fast    = 0;
    reg          clk_slow    = 0;
    reg          enclave_clk = 0;
    reg          reset_n     = 0;
    wire [255:0] entropy;
    wire         entropy_valid;

    trng dut (
        .clk_fast      (clk_fast),
        .clk_slow      (clk_slow),
        .enclave_clk   (enclave_clk),
        .reset_n       (reset_n),
        .entropy       (entropy),
        .entropy_valid (entropy_valid)
    );

    // Three behavioral clocks at different frequencies.
    // clk_fast    period 4 ns (250 MHz)
    // clk_slow    period 6 ns (167 MHz)
    // enclave_clk period 10 ns (100 MHz)
    always #2 clk_fast    = ~clk_fast;
    always #3 clk_slow    = ~clk_slow;
    always #5 enclave_clk = ~enclave_clk;

    integer pass = 0;
    integer fail = 0;

    task check;
        input [255:0] tag;       // 32-byte label
        input         actual;
        input         expected;
        begin
            if (actual === expected) begin
                pass = pass + 1;
                $display("PASS  %s", tag);
            end else begin
                pass = pass + 0;
                fail = fail + 1;
                $display("FAIL  %s  got=%b expected=%b", tag, actual, expected);
            end
        end
    endtask

    task check_zero;
        input [255:0] tag;
        input [255:0] val;
        begin
            if (val === 256'b0) begin
                pass = pass + 1;
                $display("PASS  %s", tag);
            end else begin
                fail = fail + 1;
                $display("FAIL  %s  val=%h", tag, val);
            end
        end
    endtask

    task check_nonzero;
        input [255:0] tag;
        input [255:0] val;
        begin
            if (val !== 256'b0) begin
                pass = pass + 1;
                $display("PASS  %s  (entropy = %h)", tag, val);
            end else begin
                fail = fail + 1;
                $display("FAIL  %s  entropy stuck at zero", tag);
            end
        end
    endtask

    reg [255:0] frozen_entropy;

    initial begin
        // ----- Phase 1: reset state -----
        reset_n = 0;
        #25;     // hold reset across several edges of every clock
        check     ("reset: valid is 0",       entropy_valid, 1'b0);
        check_zero("reset: entropy is 0",     entropy);

        // ----- Phase 2: release reset, wait for full collection -----
        reset_n = 1;
        // Need >256 posedges of clk_slow (= 256 * 6 = 1536 ns), plus 2-FF sync
        // into enclave_clk (~20 ns), plus margin. Wait 2000 ns.
        #2000;
        check        ("after 256 slow edges: valid is 1", entropy_valid, 1'b1);
        check_nonzero("entropy is non-zero",              entropy);

        // ----- Phase 3: lock — further slow edges do not change entropy -----
        frozen_entropy = entropy;
        #500;        // ~83 more clk_slow edges
        if (entropy === frozen_entropy) begin
            pass = pass + 1;
            $display("PASS  entropy locked after full");
        end else begin
            fail = fail + 1;
            $display("FAIL  entropy CHANGED after full: was %h now %h",
                      frozen_entropy, entropy);
        end
        check("valid still 1 after lock", entropy_valid, 1'b1);

        // ----- Phase 4: POR clears -----
        reset_n = 0;
        #25;
        check     ("after POR: valid is 0",   entropy_valid, 1'b0);
        check_zero("after POR: entropy is 0", entropy);

        // ----- Phase 5: post-POR re-collection -----
        reset_n = 1;
        #2000;
        check        ("post-POR: valid re-asserts", entropy_valid, 1'b1);
        check_nonzero("post-POR: entropy non-zero", entropy);

        // ----- Summary -----
        $display("");
        $display("================================");
        $display(" tb_trng: %0d pass / %0d fail", pass, fail);
        $display("================================");
        if (fail == 0) $display("OVERALL PASS");
        else           $display("OVERALL FAIL");
        $finish;
    end

endmodule
