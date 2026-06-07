// ============================================================================
// blake3.v -- BLAKE3 compression core (PORT-INTERFACE STUB)
// ============================================================================
//
// PORT-INTERFACE STUB. The full BLAKE3 reference implementation is published at:
//
//   O'Connor, J., Aumasson, J.-P., Neves, S., and Wilcox-O'Hearn, Z., "BLAKE3: one function, fast everywhere," BLAKE3 Team, 2020.
//   Specification: github.com/BLAKE3-team/BLAKE3-specs
//   Reference code: github.com/BLAKE3-team/BLAKE3
//
// This stub depicts the port interface by which the chip-side modules invoke a single BLAKE3 compression.
// The full round function (G-mixing function, 7-round Blake2-derived permutation, 256-bit chaining value initialization, tree-hashing chunk concatenation) is omitted from this appendix as it is published prior art not material to the novelty of the present invention.
//
// USAGE: assert `valid` together with a 256-bit `chain` chaining value, 512-bit `mblock` message block, 32-bit `numbytes` byte count, and 32-bit `dflags` domain-separation flags.
// `hash` and `done` are asserted by the core when the compression completes.
// Multiple compressions are chained by the caller (this stub is a single-compression core; tree-mode concatenation is the caller's responsibility).
//
// ============================================================================

`timescale 1ns / 1ps

module blake3 (
    input  wire         clk,
    input  wire         reset_n,

    input  wire         valid,
    input  wire [255:0] chain,
    input  wire [511:0] mblock,
    input  wire [31:0]  numbytes,
    input  wire [31:0]  dflags,

    output wire [511:0] hash,
    output wire         done
);

    // Reference implementation omitted. See cited specification.
    // The hash output is the 512-bit BLAKE3 compression of mblock under chaining value chain, with the specified byte count and domain flags.

endmodule
