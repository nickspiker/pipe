// =============================================================================
// top_ring_scheduler_synth.v — Fmax bench for ring_scheduler.v (Variant A)
// =============================================================================
//
// Wraps a single ring_scheduler instance in a self-restart harness. 16 LFSRs with distinct seeds drive ring_in[15:0], so the scheduler sees 16 independently-pseudorandom streams.
//
// Outputs:
//   led      — toggles each completed full 16-ring KOHI
//   ext_led  — XOR-fold of the healthy-ring mask (kept alive by ring_health output dependency, so synthesis cannot optimize away the health logic)
//
// Resource report = full round-robin per-ring health monitoring for all 16 rings (one shared ring_health.v + scheduler FSM + per-ring verdict mask).
//
// =============================================================================

`timescale 1ns / 1ps

module top_ring_scheduler_synth (
    input  wire clk,         // P6 (25 MHz crystal); nextpnr targets this
    input  wire reset_n,     // R7 user button (active-low pull-up)
    output reg  led,         // T6 (active-low) — toggles per full KOHI
    output wire ext_led      // T2 — XOR-fold of ring_health_mask
);

    // ---- 16 LFSR sample drivers ------------------------------------------
    reg  [15:0] lfsr [0:15];
    wire [15:0] lfsr_fb;
    wire [15:0] ring_in;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_lfsr
            assign lfsr_fb[gi] = lfsr[gi][15] ^ lfsr[gi][13] ^ lfsr[gi][12] ^ lfsr[gi][10];
            assign ring_in[gi] = lfsr[gi][0];
        end
    endgenerate

    integer li;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (li = 0; li < 16; li = li + 1)
                lfsr[li] <= 16'hACE1 + li[15:0] * 16'h0BAD;
        end else begin
            for (li = 0; li < 16; li = li + 1)
                lfsr[li] <= {lfsr[li][14:0], lfsr_fb[li]};
        end
    end

    // ---- self-restart logic ----------------------------------------------
    reg          start_r;
    reg          started;
    wire         all_done;
    wire [15:0]  ring_enable_unused;
    wire         sample_bit_unused;
    wire         sample_valid_unused;
    wire         busy_unused;
    wire [15:0]  ring_health_mask;
    wire [4:0]   ring_health_cnt_unused;

    ring_scheduler dut (
        .clk              (clk),
        .reset_n          (reset_n),
        .start            (start_r),
        .ring_in          (ring_in),
        .ring_enable      (ring_enable_unused),
        .sample_bit       (sample_bit_unused),
        .sample_valid     (sample_valid_unused),
        .busy             (busy_unused),
        .all_done         (all_done),
        .ring_health_mask (ring_health_mask),
        .ring_health_cnt  (ring_health_cnt_unused)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            start_r <= 1'b0;
            started <= 1'b0;
            led     <= 1'b1;
        end else begin
            start_r <= 1'b0;
            if (!started) begin
                start_r <= 1'b1;
                started <= 1'b1;
            end else if (all_done) begin
                start_r <= 1'b1;
                led     <= ~led;
            end
        end
    end

    // XOR-fold the 16-bit healthy mask down to one bit so synthesis preserves it
    wire [7:0] xf8 = ring_health_mask[15:8] ^ ring_health_mask[7:0];
    wire [3:0] xf4 = xf8[7:4]                ^ xf8[3:0];
    wire [1:0] xf2 = xf4[3:2]                ^ xf4[1:0];
    assign ext_led = xf2[1] ^ xf2[0];

endmodule
