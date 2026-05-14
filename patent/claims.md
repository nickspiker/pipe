# PIPE — Patent Claims (draft, 2026-05-13)

## Independent Claim 1 (broadest — physical isolation)

A processing enclave **physically isolated** from a host system, comprising:

- A self-contained timing source consisting of a combinational ring oscillator inside the enclave fabric (no external clock input, no governed timebase).
- A write-once secret register, the output of which connects to exactly one consumer (a keyed cryptographic hash core inside the enclave) and to no other element.
- A boot sequence that transitions, in a single direction, from entropy accumulation through key derivation and locking into an operational state from which no transition exits except by full power loss.
- A single bidirectional communication line shared with the host, on which the enclave continuously emits a heartbeat pattern when idle, either party initiates communication by emitting a single bit that violates the heartbeat pattern, and exchanged data consists of cryptographically authenticated output without additional framing or encoding.

### Dependent claims (isolation embodiments)

The enclave of Claim 1, wherein the physical isolation between enclave and host is achieved by:

1a. **Photonic isolation** — optocoupler or fiber-optic link.
1b. **Galvanic isolation** — magnetic transformer.
1c. **Inductive coupling** — air-core or ferrite inductor pair.
1d. **Capacitive coupling** — discrete capacitor pair.
1e. **Resistive coupling** — single direct wire with series resistor and shared ground reference (the FPGA/silicon embodiment).

---

## Independent Claim 2 (size and packaging)

A cryptographic authentication device packaged in a **three-pin enclosure** comprising:

- A power pin (VDD),
- A ground pin (VSS),
- A single bidirectional data pin,

wherein the device contains, on a single integrated-circuit die enclosed within the three-pin package:

(a) An on-chip clock source consisting of one or more ring oscillators, requiring no external timing reference;

(b) An on-chip true-random-number generator comprising a plurality of ring oscillators with mutually-prime stage counts;

(c) An on-chip one-time-programmable (OTP) memory storing an identity value of at least 256 bits, organized redundantly with cosmic-ray-tolerant cross-check encoding;

(d) An on-chip cryptographic hash core sufficient to authenticate messages exchanged on the single bidirectional data pin;

(e) A state machine implementing a wire-level protocol on the single data pin without requiring host-side enumeration, clock signaling, or out-of-band scaffolding.

### Why this is non-obvious over prior art

Comparable secure-element products in 2026 all require ≥6 package pins (typical: 8-pin SOIC/SON for I²C-interfaced secure elements like Microchip ATECC608, NXP A71CH, Infineon Optiga Trust M). Maxim/Analog Devices DS28E15 family uses 1-Wire and achieves 3-pin packaging but is factory-pre-provisioned, has externally-accessible debug commands, uses pulse-width-modulated 1-Wire protocol (vulnerable to timing-based side-channels), and lacks the deferred-identity and indestructible-from-outside features of the device claimed herein.

The combination of (a)+(b)+(c)+(d)+(e) into a single 3-pin package, with the specific architectural features claimed in dependent claims below, is non-obvious because:

1. It eliminates the host-side burden of clock provisioning, multi-wire bus management, and out-of-band reset handling — features universally present in prior-art secure elements.

2. It enables deployment topologies impossible with multi-pin parts: direct soldering to a single trace, drop-in replacement of dumb components with cryptographic-quality identity, and cost-down to passive-component levels for the integrator.

---

## Dependent Claims (architectural specifics)

### Claim 3 — Multi-ring TRNG with slow universal sampler

The device of Claim 2, wherein the on-chip TRNG comprises:

- **N ≥ 5 free-running ring oscillators**, each with a distinct prime stage count, such that the resulting frequencies are mutually incommensurate;
- **A sampling clock** derived from a further ring oscillator and divided down to a frequency at least one order of magnitude slower than the slowest entropy ring;
- **N sampling flip-flops**, each clocked by the sampling clock and capturing one of the N entropy rings on each sampling edge;
- **Per-ring health-check counters**, each accumulating a running popcount of its corresponding ring's samples;
- **A combined output bit per sampling edge**, formed by the bitwise XOR of all N sampled bits;
- **A buffer accumulating the combined output bits** across multiple sampling edges;
- **A cryptographic conditioner** applied to the accumulated buffer at completion, producing a fixed-width output;

