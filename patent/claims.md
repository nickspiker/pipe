# PIPE — Patent Claims (draft, 2026-05-13)

## Architectural Context — Photon Transport (PT)

PIPE is the chip-level embodiment of a broader transport architecture called **Photon Transport (PT)**. PT is a medium-agnostic protocol stack whose upper layers (framing, message format, cryptographic session) apply identically over single-wire (PIPE), USB-C (ferros host), fiber, or any other physical medium. Only the medium and line code change between embodiments.

**The PT stack, bottom to top:**

| Layer | Function | Claim coverage in this filing |
|---|---|---|
| **L0 — Medium** | Single bidirectional wire + pull-down (PIPE) / USB-C differential pair (ferros host) / fiber / etc. | Claims 1, 2 (single-wire, 3-pin package) |
| **L1 — Line code** | Bit-to-medium encoding | Claim 12 (mirror-XOR, single-wire embodiment) |
| **L2 — Framing** | Message boundaries on a stream-coded channel | Claim 12a (leading-zero suppress + trailing-1 marker) |
| **L3 — Message format** | Structured payload + cryptographic envelope | Claim 13 (5-purpose ephemeral pubkey + ciphertext + trailing 1) |
| **L4 — Crypto session** | ECDH key agreement + AEAD + identity binding | Claim 11 (entropy delivery + ira/wairua binding) |

Each layer has one job and is independently replaceable. PT-over-USB-C reuses L2–L4 unchanged and swaps L0–L1 for the standard USB physical layer and line code. PT-over-fiber reuses L2–L4 and uses an optical L0 with NRZI or similar at L1. The novel single-wire mirror-XOR embodiment of L1 (Claim 12) is the chip-level instantiation.

**Where PT improves on OSI:**

The OSI seven-layer model is widely taught but doesn't match real-world protocol architecture. Specific failures relevant to PT:

- **OSI forgets L0.** OSI starts at L1 ("physical") which already conflates the medium (copper, fiber, air, vacuum) with signaling on it. The medium itself is a first-class design parameter — impedance and parasitics in copper constrain achievable line codes; chromatic and modal dispersion in fiber constrain symbol rate; multipath fading in air constrains modulation. PT acknowledges L0 explicitly because PIPE's entire architecture hinges on it (single-wire-with-pull-down is the medium that makes Claim 12's mirror-XOR possible).
- **OSI's L1 is overloaded.** OSI lumps medium, modulation, line code, and framing into one layer. PT splits these into separately-replaceable L0 (medium), L1 (line code), and L2 (framing).
- **OSI's L5 ("session") is fictional.** No widely-deployed protocol has a clean L5 referent — session establishment happens at L4 (TCP), L6 (TLS), or L7 (application) depending on the stack. PT collapses session establishment into the first message exchange, with no separate session-setup phase.
- **OSI has no home for authentication.** Authentication appears at L2 (802.1X), L3 (IPSec), L4 (TLS), and L7 (HTTP Basic / OAuth) in real stacks — each incompatible with the others. PT places authentication structurally in L3's message format (Claim 13's implicit-authentication property): correct decryption to a structurally-valid plaintext is the authentication signal, with no separate field or round trip.

PT is a five-layer model (L0–L4), each layer with one job, each independently replaceable. OSI is a seven-layer model with two fictional layers (L5–L6), no home for authentication, and a conflated L1.

**Session-establishment cost comparison:**

Establishing an authenticated, identity-bound channel in the conventional TCP/IP stack requires, in order:

1. DHCP DISCOVER → OFFER → REQUEST → ACK — 4 messages, no authentication
2. ARP request/reply — 1–2 messages, no authentication
3. DNS query/response — 1+ messages (often many for full resolution), no authentication
4. TCP SYN → SYN-ACK → ACK — 3 messages, no authentication
5. TLS 1.3 handshake (ClientHello → ServerHello+Cert+KeyShare → Finished) — minimum 3 messages, more for older versions
6. Application authentication (HTTP Basic / Bearer / OAuth flow) — 1–4 additional round trips

**Total: ~12–18 messages, multiple round trips, end-to-end identity binding only after the final application-layer step.**

PT:

