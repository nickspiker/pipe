# PIPE enclave reference (Rust)

The enclave-side primitive that the silicon implements. This Rust crate is
the **bit-exact reference**: whatever the Verilog computes must match this,
verified by the test-vector generator.

```
mac = BLAKE3_keyed(key, chaos_amp(64-byte input))
```

- `key` — 256-bit secret in the silicon's write-once register
- `input` — 64-byte block; semantics (domain separation, request ID,
  challenge, mode bit, boot_nonce binding) are kernel responsibility
- `mac` — 256-bit output transmitted on the wire

## Two stacked security properties

- **chaos_amp** — provably lossy beyond heat-death by counting
  (12 rounds × 80 bits path entropy = 2⁹⁶⁰ paths, plus 72 bits of
  irrecoverable destruction via popcount). Auditable: count the ops.
- **BLAKE3 keyed** — cryptographic uniformity (avalanche, no statistical
  artifacts in the final MAC). Empirical: cryptanalysis-resistant to date.

Both must fall to break the MAC.

## Layout

```
src/
  lib.rs                      — top-level API
  chaos_amp.rs                — Dragonfly chaos amp v1
  mac.rs                      — pipe_mac primitive
  bin/
    gen_test_vectors.rs       — emits hex vectors for tb_chaos_amp.v
```

## Run

```
cargo test --release          # 8 tests; avalanche + round-const verification
cargo run --release --bin gen-test-vectors > vectors.txt
```

## Why a separate Rust crate

The silicon is too slow to iterate on. Algorithm is settled in Rust first
(fast tests, statistical property checks, easy to find design issues like
the v0 bit-flip absorption that turned up in avalanche testing). Once Rust
passes, port to Verilog and validate against the same vectors. Single source
of algorithmic truth for both implementations.

Future: a `pipe-host` crate (separate, in `pipe/host/`) will depend on this
crate to verify enrolled MAC fingerprints during attestation. This crate
stays minimal — pure algorithm, no I/O.