wherein the device aborts entropy collection permanently if any per-ring popcount falls outside a predefined acceptable bias range.

### Claim 3a — Avoidance of fast-samples-slow regime

The TRNG of Claim 3, wherein the sampling clock is selected to be slower than every entropy ring such that, between consecutive sampling edges, each entropy ring undergoes at least 100 oscillation cycles, ensuring that each sample captures the ring in essentially random phase (slow-clock-samples-fast-clock regime) and avoiding the deterministic-pattern output produced when a fast clock samples a slow signal.

### Claim 3b — Single buffer, per-cycle XOR

The TRNG of Claim 3, wherein the per-cycle bitwise XOR of all N samples is written to a single shared buffer rather than to N parallel buffers, reducing memory area by approximately N× while preserving per-ring fault attribution via the independent per-ring popcounters.

### Claim 4 — Inverted-pair OTP storage with XOR verification

The device of Claim 2, wherein the OTP memory stores the identity value in **M pairs of slots**, where M ≥ 2, with each pair containing one slot holding the value `X` and a second slot holding `~X` (bitwise inverse), such that:

- Verification consists of computing `slot_A XOR slot_B` per pair and checking whether the result equals all-ones;
- The all-zeros result indicates a virgin (unburned) pair;
- The all-ones result indicates a properly burned pair;
- Any other result indicates corruption or attack;
- The device requires a Byzantine majority of pairs to validate before considering the device provisioned.

### Claim 4a — Identical RAM and OTP verification

The device of Claim 4, wherein an in-memory (RAM) data structure for ephemeral session identity uses the identical M-pair inverted-XOR layout and verification algorithm as the OTP, sharing the same hardware verification module, such that bit-level corruption from cosmic radiation or transient noise is detected with the same logic in both backends.

### Claim 5 — Deferred identity commitment

The device of Claim 2, wherein the device contains no factory-pre-provisioned persistent identity, and the entropy-based identity is generated, conditioned, and burned into OTP **only upon explicit receipt of a permanent-attestation protocol command** from a host via the bidirectional data pin, such that:

- The device is fully functional for ephemeral (temporary) attestation before identity commitment;
- The user (not the manufacturer, distributor, or any prior party) controls the moment of identity commitment;
- Devices in the supply chain remain anonymous until end-user activation;
- Defective devices identified by quality-control attestation testing can be discarded without ever committing identity.

### Claim 6 — Indestructible-from-outside policy

The device of Claim 2, wherein the state machine implementing the wire-level protocol contains:

- **No command, no input sequence, no register value, and no protocol message** that can transition the device into a permanently inoperable state from any operational state;
- **No factory reset or debug command path**;
- **No host-authenticated self-destruct command**;

such that the only paths from operational to permanently-inoperable are: (i) physical destruction; (ii) silicon aging; (iii) interruption of the OTP burn ceremony, in which case the OTP contents are preserved for forensic analysis and the device's silently-bricked state is detectable but not modifiable.

### Claim 7 — Mirror-XOR slot-ownership wire protocol

The device of Claim 2, wherein the wire-level protocol on the single bidirectional data pin operates by:

- **Time-division of slots between host and enclave**, with alternating slot ownership;
- **Asymmetric drive convention**: each party drives the line HIGH only during its own slot when transmitting a logical 1; releases the line (relying on a pull-down resistor) when transmitting a logical 0;
- **DC balance maintained** during both idle and signaling: each pair of consecutive slots contributes the same net charge to the line regardless of whether a logical message is being transmitted;
- **Mirror-XOR coordination**: each party's transmission in its slot is the XOR of (its own idle convention) and (its message bit) and (the prior bit observed in the other party's slot), such that the line continuously appears as alternating high/low transitions even during message transmission, leaving an observer unable to distinguish idle from active states from the line's DC level alone.

### Claim 7a — Padded message framing

The protocol of Claim 7, wherein every message transmitted on the bidirectional data pin is exactly 256 bits in length, framed by at least 256 cycles of clean idle pattern on each side of the message, and where consecutive messages share their boundary pad cycles.

