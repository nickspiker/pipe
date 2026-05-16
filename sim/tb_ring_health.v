// =============================================================================
// tb_ring_health.v — exercise per-ring health monitor
// =============================================================================
//
// Feeds each known pattern through ring_health and checks the verdict against
// expectation. Patterns:
//
//   1. LFSR pseudo-random          → healthy
//   2. Constant 0                  → not healthy (RCT + level 0 fail)
//   3. Constant 1                  → not healthy (RCT + level 0 fail)
//   4. Stuck-then-stuck (W/2 zeros then W/2 ones) → not healthy (RCT)
//   5. Bias 5/8 ones (period 8 = 00011111)        → not healthy (level 0)
//   6. Period 8 = 00000111                         → not healthy (level 0)
//   7. Period 8 = 00001111                         → not healthy (level 1)
//   8. Period 4 = 0011                             → not healthy (level 2)
//   9. Period 2 = 01                               → not healthy (level 1)
//
// =============================================================================

`timescale 1ns / 1ps

module tb_ring_health;

    localparam integer W = 65536;
    localparam integer K = 6;

    reg          clk     = 1'b0;
    reg          reset_n = 1'b0;
    reg          start   = 1'b0;
    reg          sample  = 1'b0;
    wire         done;
    wire         healthy;

    ring_health #(.W(W), .K(K)) dut (
        .clk     (clk),
        .reset_n (reset_n),
        .start   (start),
        .sample  (sample),
        .done    (done),
        .healthy (healthy)
    );

    always #5 clk = ~clk;   // 100 MHz behavioral clock

    integer pass = 0;
    integer fail = 0;

    task check_verdict;
        input [255:0] tag;
        input         actual;
        input         expected;
        begin
            if (actual === expected) begin
                pass = pass + 1;
                $display("PASS  %0s  (healthy=%b)", tag, actual);
            end else begin
                fail = fail + 1;
                $display("FAIL  %0s  got healthy=%b expected=%b",
                          tag, actual, expected);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Pattern engine
    //
    // pattern_code:
    //   0 = LFSR pseudo-random (16-bit Fibonacci LFSR, taps 16,14,13,11)
    //   1 = constant 0
    //   2 = constant 1
    //   3 = stuck-then-stuck (W/2 zeros, W/2 ones)
    //   4 = 00011111 (period 8, 5/8 ones)
    //   5 = 00000111 (period 8, 3/8 ones)
    //   6 = 00001111 (period 8, balanced)
    //   7 = 0011     (period 4)
    //   8 = 01       (period 2)
    // -------------------------------------------------------------------------
    reg [15:0] lfsr = 16'hACE1;
    function lfsr_bit;
        input dummy;
        reg fb;
        begin
            fb   = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];
            lfsr = {lfsr[14:0], fb};
            lfsr_bit = fb;
        end
    endfunction

    function next_sample;
        input integer code;
        input integer i;
        begin
            case (code)
                0: next_sample = lfsr_bit(1'b0);
                1: next_sample = 1'b0;
                2: next_sample = 1'b1;
                3: next_sample = (i >= W/2);
                4: begin
                    // 00011111 period 8
                    case (i % 8)
                        0,1,2:                  next_sample = 1'b0;
                        default:                next_sample = 1'b1;
                    endcase
                end
                5: begin
                    // 00000111 period 8
                    case (i % 8)
                        5,6,7:                  next_sample = 1'b1;
                        default:                next_sample = 1'b0;
                    endcase
                end
                6: begin
                    // 00001111 period 8
                    case (i % 8)
                        4,5,6,7:                next_sample = 1'b1;
                        default:                next_sample = 1'b0;
                    endcase
                end
                7: begin
                    // 0011 period 4
                    case (i % 4)
                        2,3:                    next_sample = 1'b1;
                        default:                next_sample = 1'b0;
                    endcase
                end
                8: next_sample = i[0];          // 01 alternating
                default: next_sample = 1'b0;
            endcase
        end
    endfunction

    task run_pattern;
        input [255:0] tag;
        input integer code;
        input         expect_healthy;
        integer i;
        begin
            // reset LFSR for repeatable random
            lfsr = 16'hACE1;

            // first sample arrives in cycle of start
            @(negedge clk);
            sample = next_sample(code, 0);
            start  = 1'b1;
            @(negedge clk);
            start  = 1'b0;

            // remaining samples
            for (i = 1; i < W; i = i + 1) begin
                sample = next_sample(code, i);
                @(negedge clk);
            end

            // wait for done
            while (!done) @(negedge clk);
            check_verdict(tag, healthy, expect_healthy);
        end
    endtask

    initial begin
        // ----- POR -----
        reset_n = 1'b0;
        #50;
        reset_n = 1'b1;
        #20;

        // ----- run all patterns -----
        run_pattern("LFSR pseudo-random          ", 0, 1'b1);
        run_pattern("constant 0                  ", 1, 1'b0);
        run_pattern("constant 1                  ", 2, 1'b0);
        run_pattern("stuck-then-stuck            ", 3, 1'b0);
        run_pattern("bias 5/8 ones (00011111)    ", 4, 1'b0);
        run_pattern("00000111 (period 8, 3/8)    ", 5, 1'b0);
        run_pattern("00001111 (period 8, bal)    ", 6, 1'b0);
        run_pattern("0011 (period 4)             ", 7, 1'b0);
        run_pattern("01 (period 2)               ", 8, 1'b0);

        // ----- summary -----
        $display("");
        $display("===========================================");
        $display(" tb_ring_health: %0d pass / %0d fail", pass, fail);
        $display("===========================================");
        if (fail == 0) $display("OVERALL PASS");
        else           $display("OVERALL FAIL");
        $finish;
    end

    // safety timeout — each gather is ~W cycles @ 10 ns = ~660 us, 9 of them
    // plus margin → 10 ms ceiling
    initial begin
        #10_000_000;
        $display("FAIL  testbench TIMEOUT");
        $display("OVERALL FAIL");
        $finish;
    end

endmodule
