// =============================================================================
// top_pipe_silicon.v — Sky130-targeted production digital top (no FPGA primitives)
// =============================================================================
//
// This is the silicon-target top-level: just the digital portion of PIPE that gets synthesized through OpenLane → Sky130 → GDS. Distinct from top_pipe_ira.v (the FPGA emulation with OLED + keypad) and top.v (the empty stub).
//
// External pins (production package — SOT-23-5 or DFN-3 candidate):
//   clk        — from custom ring_osc analog block on-die (not in this RTL)
//   reset_n    — POR derived from CFGPOR-style counter (not in this RTL)
//   ring_in    — 16 entropy ring outputs from custom analog block(s)
//   pipe_pad   — single bidirectional data pin (the entire PIPE wire interface)
//
// What lives OUTSIDE this RTL (custom analog or top-level wrappers):
//   - 16 ring oscillators (custom inverter chains with (* keep *) hints)
//   - 3 other entropy sources (metastability, TERO, subthreshold inverter) — optional, added at top of ring_in[]
//   - Power-on reset generation
//   - Pad cells + ESD
//   - OTP burn voltage generation (charge pump)
//   - Bandgap reference
//
// What this RTL synthesizes:
//   - trng (round-robin per-ring health, Claim 3c)
//   - blake3_tree + blake3 (conditioner)
//   - chaos_amp_v2 (cipher)
//   - otp + inverted_pair_verify (identity storage)
//   - ira_fsm (provisioning ceremony)
//   - boot_fsm (one-way state transitions)
//   - codec + slot_clk + ping_pong + wire_io (PT L1/L2/L3)
//   - prng (protocol-side entropy)
//   - key_register (identity key fan-out=1 invariant)
//
// =============================================================================

`timescale 1ns / 1ps

module top_pipe_silicon (
    input  wire        clk,         // from custom ring_osc (~enclave_clk rate)
    input  wire        reset_n,     // POR
    input  wire [15:0] ring_in,     // 16 raw ring oscillator outputs (free-running)

    // single bidirectional data pin — split into separate in/out/oe at top of file for OpenLane synthesis, then bonded to one inout pad in the chip-level wrapper
    input  wire        pipe_in,
    output wire        pipe_out,
    output wire        pipe_oe      // 1 = drive pipe_out, 0 = tristate (pull-down quiesces line)
);

    // =========================================================================
    // PLACEHOLDER — full integration of the production blocks is a separate
    // task. This top exists so OpenLane has a known entry point and the
    // OpenLane config + flow can be exercised. Once the blocks are wired up
    // properly, replace this section with the real instantiations:
    //
    //   trng u_trng (...);
    //   blake3_tree u_blake3 (...);
    //   chaos_amp_v2 u_chaos (...);
    //   otp u_otp (...);
    //   inverted_pair_verify u_verify (...);
    //   ira_fsm u_ira (...);
    //   boot_fsm u_boot (...);
    //   slot_clk u_slot (...);
    //   codec u_codec (...);
    //   ping_pong u_pp (...);
    //   wire_io u_wire (...);
    //   prng u_prng (...);
    //   key_register u_key (...);
    //
    // For now: minimum-wiring placeholder so the OpenLane flow has something
    // to synthesize end-to-end. This lets us validate the tooling install
    // BEFORE wrestling with the full integration logic.
    // =========================================================================

    // Trivial heartbeat so the synthesizer doesn't strip everything
    reg [23:0] heartbeat_cnt;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) heartbeat_cnt <= 24'd0;
        else          heartbeat_cnt <= heartbeat_cnt + 24'd1;
    end

    // Fold ring_in into the heartbeat so synthesis can't drop the input
    wire ring_fold = ^ring_in;

    assign pipe_out = heartbeat_cnt[23] ^ ring_fold ^ pipe_in;
    assign pipe_oe  = heartbeat_cnt[22];

endmodule