1. Host transmits one inverted slot pair (the handshake event of Claim 7b) — 1 bit on the wire
2. Device responds with one 256-bit message (ephemeral pubkey + ciphertext + trailing 1 per Claims 12a + 13) — 256 bits on the wire

**Total: 1 tx + 1 rx.** Successful decryption authenticates the device by Claim 13's structural-validity property, the response is bound to the device's persistent identity by Claim 11's ira binding, and the entropy delivered in the response seeds the host CSPRNG. End-to-end authenticated, identity-bound, entropy-delivering — in two messages, one of which is a single bit. The TCP/IP stack has no comparable primitive at any layer.

---

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

A cryptographic authentication device packaged in a **three-pin surface-mount enclosure** (such as the SOT-23 industry-standard package, approximately 3 mm × 1.4 mm in body dimensions) comprising:

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
- **Per-ring health-check counters**, each accumulating one or more running statistics of its corresponding ring's samples;
- **A combined output bit per sampling edge**, formed by the bitwise XOR of all N sampled bits;
- **A buffer accumulating the combined output bits** across multiple sampling edges;
- **A cryptographic conditioner** applied to the accumulated buffer at completion, producing a fixed-width output;

wherein the device declares entropy collection failed if fewer than a predefined threshold K of the N rings pass their health checks, and refuses to operate in this failed state.

### Claim 3a — Avoidance of fast-samples-slow regime

The TRNG of Claim 3, wherein the sampling clock is selected to be slower than every entropy ring such that, between consecutive sampling edges, each entropy ring undergoes at least 100 oscillation cycles, ensuring that each sample captures the ring in essentially random phase (slow-clock-samples-fast-clock regime) and avoiding the deterministic-pattern output produced when a fast clock samples a slow signal.

### Claim 3b — Single buffer, per-cycle XOR

The TRNG of Claim 3, wherein the per-cycle bitwise XOR of all N samples is written to a single shared buffer rather than to N parallel buffers, reducing memory area by approximately N× while preserving per-ring fault attribution via the independent per-ring health counters.

### Claim 3c — Layered per-ring health check (RCT + APT + iterated GF(2) differencing)

The TRNG of Claim 3, wherein each ring's per-ring health monitoring comprises three concurrently-evaluated checks, the ring being declared healthy if and only if all three pass:

- **Repetition Count Test (RCT)** per NIST SP 800-90B §4.4.1: a counter tracking the length of the current run of identical samples, reset on each sample-to-prior-sample transition and incremented otherwise, with the ring declared unhealthy if the run length ever exceeds a threshold C derived from the claimed per-sample min-entropy H (e.g., C = ⌈α / H⌉ for α = 30, giving false-positive rate ≈ 2⁻³⁰). RCT directly detects stuck-at faults and arbitrarily-long-run failures from a single sample observation.

- **Adaptive Proportion Test (APT)** per NIST SP 800-90B §4.4.2: at the start of each window of W samples (e.g., W = 512 or 1024) the device captures the current sample as reference value A, and over the remaining W−1 samples increments a counter on each occurrence of value A, with the ring declared unhealthy if the final count exceeds a threshold derived from H and W. APT detects sustained per-window bias even when no individual run is long enough to trigger RCT.

- **Iterated GF(2) differencing predictability check** comprising K ≥ 4 (e.g., K = 6) successive derivative levels, wherein:
  - level 0 is the raw sample stream from the ring;
  - level k for 1 ≤ k ≤ K is the bitwise XOR of consecutive samples of level k−1 (each level produced by a single XOR gate and one flip-flop register);
  - a popcount counter accumulates the count of 1-bits in each level's stream over a measurement window of length W;
  - the ring is declared healthy on this metric if and only if each level's popcount lies within a tight tolerance of W/2, specifically within W/2 ± J·σ where σ = √W/2 and J (e.g., J = 4) is the per-level z-score threshold;

