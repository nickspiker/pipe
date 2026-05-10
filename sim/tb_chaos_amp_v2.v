// =============================================================================
// tb_chaos_amp_v2.v — bit-exact validation of chaos_amp_v2.v vs. Rust reference
// =============================================================================
//
// Same pattern as tb_chaos_amp.v: load `vectors_input.mem` (16 × LE u32 per
// vector) and `vectors_state_v2.mem` (16 × 24b per vector) from the Rust
// `gen-test-vectors` binary, drive the DUT, compare its 384-bit state_out to
// the expected v2 state byte-for-byte.
//
// =============================================================================

`timescale 1ns / 1ps

module tb_chaos_amp_v2;

    localparam integer N_VECTORS = 4;
    localparam integer N_BUCKETS = 16;

    reg          clk = 0;
    reg          reset_n = 0;
    reg          start = 0;
    reg  [511:0] in_data = 0;
    wire [383:0] state_out;
    wire         done;

    chaos_amp_v2 dut (
        .clk       (clk),
        .reset_n   (reset_n),
        .start     (start),
        .in_data   (in_data),
        .state_out (state_out),
        .done      (done)
    );

    always #5 clk = ~clk;  // 100 MHz behavioral clock

    // Vector storage
    reg [31:0] vec_input    [0:N_VECTORS*N_BUCKETS-1];   // 16 × u32 per vector
    reg [23:0] vec_state_v2 [0:N_VECTORS*N_BUCKETS-1];   // 16 × u24 per vector

    integer pass = 0;
    integer fail = 0;

    task pack_input;
        input integer v;
        integer k;
        begin
            for (k = 0; k < N_BUCKETS; k = k + 1)
                in_data[k*32 +: 32] = vec_input[v*N_BUCKETS + k];
        end
    endtask

    task check_vector;
        input integer v;
        integer k;
        reg [23:0] got;
        reg [23:0] want;
        reg        vec_ok;
        begin
            vec_ok = 1'b1;
            for (k = 0; k < N_BUCKETS; k = k + 1) begin
                got  = state_out[k*24 +: 24];
                want = vec_state_v2[v*N_BUCKETS + k];
                if (got !== want) begin
                    vec_ok = 1'b0;
                    $display("FAIL  vec=%0d bucket=%0d got=%06x want=%06x",
                             v, k, got, want);
                end
            end
            if (vec_ok) begin
                pass = pass + 1;
                $display("PASS  vec=%0d", v);
            end else begin
                fail = fail + 1;
                $display("FAIL  vec=%0d (bucket-level mismatches above)", v);
            end
        end
    endtask

    integer v;
    integer cyc;
    initial begin
        $readmemh("vectors_input.mem",     vec_input);
        $readmemh("vectors_state_v2.mem",  vec_state_v2);

        reset_n = 0;
        #20;
        reset_n = 1;
        #10;

        for (v = 0; v < N_VECTORS; v = v + 1) begin
            pack_input(v);
            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            // 514 cycles per call max (1 LOAD + 16 rounds × 32 + 1 FINISH)
            cyc = 0;
            while (!done && cyc < 700) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (!done) begin
                fail = fail + 1;
                $display("FAIL  vec=%0d done never asserted (cyc=%0d)", v, cyc);
            end else begin
                check_vector(v);
            end
            @(posedge clk);
        end

        $display("");
        $display("chaos_amp_v2 tests: %0d pass, %0d fail", pass, fail);
        if (fail == 0)
            $display("OVERALL PASS");
        else
            $display("OVERALL FAIL");
        $finish;
    end

endmodule
