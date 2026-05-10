# PIPE enclave reference (Rust)

The enclave-side primitive that the silicon implements. This Rust crate is
the **bit-exact reference**: whatever the Verilog computes must match this,
verified by the test-vector generator.

```
ragu = BLAKE3_keyed(key, chaos_amp(64-byte input) || input)
```

- `key` — 256-bit secret in the silicon's write-once register
  (eFuse-derived in static mode; eFuse + boot_nonce in session mode)
- `input` — 64-byte block; semantics (domain separation, request ID,
  challenge, mode bit, boot_nonce binding) are kernel responsibility
- `ragu` — 256-bit output transmitted on the wire

## Two stacked security properties

- **chaos_amp** — provably lossy beyond heat-death by counting
  (16 rounds × 80 bits path entropy = ~10⁴⁸² paths in v2, with hundreds
  of bits of irrecoverable destruction via popcount/parity/squeeze).
  Auditable: count the ops.
- **BLAKE3 keyed** — cryptographic uniformity (avalanche, no statistical
  artifacts in the final ragu). Empirical: cryptanalysis-resistant to date.
- **Defense in depth** — the original input is appended to the chaos
  output before BLAKE3-keyed-hashing. Any chaos_amp absorption is
  irrelevant: BLAKE3 sees the input difference directly.

All three layers must fall to forge a ragu.

## Layout

```
src/
  lib.rs                      — top-level API
  chaos_amp.rs                — Dragonfly chaos amp v1 (AES S-box, LUT-heavy, historical)
  chaos_amp_v2.rs             — Dragonfly chaos amp v2 (32-op menu, FPGA-friendly, current)
  ragu.rs                     — `ragu(key, input)` primitive (was `pipe_mac`)
  bin/
    gen_test_vectors.rs       — emits hex vectors for tb_chaos_amp.v
```

## Run

```
cargo test --release          # 14 tests across chaos_amp v1, v2, and ragu
cargo run --release --bin gen-test-vectors -- ../sim   # writes vectors_*.mem
```

## Why a separate Rust crate

The silicon is too slow to iterate on. Algorithm is settled in Rust first
(fast tests, statistical property checks, easy to find design issues like
the v0 bit-flip absorption that turned up in avalanche testing). Once Rust
passes, port to Verilog and validate against the same vectors. Single source
of algorithmic truth for both implementations.

Sister crate `pipe-host` (`pipe/host/`) depends on this one for the
mirror-XOR codec; future ragu verification helpers go there. This crate
stays minimal — pure algorithm, no I/O.
