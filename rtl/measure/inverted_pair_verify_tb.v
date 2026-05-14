// =============================================================================
// inverted_pair_verify_tb.v — exercise the 5-state classifier
// =============================================================================
// Drives the combinational inverted_pair_verify module with a series of
// hand-crafted slot configurations and checks that state, valid_count,
// agreement, and recovered ira match the IRA.md spec.
// =============================================================================

`timescale 1ns / 1ps

module inverted_pair_verify_tb;

    localparam SLOT_BITS = 256;

    reg  [8*SLOT_BITS-1:0] slot_flat;
    wire [3:0]             pair_virgin, pair_valid, pair_corrupt;
    wire [2:0]             valid_count, state;
    wire                   all_virgin, agreement_ok, byzantine_ok;
    wire [SLOT_BITS-1:0]   ira;

    inverted_pair_verify #(.SLOT_BITS(SLOT_BITS)) dut (
        .slot_flat   (slot_flat),
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

    // Helpers — pack slots 0..7 into the flat input.
    task automatic set_slots(
        input [SLOT_BITS-1:0] s0, s1, s2, s3,
        input [SLOT_BITS-1:0] s4, s5, s6, s7
    );
        begin
            slot_flat = {s7, s6, s5, s4, s3, s2, s1, s0};
        end
    endtask

    // Test scoreboard
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

    localparam [SLOT_BITS-1:0] ZERO   = {SLOT_BITS{1'b0}};
    localparam [SLOT_BITS-1:0] ONES   = {SLOT_BITS{1'b1}};
    localparam [SLOT_BITS-1:0] IRA_A  = 256'hC0FFEE_DEADBEEF_C0FFEE_DEADBEEF_C0FFEE_DEADBEEF_C0FFEE_DEADBEEF;
    localparam [SLOT_BITS-1:0] IRA_B  = 256'hFEEDFACE_BAADF00D_FEEDFACE_BAADF00D_FEEDFACE_BAADF00D_FEEDFACE_BAADF00D;

    initial begin
        $display("");
        $display("=== inverted_pair_verify 5-state classifier ===");

        // ------------------------------------------------------------------
        // T1. All slots zero — should be VIRGIN (state 0)
        // ------------------------------------------------------------------
        set_slots(ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO);
        #1;
        $display("T1 (all-zero): state=%0d, valid_count=%0d, virgin=%b",
                 state, valid_count, pair_virgin);
        expect_eq("T1.state",       {29'b0, state},      32'd0);
        expect_eq("T1.valid_count", {29'b0, valid_count}, 32'd0);
        expect_eq("T1.all_virgin",  {31'b0, all_virgin},  32'd1);

        // ------------------------------------------------------------------
        // T2. Pair 0 valid (A=IRA_A, B=~IRA_A), others zero (virgin)
        //     1 valid + 3 virgin — should be FUCKED (state 1, <2 valid)
        // ------------------------------------------------------------------
        set_slots(IRA_A, ZERO, ZERO, ZERO, ~IRA_A, ZERO, ZERO, ZERO);
        #1;
        $display("T2 (1 valid + 3 virgin): state=%0d, valid_count=%0d",
                 state, valid_count);
        expect_eq("T2.state",       {29'b0, state},      32'd1);
        expect_eq("T2.valid_count", {29'b0, valid_count}, 32'd1);

        // ------------------------------------------------------------------
        // T3. Pairs 0,1 valid agreeing — DEGRADED-2 (state 2)
        // ------------------------------------------------------------------
        set_slots(IRA_A, IRA_A, ZERO, ZERO, ~IRA_A, ~IRA_A, ZERO, ZERO);
        #1;
        $display("T3 (2 valid agreeing): state=%0d, valid_count=%0d, ira=%h",
                 state, valid_count, ira);
        expect_eq("T3.state",       {29'b0, state},        32'd2);
        expect_eq("T3.valid_count", {29'b0, valid_count},   32'd2);
        expect_eq("T3.byzantine",   {31'b0, byzantine_ok},  32'd1);
        if (ira === IRA_A) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("  FAIL T3.ira"); end

        // ------------------------------------------------------------------
        // T4. Pairs 0,1 valid DISAGREEING — FUCKED (state 1, no agreement)
        // ------------------------------------------------------------------
        set_slots(IRA_A, IRA_B, ZERO, ZERO, ~IRA_A, ~IRA_B, ZERO, ZERO);
        #1;
        $display("T4 (2 valid disagreeing): state=%0d, agreement=%b",
                 state, agreement_ok);
        expect_eq("T4.state",        {29'b0, state},        32'd1);
        expect_eq("T4.agreement_ok", {31'b0, agreement_ok}, 32'd0);

        // ------------------------------------------------------------------
        // T5. Pairs 0,1,2 valid agreeing — DEGRADED-1 (state 3)
        // ------------------------------------------------------------------
        set_slots(IRA_A, IRA_A, IRA_A, ZERO, ~IRA_A, ~IRA_A, ~IRA_A, ZERO);
        #1;
        $display("T5 (3 valid agreeing): state=%0d, valid_count=%0d",
                 state, valid_count);
        expect_eq("T5.state",       {29'b0, state},      32'd3);
        expect_eq("T5.valid_count", {29'b0, valid_count}, 32'd3);

        // ------------------------------------------------------------------
        // T6. All 4 pairs valid agreeing — HEALTHY (state 4)
        // ------------------------------------------------------------------
        set_slots(IRA_A, IRA_A, IRA_A, IRA_A, ~IRA_A, ~IRA_A, ~IRA_A, ~IRA_A);
        #1;
        $display("T6 (HEALTHY): state=%0d, valid_count=%0d, ira=%h",
                 state, valid_count, ira);
        expect_eq("T6.state",       {29'b0, state},        32'd4);
        expect_eq("T6.valid_count", {29'b0, valid_count},  32'd4);
        if (ira === IRA_A) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("  FAIL T6.ira"); end

        // ------------------------------------------------------------------
        // T7. Pair 0 corrupt (A=IRA_A, B=IRA_A — XOR=0 wait that's virgin)
        //     Try: A=IRA_A, B=IRA_B (random other value) — XOR=something
        //     other than all-ones → corrupt. Others valid agreeing.
        // ------------------------------------------------------------------
        set_slots(IRA_A, IRA_A, IRA_A, IRA_A, IRA_B, ~IRA_A, ~IRA_A, ~IRA_A);
        #1;
        $display("T7 (1 corrupt + 3 valid): state=%0d, corrupt=%b, valid=%b",
                 state, pair_corrupt, pair_valid);
        // 3 valid agreeing on IRA_A → DEGRADED-1
        expect_eq("T7.state",       {29'b0, state},      32'd3);
        expect_eq("T7.valid_count", {29'b0, valid_count}, 32'd3);
        expect_eq("T7.corrupt0",    {31'b0, pair_corrupt[0]}, 32'd1);

        // ------------------------------------------------------------------
        // T8. Lowest-valid-pair ira recovery: pair 0 corrupt, pair 1 valid
        // ------------------------------------------------------------------
        set_slots(IRA_A, IRA_B, ZERO, ZERO, IRA_B, ~IRA_B, ZERO, ZERO);
        #1;
        $display("T8 (pair 0 corrupt, pair 1 valid): ira=%h", ira);
        // valid_count = 1 → FUCKED (state 1). ira fallback = slot[1] = IRA_B.
        expect_eq("T8.state", {29'b0, state}, 32'd1);
        if (ira === IRA_B) pass_count = pass_count + 1;
        else begin fail_count = fail_count + 1; $display("  FAIL T8.ira: got %h, expected %h", ira, IRA_B); end

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("");
        $display("=== %0d pass / %0d fail ===", pass_count, fail_count);
        if (fail_count == 0) $display("  *** PASS ***  classifier matches IRA.md 5-state spec");
        else                  $display("  *** FAIL ***  see diagnostics above");
        $display("");
        $finish;
    end

endmodule