wherein the K-level iterated differencing detects any periodic pattern with period at most 2^K (because a sequence of period 2^k collapses to the all-zeros sequence after k successive XOR-with-predecessor operations, driving that level's popcount far below the W/2 ± J·σ band), and detects bias and stuck-at failures by way of level-0 and level-1 deviation from W/2.

The combination of RCT (instantaneous long-run detection), APT (windowed bias detection per the standards-mandated test), and iterated GF(2) differencing (multi-scale periodicity and balance detection) catches the failure modes that any individual first-order statistic (plain popcount, plain toggle count, or either alone) would miss — most notably balanced structured patterns such as the periodic sequence `0000011100000111…` which passes simple popcount and toggle thresholds despite carrying near-zero per-sample entropy.

The primary threat model is **physical degradation of the silicon entropy source** — manufacturing variation, aging, near-resonance with the sampling clock, and stuck-at faults — under normal user-controlled operation. As a structural side benefit, the same layered checks substantially raise the bar for **physical extraction attacks** in which an adversary has gained device custody and attempts to coerce predictable entropy output via environmental manipulation (voltage glitching, clock-injection, thermal forcing, EMI illumination): any such manipulation that successfully steers the ring oscillator toward a stuck, biased, or periodic output state is detected by RCT, APT, or one of the K iterated-differencing levels respectively, causing the device to mark the affected ring(s) unhealthy and, if the count of healthy rings falls below the Byzantine threshold of Claim 3d, enter the silent-wire state of Claim 9a. The adversary therefore cannot extract predictable output from a captured device by environmental coercion: any successful coercion is converted by the health-check layer into refusal to operate, leaving the adversary with no usable channel even with full physical control of the silicon.

### Claim 3d — Byzantine-tolerant ring-set health threshold

The TRNG of Claim 3, wherein the threshold K of healthy rings required for entropy collection to succeed is set to approximately N/2 (e.g., 8 healthy rings of 16 total), such that:

- The device tolerates the failure of up to N − K individual rings without rejecting the entropy gather, preserving function across silicon-aging and partial-defect failure modes;
- The per-ring failure probability budget is mathematically derivable from N, K, and the desired chip-failure rate (with N=16 and K=8, a per-ring failure rate up to approximately 0.8% keeps the per-chip failure rate below 10⁻¹⁵ per gather event);
- The output entropy remains cryptographically uniform whenever at least one ring is healthy, because XOR of independent sources is uniform whenever any single XOR input is uniform.

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

### Claim 9a — Silent-wire FUCKED state (no-heartbeat as honest signal)

The device of Claim 6 and Claim 7, wherein upon any intrinsic silicon-level health failure — including but not limited to: failure of the per-ring TRNG health check of Claim 3 such that fewer than the threshold K rings pass; failure of the inverted-pair OTP verification of Claim 4 such that fewer than the Byzantine-majority number of pairs verify; or an interrupted OTP burn ceremony — the device permanently ceases driving the bidirectional data pin and emits no heartbeat pattern, such that:

- The wire remains at its pull-down resistor's quiescent level, indistinguishable from an absent or unpowered device, with no information leakage about which fault occurred;
- The transition to the silent-wire state is caused only by silicon-level physical truth conditions (broken rings, corrupt OTP, interrupted burn), never by any protocol command, host-authenticated message, or input bit pattern, preserving the indestructible-from-outside property of Claim 6;
- The OTP and internal state remain intact and electrically readable for forensic analysis if the device is decapsulated, but cannot be altered through the pin interface;
- The host's natural retry or alert behavior on detecting no response correctly identifies the device as non-functional without distinguishing whether it is broken, unpowered, or removed.

### Claim 9b — Host-asks-only state reporting

The device of Claim 2, wherein the device never proactively reports its internal state on the bidirectional data pin and instead:

- The heartbeat pattern conveys only a binary alive/dead signal (present and alternating, or absent), with no information content beyond bare existence;
- Any state information (e.g., current 5-state classification of Claim 4, ring-health bitmap of Claim 3c, popcount band of Claim 3) is computed continuously inside the device but is exposed on the wire only in response to an explicit host-initiated attestation request;
- The attestation response is a cryptographic derivation (e.g., a domain-separated keyed hash) that obscures raw register fields rather than transmitting them in the clear;
- No periodic state pings, no wakeup advertisements, no spontaneous notifications of any kind are emitted, eliminating timing-based and frequency-based side-channels that proactive state reporting would create.

### Claim 10 — wairua/ira parallel architecture

The device of Claim 4a, wherein the device implements two parallel identity-storage backends:

- A **persistent backend** (the OTP) holding an identity value (`ira`) committed once at first-permanent-attestation;
- An **ephemeral backend** (the RAM, structured identically to the OTP) holding a session-scoped value (`wairua`) regenerated by entropy gathering at session handshake;

wherein cryptographic operations requiring per-session uniqueness derive their working keys from a domain-separated mixture of `wairua` and (if provisioned) `ira`, and the ephemeral backend's failure to verify causes the session to halt and require a fresh handshake without re-running entropy gathering on the ephemeral backend silently.

### Claim 11 — Single-bit-in, 256-bits-out clean-entropy delivery

The device of Claims 3, 7, 7b, and 10, wherein the act of completing a session handshake on the bidirectional data pin both (a) invariably triggers a fresh KOHI entropy gather of Claim 3 and (b) causes the first response message in the new session to be a cryptographically-conditioned derivation containing the freshly-gathered entropy, such that:

- A host requesting fresh hardware entropy from the device need transmit only **one inverted slot pair** (the handshake event of Claim 7b) within the prescribed clean-idle envelope, with no command opcode, no command structure, and no protocol-stack negotiation;
- The device's response, transmitted as a 256-bit message per Claim 7a, is a domain-separated cryptographic derivation of the form `BLAKE3("ferros-pipe/handshake" || ira || wairua)` where `wairua` is the 256-bit value just produced by KOHI per Claim 10, providing the host with 256 bits of physically-fresh, BLAKE3-conditioned, ira-bound entropy;
- The same single-bit handshake event simultaneously establishes session-key material **and** delivers entropy to the host, eliminating the need for any separate "entropy request", "RNG read", or "get-random" command in the wire-level protocol;
- The output is authenticated by the protocol's keyed-hash chain per Claim 7 and bound to the device's persistent identity per Claim 4, enabling the host to verify that the entropy originated from this specific device's silicon entropy source rather than from a man-in-the-middle attacker;
- The device sustains no damage and incurs no persistent-state cost from repeated entropy requests beyond the negligible cycle count consumed by each KOHI's ring oscillation, with the per-request latency bounded above by user-perceptible delay (~110 ms at the design enclave_clk rate) and below by the entropy-gather requirement of Claim 3;
- This property — minimum-protocol-complexity hardware entropy delivery — provides operating systems and other host-side cryptographic consumers with a kernel-CSPRNG seeding interface achievable by transmitting one bit and receiving one 256-bit message, on a single bidirectional data pin, with no host-side bus initialization, authentication phase, or structured response parsing of the kind universally required by prior-art secure-element products with separate "GET_RANDOM" or "RNG_READ" commands.

### Claim 12 — Mirror-XOR line code (100%-efficient, DC-balanced, self-clocking single-wire bidirectional signaling)

A bidirectional single-wire line code wherein each party transmits in alternating time slots, encoding each bit as the XOR of its own idle value, its current data bit, and the most recently decoded bit from the opposite party, providing automatic DC balance within one slot pair, 100% encoding efficiency with no stuffing or expansion, and continuous clock recovery from idle pattern transitions — all as mathematical consequences of the encoding rule, requiring no additional mechanism.

Encoding rule (applied identically at both ends):

```
wire_value = OWN_IDLE XOR own_data XOR other_last_decoded_data
```

With idle assignments `enclave_idle = 1`, `host_idle = 0`, the line code has the following provable mathematical properties, all arising from the single XOR operation above without separate mechanisms:

- **100% encoding efficiency per direction.** Each slot carries exactly one data bit from its owning party. No bit stuffing, no symbol expansion (no 4B/5B, 8B/10B, 64B/66B), no lookup tables, no scramblers. Asymptotic overhead in the limit of a continuous data stream is zero.
- **Automatic DC balance per slot pair.** The cross-coupling term `other_last_decoded_data` in the encoding rule mathematically forces one party's slot value to compensate the other party's prior data transmission. Any active data bit on one side propagates as a pattern inversion across the slot pair; DC balance is restored within two slots of any data activity, with no balance-encoding overhead.
- **100% transition density in idle.** With both data streams at zero, the encoding rule produces the strict alternation `1, 0, 1, 0, …` on the wire (enclave slots HIGH, host slots LOW). Every slot transitions, providing continuous clock recovery on the receiving side without any separate clock wire, without Manchester encoding's 50% efficiency penalty, and without scrambler-based transition guarantees.
- **No active components beyond a single XOR gate.** The encoding rule is a 3-input XOR per slot, applied identically and statelessly at both ends (each side need only register the most recent decoded bit from the other party). All three properties — efficiency, DC balance, and clock recovery — fall out of the same operation, not as separately-engineered mechanisms.

Comparison to prior-art line codes on the three axes simultaneously:

| Line code | Bit-level efficiency | DC balance mechanism | Clock recovery mechanism |
|---|---|---|---|
| NRZ + bit stuffing (USB) | <100% (stuffed) | approximate, per-window | bit-stuff-induced transitions |
| Manchester / biphase | **50%** (2 line transitions per data bit) | per-bit, by encoding | mid-bit transition |
| 4B/5B (FDDI, USB 1.1 LS) | 80% | per-symbol, by lookup | 5-bit symbol transitions |
| 8B/10B (USB 3.0, GbE, PCIe Gen1/2) | 80% | per-symbol, by lookup with running-disparity tracking | guaranteed transitions per 10-bit symbol |
| 64B/66B (10GbE, USB4) | 97% | per-block, by scrambler | 2-bit sync header |
| 128B/130B (PCIe Gen3) | 98.5% | per-block, by scrambler | 2-bit sync header |
| **Mirror-XOR (this claim)** | **100% per direction** | **per slot pair, by XOR cross-coupling — free** | **per slot in idle, by encoding rule — free** |

The novel contribution is the *simultaneity* of all three properties from a single encoding rule. Prior-art line codes achieve any one or two of these by separate engineered mechanisms (lookup tables for balance, scramblers for transitions, stuffing or symbol expansion for either); mirror-XOR achieves all three by mathematical consequence of the cross-coupled XOR.

### Claim 12a — Zero-overhead message framing via leading-zero suppression and trailing-1 marker

The line code of Claim 12, wherein messages of fixed length L are transmitted with provably zero framing overhead in expectation over uniformly-random message content (such as the BLAKE3-conditioned output of Claim 3), by:

- The sender omitting all leading zeros of the message and beginning transmission at the first 1 bit;
- The sender appending exactly one trailing 1 bit at the end of the message as the only frame marker;
- The receiver buffering the entirety of the message-length window, detecting the trailing 1, and prepending leading zeros to reconstruct the original L-bit message.

For uniformly-random message content (the regime of cryptographic hash outputs and conditioner extracts):

- The expected number of leading zeros omitted is 1 (geometric distribution with p = 0.5);
- The trailing 1 marker adds exactly 1 bit;
- Net expected framing overhead = 0 bits per message.

This is the **minimum-possible framing overhead** for distinguishable variable-content fixed-length messages on a stream-coded channel: a delimiter of less than 1 bit is information-theoretically impossible for any non-trivial frame boundary, and the trailing-1 scheme achieves exactly this minimum on average across the uniformly-random regime that the device's outputs naturally occupy.

### Claim 12b — Float-high full-full duplex via wired-OR with own-contribution subtraction

The line code of Claim 12, in a further embodiment wherein both parties transmit simultaneously in every slot (eliminating the slot-alternation constraint), such that:

- The single bidirectional wire is wired-OR: pulled HIGH if either party actively drives HIGH, otherwise pulled LOW by the shared pull-down resistor;
- Each party knows its own transmitted value (`own_drive`) and reads back the wire (`wire_value`) on the same slot;
- Each party recovers the other party's transmitted bit by `other_data = wire_value XOR own_drive` (extraction of the other party's contribution by subtracting one's own known contribution);
- The effective data throughput per wire is doubled relative to the slot-alternating embodiment of Claims 7 and 12, while preserving Claim 12's 100% per-direction efficiency, automatic DC balance, and zero clock-recovery overhead — with the DC-balance mechanism in this embodiment realized via either (i) transition-based encoding wherein data is encoded as toggles rather than levels, or (ii) differential physical topology, either of which preserves average 50% line duty cycle in the presence of uniformly-random simultaneous data from both parties.

### Claim 13 — Five-purpose message format: ephemeral pubkey simultaneously providing key transport, decryption material, authentication, DC balance, and frame leading edge

The protocol of Claims 7 and 12, wherein each message transmitted on the bidirectional data pin is structured as:

```
[ephemeral pubkey, K bits, with leading-zeros suppressed]
[encrypted message body, M bits]
[single trailing 1 bit]
```

and wherein the ephemeral pubkey field of K bits (e.g., K = 256 for a standard elliptic-curve ephemeral) is the sole framing structure of the message and simultaneously fulfills five functions arising from the composition of the line code of Claim 12 with the cryptographic protocol:

1. **Key transport.** The K-bit pubkey is the sender's ephemeral public key for an ECDH-style key agreement with the receiver's static private key (or per-session static key per Claim 10's wairua/ira derivations), enabling the receiver to derive the symmetric key under which the encrypted message body was sealed.

2. **Decryption material.** The same K-bit field is the *only* information the receiver needs (in combination with its own private key) to decrypt the message body. No separate key-ID, key-version, or key-selector header is required because each message carries its own ephemeral pubkey.

3. **Implicit authentication.** Because only a sender in possession of the ephemeral private key corresponding to the transmitted pubkey could have produced ciphertext that decrypts under the agreed shared key, successful decryption to a structurally-valid plaintext authenticates the sender by construction. No separate MAC field, no explicit signature, no challenge-response handshake — wrong-key or tampered ciphertext decrypts to garbage, which the receiver discards silently per Claim 9a. Optional integrity hash inside the ciphertext is available for the user's threat model but not required for the basic authentication property.

4. **DC balance on the wire.** A uniformly-distributed ephemeral pubkey (such as a standard curve-point-uniform-encoded ECDH ephemeral) has approximately 50% one-bit density. Combined with the mirror-XOR line code's mathematical DC-balance guarantee from Claim 12, the entire on-wire transmission of the message has statistical line-state distribution indistinguishable from the idle pattern. A passive wire observer cannot distinguish "transmitting an authenticated encrypted message" from "wire idle" by statistical analysis of the wire's voltage levels, transition density, or DC offset.

5. **Frame leading edge.** The leading-zero-suppression rule of Claim 12a applies to the pubkey field: transmission begins at the first 1 bit of the pubkey, omitting any leading zeros (which are reconstructed by the receiver from the prevailing idle state). The leading 1 bit is therefore the unambiguous start-of-message marker, and combined with the trailing-1 marker of Claim 12a forms the complete framing structure of the message without any separate framing bytes, sync words, or length headers.

The novel contribution is the simultaneity of all five functions in a single K-bit field, exploiting the composition of (i) the line code of Claim 12, (ii) the framing scheme of Claim 12a, (iii) standard ECDH-based hybrid encryption, and (iv) the silent-failure policy of Claim 9a. Prior-art secure-element protocols (e.g., ATECC608A, A71CH, Optiga Trust M, TPM 2.0) use separate fields for each function: command-frame headers and length fields for framing, key-selector or key-handle bytes for key transport, separate MAC or signature fields for authentication, and either don't address line-level DC balance or rely on PHY-layer line codes (NRZI, 8B/10B) with separate DC-balance mechanisms. PIPE collapses all of these into one 256-bit ephemeral pubkey that does five jobs.

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

2. **File a US provisional application** capturing Claims 1-13 plus dependent claims 3a-d, 4a, 7a-b, 9a-b, 12a-b. Provisional doesn't require formal claim format; allows ~12 months to mature into a non-provisional. Cost ~$140 (micro entity) to ~$1600 (large entity).

3. **Optionally, file a PCT** application within the priority window for international protection.

4. **Push the repository public only after the provisional is filed**, anchoring the public-disclosure date inside the protection window.

5. **Continuation strategy**: separate continuation applications for (a) the TRNG architecture as a standalone block, (b) the inverted-pair OTP scheme as a standalone block, (c) the wire protocol as a standalone block — to capture wider claim scope across multiple sub-fields.

---

## Status

Updated 2026-05-13 with full architectural claim cluster from the TRNG/IRA/PROTOCOL design freeze. Predecessor placeholder (broad isolation claim, now Claim 1) preserved. Awaiting attorney review and provisional filing.

Updated 2026-05-14 with three additional claims surfaced during implementation work:

- **Claim 3c (layered RCT + APT + iterated GF(2) differencing health check)** — superseded the earlier dual popcount+toggle formulation after observing that balanced structured patterns (e.g., `00000111` repeating, period 8, max run 5, popcount 37.5%) pass simple popcount and toggle thresholds despite carrying near-zero per-sample entropy. The new formulation stacks NIST SP 800-90B's standards-mandated RCT (instantaneous long-run) and APT (windowed bias) with K ≥ 4 levels of iterated GF(2) XOR-differencing, each level having its own popcount counter and tight z-score range check around W/2; this exposes any periodic pattern with period ≤ 2^K as a far-from-W/2 popcount at level k = log₂(period). Estimated silicon cost: ~1800 LUTs total for all 16 rings (≈100 LUTs/ring × 16 rings + standards-test overhead). As a side benefit, the layered checks also defend against physical extraction attacks: an adversary with device custody who attempts to coerce predictable output via voltage glitching, clock injection, thermal forcing, or EMI illumination cannot succeed without producing a stuck, biased, or periodic ring state — all of which the health-check layer detects and converts into the silent-wire refusal-to-operate state of Claim 9a.

- **Claim 3d (Byzantine-tolerant ring threshold)** — operating with a subset of healthy rings rather than requiring all rings to pass relaxes per-ring failure budget by a large factor (roughly C(N, N−K) for threshold K of N rings), enabling silicon to remain functional under partial degradation while preserving cryptographic-grade output uniformity.

- **Claims 9a/9b (silent-wire FUCKED state and host-asks-only state reporting)** — the device's response to internal health failure is to cease driving the wire entirely, producing a level indistinguishable from "absent device" rather than any informative error code. Combined with the policy that state information is never proactively broadcast and is exposed only via cryptographic derivation in response to host-initiated attestation requests, this eliminates an entire class of side-channels (timing-based, frequency-based, and DC-level-based) that informative error reporting would create.

- **Claim 11 (single-bit-in, 256-bits-out clean-entropy delivery)** — surfaced while sketching the OS-side hardware-RNG interface. The handshake event of Claim 7b inherently triggers a fresh KOHI for Claim 10's wairua, and the protocol's first response message after handshake completion is a domain-separated BLAKE3 derivation that exposes that fresh entropy to the host. There is no "GET_RANDOM" command in the protocol because the architectural constraints of Claims 3+7+10 collapse handshake and entropy delivery into the same event. A host transmits one inverted slot pair on a single bidirectional pin and receives 256 bits of cryptographically-conditioned, ira-bound, MAC-authenticated hardware entropy. The minimum-protocol-complexity property — and the structural impossibility of separating "session key derivation" from "entropy delivery" once Claims 3+10 are committed to — is the novel contribution. Comparable secure-element products require I²C/SPI bus initialization, an authentication phase, a separate "GET_RANDOM" / "RNG_READ" command opcode, and structured response parsing — PIPE collapses all of this into a single bit on a single wire.

- **Claim 12 + 12a + 12b (mirror-XOR as a 100%-efficient line code)** — surfaced when comparing PIPE's wire signaling against the published line-code literature. The mirror-XOR encoding rule `wire_value = OWN_IDLE XOR own_data XOR other_last_decoded_data`, originally framed as a wire-protocol convention in Claim 7, is in fact a novel single-wire bidirectional line code that simultaneously achieves three properties prior-art line codes pay separately for: (i) 100% per-direction bit-level efficiency with no stuffing or symbol expansion; (ii) automatic DC balance per slot pair via the cross-coupled XOR feedback term (no lookup tables, no running disparity); (iii) 100% transition density in idle via the alternating slot-ownership pattern (no scrambler, no Manchester doubling). The three properties are mathematical consequences of the same single XOR operation, not separately-engineered mechanisms — a property no published line code (NRZ+stuffing, Manchester, 4B/5B, 8B/10B, 64B/66B, 128B/130B, scrambled-NRZ-with-sync-header) achieves. Claim 12a additionally captures the leading-zero-suppression + trailing-1-marker framing scheme that achieves provably-zero expected framing overhead on uniformly-random message content (cryptographic hash output, conditioner extracts). Claim 12b captures the float-high full-full-duplex embodiment wherein both parties transmit simultaneously and each recovers the other's bit by subtracting its own known contribution from the wired-OR observation.

- **Claim 13 (five-purpose message format)** — surfaced while sketching the per-message wire format that combines Claim 12's line code with Claim 12a's framing and the protocol's cryptographic layer. Each transmitted message contains exactly one variable-sized field (an ephemeral ECDH-style pubkey of K=256 bits) followed by the encrypted message body and a single trailing 1. That K-bit pubkey field simultaneously provides (1) key transport for hybrid encryption, (2) decryption material self-contained per message, (3) implicit authentication of the sender via the structural-validity property of correct decryption, (4) DC balance on the wire by virtue of its statistical uniformity composed with Claim 12's line code, and (5) the frame leading-edge marker per Claim 12a's leading-zero-suppression rule. Five protocol functions fulfilled by one 256-bit field — no separate framing header, no key-selector byte, no MAC field, no length field, no DC-balance encoding overhead. Prior-art secure-element protocols use separate fields for each function; PIPE collapses them by exploiting the composition of the line code, framing scheme, and crypto layer.

Updated 2026-05-16 with revision of Claim 3c:

- **Claim 3c upgraded from dual popcount+toggle to layered RCT + APT + iterated GF(2) differencing.** The earlier popcount+toggle formulation, while catching stuck and stuck-then-stuck rings, was found to admit a class of balanced structured patterns (e.g., periodic `00000111` with period 8, max run 5, popcount 37.5%, transition rate 25%) that satisfy both first-order statistics yet carry near-zero per-sample entropy. The revised claim stacks three layers: (1) NIST SP 800-90B Repetition Count Test (instantaneous long-run detection, supersedes the worst-case role of popcount and toggle for stuck failures), (2) NIST SP 800-90B Adaptive Proportion Test (windowed bias detection, standards-mandated for certifiable hardware entropy sources), and (3) K ≥ 4 levels of iterated GF(2) XOR-differencing, each level having its own popcount counter with tight z-score range check around W/2; this exposes any periodic pattern with period ≤ 2^K as a level-k popcount far from W/2. Side benefit: the layered checks also frustrate physical extraction attacks — an adversary with device custody who attempts to coerce predictable output via voltage glitching, clock injection, thermal forcing, or EMI illumination cannot succeed without producing one of the patterns (stuck, biased, periodic) that this layer detects and converts into the silent-wire refusal-to-operate state of Claim 9a.

Updated 2026-05-16 (second revision) with **round-robin per-ring health monitoring (Variant A)** for the SOT-23 silicon-area target:

- **Single shared `ring_health` instance + scheduler FSM** rather than 16 parallel instances. The scheduler enables one ring at a time, runs a full W=65,536 sample gather with full statistical power (the layered RCT + APT + iterated GF(2) check from Claim 3c), and advances to the next ring. Total KOHI time = 16 × W = 1.75 s at enclave_clk = 600 kHz, which fits comfortably within the per-session handshake latency budget (sessions are long-lived; KOHI fires per session-establish, not per protocol message). The 1.75 s also fits beneath the Claim 8 TATARI random pre-burn delay envelope for the once-per-lifetime OTP burn.
- **Measured synth cost on ECP5-25F (yosys + nextpnr-ecp5)**: 689 LUT4 + 474 FF + 151 carry cells total (the entire 16-ring health-monitoring subsystem). Compared to a parallel-instance equivalent at 9,280 LUT4 + 3,232 FF, this is a 13× LUT reduction and 7× FF reduction. Fmax 100–106 MHz across placement seeds, providing >150× headroom over the 600 kHz enclave_clk target.
- **Silicon estimate at 28 nm**: ~3,500 standard cells ≈ ~0.01 mm² (versus ~0.10 mm² for parallel). At ~2% of a SOT-23 die area budget, this leaves the rest of the die for BLAKE3, OTP, codec, and wire-protocol logic.
- **The patent claim text is unchanged** — "per-ring health monitoring comprising three concurrently-evaluated checks" applies equally to time-multiplexed and parallel embodiments. Claim language already supports the implementation choice.
