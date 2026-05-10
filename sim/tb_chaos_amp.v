// =============================================================================
// tb_chaos_amp.v — bit-exact validation of chaos_amp.v vs. Rust reference
// =============================================================================
//
// Loads vectors_input.mem and vectors_state.mem (both written by
// `cargo run --release --bin gen-test-vectors -- ../sim`) and drives the DUT
// with each input vector. The DUT must produce a state that matches the
// expected state byte-for-byte. Any mismatch fails.
//
// Vector format: 16 lines per vector in each file, one bucket (LE u32) per
// line. Vector v occupies lines [v*16 .. v*16+15].
//
// =============================================================================

`timescale 1ns / 1ps

module tb_chaos_amp;

    localparam integer N_VECTORS  = 4;
    localparam integer N_BUCKETS  = 16;

    reg          clk = 0;
    reg          reset_n = 0;
    reg          start = 0;
    reg  [511:0] in_data = 0;
    wire [511:0] state_out;
    wire         done;

    chaos_amp dut (
        .clk       (clk),
        .reset_n   (reset_n),
        .start     (start),
        .in_data   (in_data),
        .state_out (state_out),
        .done      (done)
    );

    always #5 clk = ~clk;  // 100 MHz behavioral clock

    // Vector storage (one u32 per line)
    reg [31:0] vec_input [0:N_VECTORS*N_BUCKETS-1];
    reg [31:0] vec_state [0:N_VECTORS*N_BUCKETS-1];

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
        reg [31:0] got;
        reg [31:0] want;
        reg        vec_ok;
        begin
            vec_ok = 1'b1;
            for (k = 0; k < N_BUCKETS; k = k + 1) begin
                got  = state_out[k*32 +: 32];
                want = vec_state[v*N_BUCKETS + k];
                if (got !== want) begin
                    vec_ok = 1'b0;
                    $display("FAIL  vec=%0d bucket=%0d got=%08x want=%08x",
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
        $readmemh("vectors_input.mem", vec_input);
        $readmemh("vectors_state.mem", vec_state);

        // Reset
        reset_n = 0;
        #20;
        reset_n = 1;
        #10;

        for (v = 0; v < N_VECTORS; v = v + 1) begin
            pack_input(v);
            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            // 12 rounds + 1 cycle for done assert
            cyc = 0;
            while (!done && cyc < 100) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            if (!done) begin
                fail = fail + 1;
                $display("FAIL  vec=%0d done never asserted (cyc=%0d)", v, cyc);
            end else begin
                check_vector(v);
            end
            @(posedge clk);  // settle
        end

        $display("");
        $display("chaos_amp tests: %0d pass, %0d fail", pass, fail);
        if (fail == 0)
            $display("OVERALL PASS");
        else
            $display("OVERALL FAIL");
        $finish;
    end

endmodule
