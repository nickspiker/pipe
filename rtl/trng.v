// =============================================================================
// trng.v — True random number generator for the boot secret seed
// =============================================================================
//
// Two ring oscillators at slightly different frequencies:
//   clk_fast — fast ring (e.g., STAGES=5 ≈ 290 MHz on ECP5)
//   clk_slow — slow ring (e.g., STAGES=7 ≈ 200 MHz, or further divided)
//
// On every posedge of clk_slow, sample clk_fast. The frequencies are
// incommensurate, the rings have independent thermal/voltage noise, and the
// flip-flop sampling clk_fast on a clk_slow edge is in violation of setup/hold
// → metastability → resolves to 0 or 1 unpredictably → one bit of entropy.
//
// 256 sampled bits accumulate into entropy[255:0]. When the counter reaches
// 256, `full` asserts (in clk_slow domain) and the shift register stops
// updating (locked). entropy_valid is `full` synced into enclave_clk via
// 2-FF synchronizer for the downstream consumer (boot_fsm).
//
// PIPE rule: ring oscillator instances live in top.v, not here. This module
// takes the clocks as inputs so testbenches can drive them with behavioral
// generators (iverilog can't simulate the LUT4-based ring_osc primitives).
//
// SIM CAVEAT: in simulation, both clocks are deterministic — the captured
// bits are a deterministic function of the chosen periods. Sims validate
// PLUMBING (counter, full flag, CDC sync, output stability), not entropy
// quality. Entropy quality is validated only on real silicon (NIST SP800-90B
// basic tests on the captured 256-bit vector — see design notes section 8).
//
// =============================================================================

`timescale 1ns / 1ps

module trng (
    input  wire         clk_fast,         // from ring_osc #(.STAGES(F)) in top.v
    input  wire         clk_slow,         // from ring_osc #(.STAGES(S)) in top.v, S > F
    input  wire         enclave_clk,      // for CDC sync of valid signal
    input  wire         reset_n,          // active-low POR

    output reg  [255:0] entropy,          // 256b entropy (stable when valid high)
    output wire         entropy_valid     // synced to enclave_clk
);

    // -------------------------------------------------------------------------
    // Capture: sample clk_fast on every posedge of clk_slow.
    // The (* keep *) on the FF prevents synth from optimizing the
    // setup-violating sample away. In sim this is just a normal FF.
    // -------------------------------------------------------------------------
    (* keep = "true" *) reg entropy_bit;
    always @(posedge clk_slow or negedge reset_n) begin
        if (!reset_n) entropy_bit <= 1'b0;
        else          entropy_bit <= clk_fast;
    end

    // -------------------------------------------------------------------------
    // Accumulator: shift-in 256 entropy bits on clk_slow edges, then lock.
    // -------------------------------------------------------------------------
    reg [7:0]  cnt;
    reg        full;
    always @(posedge clk_slow or negedge reset_n) begin
        if (!reset_n) begin
            entropy <= 256'b0;
            cnt     <= 8'b0;
            full    <= 1'b0;
        end else if (!full) begin
            entropy <= {entropy[254:0], entropy_bit};
            cnt     <= cnt + 8'd1;
            if (cnt == 8'd255) full <= 1'b1;
        end
        // When full is asserted, the if-block doesn't execute. entropy and cnt
        // freeze at their final values. No path to clear full short of POR.
    end

    // -------------------------------------------------------------------------
    // CDC: 2-FF sync of `full` into enclave_clk domain.
    // entropy[255:0] is stable in clk_slow domain once full asserts (no further
    // updates). By the time entropy_valid is high in enclave_clk, the data has
    // been stable for at least 2 enclave_clk periods → safe to sample.
    // -------------------------------------------------------------------------
    reg [1:0] full_sync;
    always @(posedge enclave_clk or negedge reset_n) begin
        if (!reset_n) full_sync <= 2'b00;
        else          full_sync <= {full_sync[0], full};
    end

    assign entropy_valid = full_sync[1];

endmodule
