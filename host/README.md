# PIPE host-side tools (Rust)

PC-side software for talking to a PIPE-enabled FPGA over a single bidirectional wire. Drives the wire via a USB-GPIO bridge (FT232H spare ACBUS pin during prototype; whatever the production system uses later).

The host:

1. Watches the wire for the heartbeat (idle 1010 alternation, half from enclave releases, half from host's own pull-downs).
2. Initiates a challenge by deviating from its idle (release a host-slot to assert 1).
3. Sends 256 bits of challenge in its slots.
4. Watches enclave's slots for the unexpected-1 marker that signals MAC-incoming.
5. Receives 256 bits of MAC.
6. Verifies `MAC == BLAKE3_keyed(challenge || nonce, key)` against the enrolled key.

Slot-partitioned full duplex: even wire bits = enclave, odd wire bits = host. Each side at half wire rate. Recovery is plain wire-read on the other side's slots — no XOR. See [ferros/PIPE.md](../../ferros/PIPE.md) for protocol details.

## Status

Stub. Real implementation pending PIPE-wire RTL (shift_tx, shift_rx, cdc) and a free FPGA pin allocated in the LPF.

## Plan

- Single Rust binary (`pipe-host` crate)
- FT232H driver crate (TBD: pure Rust via `nusb` + manual MPSSE, or `libftdi`-binding) — preference will lean pure Rust to match ferros's no-C-deps ethos
- Host runs on whatever target architecture (Linux x86, macOS aarch64) — host code is `std`, not `no_std`
- Bit-bang ACBUS5 (or chosen GPIO) at ~1-10 MHz to match enclave's wire baud
- BLAKE3 verification via the `blake3` crate (matches `ferros_vault::anchor`)

## Toolchain

- Rust stable (1.94+ per ferros's Cargo lock)
- Standard `cargo build --release` produces a single static binary, no runtime deps

## Why Rust

- Zero Python (slow, dependency-prone, no compile-time checks)
- Compiled binary, easy to ship
- Matches ferros's stack — host-side BLAKE3 verification reuses the same crate the enclave's reference implementation maps to
- Memory safety on a protocol parser is worth having
