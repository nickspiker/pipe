// =============================================================================
// inverted_pair_verify_tb.v — exercise the 5-state classifier
// =============================================================================
// Drives inverted_pair_verify with a series of hand-crafted slot
// configurations and checks state, valid_count, agreement, recovered ira,
// and the popcount-sanity-driven corrupt/valid distinctions match the
// IRA.md spec.
//
// Popcount is sequential (257-cycle sweep), so each scenario waits 320
// cycles after changing slot_flat to let the sweep latch fresh counts.
// =============================================================================

`timescale 1ns / 1ps

module inverted_pair_verify_tb;

    localparam SLOT_BITS = 256;

    reg clk = 0;
    always #5 clk = ~clk;        // 100 MHz sim clock

    reg                    reset_n = 0;
    reg  [8*SLOT_BITS-1:0] slot_flat = 0;
    wire                   state_valid;
    wire [3:0]             pair_virgin, pair_valid, pair_corrupt;
    wire [2:0]             valid_count, state;
    wire                   all_virgin, agreement_ok, byzantine_ok;
    wire [SLOT_BITS-1:0]   ira;

    inverted_pair_verify #(.SLOT_BITS(SLOT_BITS)) dut (
        .clk         (clk),
        .reset_n     (reset_n),
        .slot_flat   (slot_flat),
        .state_valid (state_valid),
        .pair_virgin (pair_virgin),
        .pair_valid  (pair_valid),
        .pair_corrupt(pair_corrupt),
        .valid_count (valid_count),
        .all_virgin  (all_virgin),
        .agreement_ok(agreement_ok),
        .byzantine_ok(byzantine_ok),
        .state       (state),
        .ira         (ira)
    );

    task automatic set_slots(
        input [SLOT_BITS-1:0] s0, s1, s2, s3,
        input [SLOT_BITS-1:0] s4, s5, s6, s7
    );
        begin
            slot_flat = {s7, s6, s5, s4, s3, s2, s1, s0};
        end
    endtask

    // Wait long enough for the popcount sweep to refresh after a slot_flat
    // change. 2049 cycles per sweep (8 slots × 256 bits + 1); pick 5000 to
    // comfortably cover two sweeps (the in-flight one may be using stale
    // data; the next one picks up new).
    task automatic wait_for_resweep;
        integer cycles;
        begin
            for (cycles = 0; cycles < 5000; cycles = cycles + 1)
                @(posedge clk);
        end
    endtask

    integer pass_count = 0, fail_count = 0;
    task automatic expect_eq(
        input [127:0] name,
        input [31:0]  actual,
        input [31:0]  expected
    );
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("  FAIL %s: got %0d, expected %0d", name, actual, expected);
            end
        end
    endtask

    localparam [SLOT_BITS-1:0] ZERO  = {SLOT_BITS{1'b0}};
    localparam [SLOT_BITS-1:0] ONES  = {SLOT_BITS{1'b1}};
    localparam [SLOT_BITS-1:0] IRA_A = 256'hC0FFEE_DEADBEEF_C0FFEE_DEADBEEF_C0FFEE_DEADBEEF_C0FFEE_DEADBEEF;
    localparam [SLOT_BITS-1:0] IRA_B = 256'hFEEDFACE_BAADF00D_FEEDFACE_BAADF00D_FEEDFACE_BAADF00D_FEEDFACE_BAADF00D;

    initial begin
        $display("");
        $display("=== inverted_pair_verify 5-state classifier ===");

        #25 reset_n = 1;
        @(posedge clk);

        // T1. All slots zero — VIRGIN (state 0)
        set_slots(ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO);
        wait_for_resweep;
        $display("T1 (all-zero): state=%0d, valid_count=%0d, virgin=%b state_valid=%b",
                 state, valid_count, pair_virgin, state_valid);
        expect_eq("T1.state_valid", {31'b0, state_valid}, 32'd1);
        expect_eq("T1.state",       {29'b0, state},       32'd0);
        expect_eq("T1.valid_count", {29'b0, valid_count}, 32'd0);
        expect_eq("T1.all_virgin",  {31'b0, all_virgin},  32'd1);

        // T2. Pair 0 valid (A=IRA_A, B=~IRA_A), others zero (virgin) → FUCKED
        set_slots(IRA_A, ZERO, ZERO, ZERO, ~IRA_A, ZERO, ZERO, ZERO);
        wait_for_resweep;
        $display("T2 (1 valid + 3 virgin): state=%0d, valid_count=%0d", state, valid_count);
        expect_eq("T2.state",       {29'b0, state},       32'd1);
        expect_eq("T2.valid_count", {29'b0, valid_count}, 32'd1);

        // T3. Pairs 0,1 valid agreeing → DEGRADED-2 (state 2)
        set_slots(IRA_A, IRA_A, ZERO, ZERO, ~IRA_A, ~IRA_A, ZERO, ZERO);
        wait_for_resweep;
        $display("T3 (2 valid agreeing): state=%0d, valid_count=%0d", state, valid_count);
        expect_eq("T3.state",       {29'b0, state},        32'd2);
        expect_eq("T3.valid_count", {29'b0, valid_count},  32'd2);
        expect_eq("T3.byzantine",   {31'b0, byzantine_ok}, 32'd1);
        if (ira === IRA_A) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("  FAIL T3.ira"); end

        // T4. Pairs 0,1 valid DISAGREEING → FUCKED
        set_slots(IRA_A, IRA_B, ZERO, ZERO, ~IRA_A, ~IRA_B, ZERO, ZERO);
        wait_for_resweep;
        $display("T4 (2 valid disagreeing): state=%0d, agreement=%b", state, agreement_ok);
        expect_eq("T4.state",        {29'b0, state},        32'd1);
        expect_eq("T4.agreement_ok", {31'b0, agreement_ok}, 32'd0);

        // T5. Pairs 0,1,2 valid agreeing → DEGRADED-1 (state 3)
        set_slots(IRA_A, IRA_A, IRA_A, ZERO, ~IRA_A, ~IRA_A, ~IRA_A, ZERO);
        wait_for_resweep;
        $display("T5 (3 valid agreeing): state=%0d, valid_count=%0d", state, valid_count);
        expect_eq("T5.state",       {29'b0, state},       32'd3);
        expect_eq("T5.valid_count", {29'b0, valid_count}, 32'd3);

        // T6. All 4 pairs valid agreeing → HEALTHY (state 4)
        set_slots(IRA_A, IRA_A, IRA_A, IRA_A, ~IRA_A, ~IRA_A, ~IRA_A, ~IRA_A);
        wait_for_resweep;
        $display("T6 (HEALTHY): state=%0d, valid_count=%0d", state, valid_count);
        expect_eq("T6.state",       {29'b0, state},       32'd4);
        expect_eq("T6.valid_count", {29'b0, valid_count}, 32'd4);
        if (ira === IRA_A) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("  FAIL T6.ira"); end

        // T7. 1 corrupt + 3 valid agreeing → DEGRADED-1
        set_slots(IRA_A, IRA_A, IRA_A, IRA_A, IRA_B, ~IRA_A, ~IRA_A, ~IRA_A);
        wait_for_resweep;
        $display("T7 (1 corrupt + 3 valid): state=%0d, corrupt=%b, valid=%b",
                 state, pair_corrupt, pair_valid);
        expect_eq("T7.state",          {29'b0, state},      32'd3);
        expect_eq("T7.valid_count",    {29'b0, valid_count}, 32'd3);
        expect_eq("T7.corrupt0",       {31'b0, pair_corrupt[0]}, 32'd1);

        // T8. Lowest-valid-pair ira recovery: pair 0 corrupt, pair 1 valid
        set_slots(IRA_A, IRA_B, ZERO, ZERO, IRA_B, ~IRA_B, ZERO, ZERO);
        wait_for_resweep;
        $display("T8 (pair 0 corrupt, pair 1 valid): ira=%h", ira);
        expect_eq("T8.state", {29'b0, state}, 32'd1);
        if (ira === IRA_B) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("  FAIL T8.ira"); end

        // T9. Degenerate A=0, B=all-ones — popcount sanity must reject
        set_slots(ZERO, IRA_A, IRA_A, IRA_A, ONES, ~IRA_A, ~IRA_A, ~IRA_A);
        wait_for_resweep;
        $display("T9 (degenerate A=0/B=ones in pair 0): state=%0d, corrupt=%b",
                 state, pair_corrupt);
        expect_eq("T9.state",          {29'b0, state},           32'd3);
        expect_eq("T9.pair0_corrupt",  {31'b0, pair_corrupt[0]}, 32'd1);
        expect_eq("T9.pair0_valid",    {31'b0, pair_valid[0]},   32'd0);

        // T10. A=ones/B=ones → CORRUPT (tightened virgin requires all-zero)
        set_slots(ONES, IRA_A, IRA_A, IRA_A, ONES, ~IRA_A, ~IRA_A, ~IRA_A);
        wait_for_resweep;
        $display("T10 (A=ones/B=ones pair 0): state=%0d, virgin=%b, corrupt=%b",
                 state, pair_virgin, pair_corrupt);
        expect_eq("T10.state",          {29'b0, state},           32'd3);
        expect_eq("T10.pair0_virgin",   {31'b0, pair_virgin[0]},  32'd0);
        expect_eq("T10.pair0_corrupt",  {31'b0, pair_corrupt[0]}, 32'd1);

        // T11. Low-popcount slot A (popcount=8 < 32) → CORRUPT
        set_slots(256'h0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_00FF, IRA_A, IRA_A, IRA_A,
                  ~256'h0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_00FF, ~IRA_A, ~IRA_A, ~IRA_A);
        wait_for_resweep;
        $display("T11 (low-popcount A pair 0): state=%0d, corrupt=%b", state, pair_corrupt);
        expect_eq("T11.state",          {29'b0, state},           32'd3);
        expect_eq("T11.pair0_corrupt", {31'b0, pair_corrupt[0]}, 32'd1);

        // Summary
        $display("");
        $display("=== %0d pass / %0d fail ===", pass_count, fail_count);
        if (fail_count == 0) $display("  *** PASS ***  classifier matches IRA.md 5-state spec");
        else                  $display("  *** FAIL ***  see diagnostics above");
        $display("");
        $finish;
    end

    // Safety timeout — generous for the 11 scenarios at 5000 cycles each
    initial begin
        #5_000_000;
        $display("");
        $display("  *** TIMEOUT *** ");
        $finish;
    end

endmodule