### Claim 7b — Handshake detection

The protocol of Claim 7, wherein session initialization is signaled by a single break from the idle pattern (a single inverted slot pair) embedded within a clean idle envelope of at least 256 cycles before and 256 cycles after, distinguishable from a 256-bit message by the count of inversions within the envelope.

### Claim 8 — Random pre-burn delay

The device of Claim 2, wherein the OTP burn operation is preceded by a random delay derived cryptographically from the same entropy gathered for the value being burned, such that:

- The delay value is unpredictable to an external observer;
- The delay range is bounded such that an attacker observing power consumption cannot reliably time a power-cut to interrupt the burn at a chosen point;
- The delay range is bounded above by user-perceptible latency limits.

### Claim 9 — Ring-enable gating

The device of Claim 3, wherein the ring oscillators are **gated off** by default and enabled only during entropy-gathering operations, such that:

- Quiescent power consumption is reduced by avoiding continuous high-frequency switching;
- Electromagnetic emissions from the entropy source are present only during entropy-gathering;
- Aging rate of the ring transistors is reduced relative to a continuously-running implementation.

### Claim 10 — wairua/ira parallel architecture

The device of Claim 4a, wherein the device implements two parallel identity-storage backends:

- A **persistent backend** (the OTP) holding an identity value (`ira`) committed once at first-permanent-attestation;
- An **ephemeral backend** (the RAM, structured identically to the OTP) holding a session-scoped value (`wairua`) regenerated by entropy gathering at session handshake;

wherein cryptographic operations requiring per-session uniqueness derive their working keys from a domain-separated mixture of `wairua` and (if provisioned) `ira`, and the ephemeral backend's failure to verify causes the session to halt and require a fresh handshake without re-running entropy gathering on the ephemeral backend silently.

---

## Prior art table

| Reference | What it covers | How PIPE differs |
|---|---|---|
| Maxim DS28E15, DS28EL15, DS28E50 (1-Wire authenticators) | 2-3 pin secure auth with preloaded SHA-256 keys | Factory-pre-provisioned; 1-Wire protocol (PWM-coded, timing-attack-prone); has externally-accessible factory commands; no on-chip TRNG of comparable architecture |
| Microchip ATECC608A/B | 8-pin secure element with ECDH/ECDSA | Multi-pin I²C bus; factory-provisioned identity; lock-state can be exploited pre-lock |
| NXP A71CH, SE050 | 8-pin HVSON secure elements | Multi-pin I²C; factory-provisioned; vendor-controlled key injection |
| Infineon Optiga Trust M | 6-pin SON | Multi-pin I²C; factory model |
| TPM 2.0 chips (various vendors) | 28-pin secure modules | Much larger physical envelope; host-driven configuration |
| Intel SGX / ARM TrustZone | Software enclaves | Software-only; no hardware identity in this sense |
| ETH Zurich academic ring-osc TRNGs | Multi-ring entropy primitives | Lab-scale, not packaged products; do not address packaging, OTP storage, or wire protocol |

---

## Filing strategy

1. **Document local invention date** via this file's timestamp + MEGA backup timestamp. (Done by the act of writing this file before any push to public Git.)

2. **File a US provisional application** capturing Claims 1-10 as a first step. Provisional doesn't require formal claim format; allows ~12 months to mature into a non-provisional. Cost ~$140 (micro entity) to ~$1600 (large entity).

3. **Optionally, file a PCT** application within the priority window for international protection.

4. **Push the repository public only after the provisional is filed**, anchoring the public-disclosure date inside the protection window.

5. **Continuation strategy**: separate continuation applications for (a) the TRNG architecture as a standalone block, (b) the inverted-pair OTP scheme as a standalone block, (c) the wire protocol as a standalone block — to capture wider claim scope across multiple sub-fields.

---

## Status

Updated 2026-05-13 with full architectural claim cluster from the TRNG/IRA/PROTOCOL design freeze. Predecessor placeholder (broad isolation claim, now Claim 1) preserved. Awaiting attorney review and provisional filing.
