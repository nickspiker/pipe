# PIPE — Patent Claims (draft placeholder)

## Independent claim (broadest)

A processing enclave **physically isolated** from a host system, comprising:

- A self-contained timing source consisting of a combinational ring oscillator inside the enclave fabric (no external clock input, no governed timebase).
- A write-once secret register, the output of which connects to exactly one consumer (a keyed cryptographic hash core inside the enclave) and to no other element.
- A boot sequence that transitions, in a single direction, from entropy accumulation through key derivation and locking into an operational state from which no transition exits except by full power loss.
- A single bidirectional communication line shared with the host, on which the enclave continuously emits a heartbeat pattern when idle, either party initiates communication by emitting a single bit that violates the heartbeat pattern, and exchanged data consists of cryptographically authenticated output without additional framing or encoding.

## Dependent claims (isolation embodiments)

The enclave of [independent claim], wherein the physical isolation between enclave and host is achieved by:

- **Photonic isolation** — optocoupler or fiber-optic link.
- **Galvanic isolation** — magnetic transformer.
- **Inductive coupling** — air-core or ferrite inductor pair.
- **Capacitive coupling** — discrete capacitor pair.

(Each of the above is a separate dependent claim.)

## Status

Placeholder. Patent provisional pending; combined with ISOMEM and ORACLE per [ferros/ORACLE.md](../../ferros/ORACLE.md).
