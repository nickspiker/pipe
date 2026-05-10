//! PIPE enclave-side reference implementation.
//!
//! This crate is the bit-exact spec for what the silicon computes. The Verilog implementation in `rtl/chaos_amp.v` must match this Rust code on every input; `gen-test-vectors` emits hex vectors for the Verilog testbench to validate against.
//!
//! PIPE silicon is a *primitive*, not a protocol:
//!
//! ```text
//! ragu = BLAKE3_keyed(key, chaos_amp(64-byte input) || input)
//! ```
//!
//! - `key` is the 256-bit secret in the silicon's write-once register
//! - `input` is whatever the kernel hands the silicon — semantics are policy
//! - `ragu` is the 256-bit output transmitted on the wire
//!
//! Domain separation, freshness, request identity — all caller responsibility. The silicon doesn't interpret the input. Same convention as `blake3::keyed_hash(key, input)`.
//!
//! # Two stacked security properties
//!
//! - **chaos_amp**: provably lossy beyond heat-death by counting (path explosion + information destruction)
//! - **BLAKE3 keyed**: cryptographic uniformity (avalanche, no statistical structure in the output)
//!
//! Both must fall to forge a ragu. The chaos amp's hardness is auditable (count the paths, count the destroyed bits). The BLAKE3 layer's hardness is conjectural but well-validated.

pub mod chaos_amp;
pub mod chaos_amp_v2;
pub mod ragu;

pub use chaos_amp::{chaos_amp, ChaosState};
pub use chaos_amp_v2::{chaos_amp_v2, ChaosStateV2};
pub use ragu::ragu;
