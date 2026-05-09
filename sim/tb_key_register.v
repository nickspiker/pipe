// =============================================================================
// tb_key_register.v — exercise the write-once invariant
// =============================================================================
// Tests:
//   1. After reset, key_out is 0 and locked is 0
//   2. First write_strobe latches key_in, asserts locked
//   3. Subsequent writes are ignored (key_out unchanged)
//   4. Writes with locked already asserted are no-ops
//   5. POR (reset_n low) clears key and locked
// =============================================================================

`timescale 1ns / 1ps

module tb_key_register;

    reg          clk = 0;
    reg          reset_n = 0;
    reg  [255:0] key_in = 0;
    reg          write_strobe = 0;
    wire         locked;
    wire [255:0] key_out;

    key_register dut (
        .clk          (clk),
        .reset_n      (reset_n),
        .key_in       (key_in),
        .write_strobe (write_strobe),
        .locked       (locked),
        .key_out      (key_out)
    );

    // 100 MHz behavioral clock (no ring_osc instance — sims don't simulate primitives)
    always #5 clk = ~clk;

    integer pass = 0;
    integer fail = 0;
    task check;
        input [255:0] name_dummy;        // for $display labelling — caller passes a 32-char tag
        input         actual;
        input         expected;
        begin
            if (actual === expected) begin
                pass = pass + 1;
                $display("PASS  %s", name_dummy);
            end else begin
                fail = fail + 1;
                $display("FAIL  %s  got=%b expected=%b", name_dummy, actual, expected);
            end
        end
    endtask

    task check_key;
        input [255:0] name_dummy;
        input [255:0] actual;
        input [255:0] expected;
        begin
            if (actual === expected) begin
                pass = pass + 1;
                $display("PASS  %s", name_dummy);
            end else begin
                fail = fail + 1;
                $display("FAIL  %s", name_dummy);
                $display("        got=%h", actual);
                $display("        exp=%h", expected);
            end
        end
    endtask

    localparam [255:0] TEST_KEY_A = 256'hCAFEBABE_DEADBEEF_DEADBEEF_CAFEBABE_0123456789ABCDEF_FEDCBA9876543210;
    localparam [255:0] TEST_KEY_B = 256'h11111111_22222222_33333333_44444444_55555555_66666666_77777777_88888888;

    initial begin
        // ---- Phase 1: reset behaviour ----
        reset_n = 0;
        key_in  = 0;
        write_strobe = 0;
        #20;
        @(posedge clk);
        check("reset: locked is 0", locked, 1'b0);
        check_key("reset: key_out is 0", key_out, 256'b0);

        // ---- Release POR ----
        @(negedge clk);
        reset_n = 1;
        #1;
        check("post-reset: locked still 0", locked, 1'b0);
        check_key("post-reset: key_out still 0", key_out, 256'b0);

        // ---- Phase 2: first write latches key, asserts locked ----
        @(negedge clk);
        key_in       = TEST_KEY_A;
        write_strobe = 1;
        @(posedge clk);
        @(negedge clk);
        write_strobe = 0;
        check("after first write: locked = 1", locked, 1'b1);
        check_key("after first write: key_out == TEST_KEY_A", key_out, TEST_KEY_A);

        // ---- Phase 3: second write attempt is ignored ----
        @(negedge clk);
        key_in       = TEST_KEY_B;
        write_strobe = 1;
        @(posedge clk);
        @(negedge clk);
        write_strobe = 0;
        check_key("second write IGNORED: key_out still A", key_out, TEST_KEY_A);
        check("second write IGNORED: locked still 1", locked, 1'b1);

        // ---- Phase 4: many subsequent strobes ignored ----
        repeat (16) begin
            @(negedge clk);
            key_in       = $random;
            write_strobe = 1;
            @(posedge clk);
            @(negedge clk);
            write_strobe = 0;
        end
        check_key("after 16 attempted overwrites: key still A", key_out, TEST_KEY_A);
        check("after 16 attempted overwrites: locked still 1", locked, 1'b1);

        // ---- Phase 5: POR clears (the only escape) ----
        @(negedge clk);
        reset_n = 0;
        #20;
        check("after POR: locked = 0", locked, 1'b0);
        check_key("after POR: key_out = 0", key_out, 256'b0);

        // ---- Phase 6: post-POR write behaves like first-write again ----
        @(negedge clk);
        reset_n      = 1;
        @(negedge clk);
        key_in       = TEST_KEY_B;
        write_strobe = 1;
        @(posedge clk);
        @(negedge clk);
        write_strobe = 0;
        check("post-POR write: locked = 1", locked, 1'b1);
        check_key("post-POR write: key_out == TEST_KEY_B", key_out, TEST_KEY_B);

        // ---- Summary ----
        $display("");
        $display("================================");
        $display(" tb_key_register: %0d pass / %0d fail", pass, fail);
        $display("================================");
        if (fail == 0) $display("OVERALL PASS");
        else           $display("OVERALL FAIL");
        $finish;
    end

endmodule
