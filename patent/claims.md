# PIPE — Patent Claims (draft, 2026-05-13)

## Architectural Context — Photon Transport (PT)

PIPE is the chip-level embodiment of a broader transport architecture called **Photon Transport (PT)**. PT is a medium-agnostic protocol stack whose upper layers (framing, message format, cryptographic session) apply identically over single-wire (PIPE), USB-C (ferros host), fiber, or any other physical medium. Only the medium and line code change between embodiments.

**The PT stack, bottom to top:**

| Layer | Function | Claim coverage in this filing |
|---|---|---|
| **L0 — Medium** | Single bidirectional wire + pull-down (PIPE) / USB-C differential pair (ferros host) / fiber / etc. | Claims 1, 2 (single-wire, 3-pin package) |
| **L1 — Line code** | Bit-to-medium encoding | Claim 12 (mirror-XOR, single-wire embodiment) |
| **L2 — Framing** | Message boundaries on a stream-coded channel | Claim 12a (leading-zero suppress + trailing-1 marker) |
| **L3 — Message format** | Structured payload + cryptographic envelope (keyed) or hash-seeded scrambler envelope (keyless) | Claim 13 (5-purpose ephemeral pubkey + ciphertext + trailing 1) / Claim 13a (4-purpose payload-hash + scrambled-payload + trailing 1) |
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
- A boot sequence that transitions, in a single direction, from entropy accumulation thru key derivation and locking into an operational state from which no transition exits except by full power loss.
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
- The OTP and internal state remain intact and electrically readable for forensic analysis if the device is decapsulated, but cannot be altered thru the pin interface;
- The host's natural retry or alert behavior on detecting no response correctly identifies the device as non-functional without distinguishing whether it is broken, unpowered, or removed.

### Claim 9b — Host-asks-only state reporting

The device of Claim 2, wherein the device never proactively reports its internal state on the bidirectional data pin and instead:

- The heartbeat pattern conveys only a binary alive/dead signal (present and alternating, or absent), with no information content beyond bare existence;
- Any state information (e.g., current 5-state classification of Claim 4, ring-health bitmap of Claim 3c, popcount band of Claim 3) is computed continuously inside the device but is exposed on the wire only in response to an explicit host-initiated attestation request;
- The attestation response is a cryptographic derivation (e.g., a domain-separated keyed hash) that obscures raw register fields rather than transmitting them in the clear;
- No periodic state pings, no wakeup advertisements, no spontaneous notifications of any kind are emitted, eliminating timing-based and frequency-based side-channels that proactive state reporting would create.

### Claim 9c — Health-attestation queries via domain-separated Message B exchanges

The device of Claim 9b, wherein internal-state attestation queries are issued by the host as Message B authenticated exchanges per the wire protocol of Claim 7 and the L3 message format described in PROTOCOL.md, with the message_req field set to a **domain-separated cryptographic identifier** of the requested state class, and the device's response computed by the keyed hash core of Claim 2 element (d) over the concatenation of the matched domain identifier and the corresponding internal-state vector. Specifically:

(a) The device maintains a set of one or more recognized query domain identifiers, each a fixed cryptographic constant (e.g., the BLAKE3 hash of a domain-separation string such as `"Kei te ora koe?"` — Māori, "are you well/alive?", BLAKE3 = `c0a6cabf9f69f2aff78b51151e9300cd5bd32dfbbecf550600625478ffee8e80`);

(b) Upon receipt of a Message B exchange whose recovered message_req matches one of the recognized identifiers, the device composes the response as
```
message_resp = BLAKE3.keyed(active_key, matched_domain_identifier || internal_state_snapshot)
```
where `internal_state_snapshot` is a concatenation of internal-state vectors corresponding to the matched query domain — including but not limited to: chip_state classification per Claim 4, ring health bitmap and count per Claim 3c/3d, OTP burn mask per Claim 4, ira_fsm state per Claim 5, session exchange counter, and boot epoch counter;

(c) Upon receipt of a Message B exchange whose recovered message_req does not match any recognized query identifier, the device computes the response as
```
message_resp = BLAKE3.keyed(active_key, message_req)
```
without state-vector inclusion, treating the exchange as an arbitrary content-commitment per Claim 15;

(d) The wire encoding distinguishing query from content-commitment is implementation-specific — in one embodiment a single reserved bit of message_req signals query/content; in another the full hash identifier comparison serves as both signal and selector;

(e) No separate wire opcode, command structure, framing extension, or additional protocol round trip is required to support health-attestation queries — the existing Message B primitive of PROTOCOL.md L3 carries all such queries.

The novel contribution is the **unification of arbitrary-content attestation and internal-state attestation under one wire primitive**, with domain-separated identifiers naming the state class. A host knowing the device's active key may verify the response (recomputing the keyed hash with the same state vector and confirming bit-equality); an eavesdropper observing the wire learns nothing about which state class was queried or what the state values are, because the response is statistically indistinguishable from any other Message B response under the line code of Claim 12. Prior-art secure elements expose state through dedicated GET_STATUS / GET_INFO opcodes with raw register-field returns — leaking state to wire observers and requiring separate protocol primitives per query type — whereas this claim composes state attestation cleanly with the existing message exchange.

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
- **100% transition density in idle.** With both data streams at zero, the encoding rule produces the strict alternation `1, 0, 1, 0, …` in the encoded bit stream of the wire's slot sequence (enclave slots HIGH, host slots LOW). Every slot transitions in the bit stream, providing continuous clock recovery on the receiving side without any separate clock wire, without Manchester encoding's 50% efficiency penalty, and without scrambler-based transition guarantees. *Analog-domain edge timing in the resulting waveform is subject to the driver slew rate, line capacitance, and reflection-settling characteristics of the physical implementation; the encoding-layer transition density is a necessary but not sufficient condition for receiver-side clock recovery, with the latter additionally requiring the analog implementation's edge sharpness to be sufficient for the receiver's sampling precision.*
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
- The effective data thruput per wire is doubled relative to the slot-alternating embodiment of Claims 7 and 12, while preserving Claim 12's 100% per-direction efficiency, automatic DC balance, and zero clock-recovery overhead — with the DC-balance mechanism in this embodiment realized via either (i) transition-based encoding wherein data is encoded as toggles rather than levels, or (ii) differential physical topology, either of which preserves average 50% line duty cycle in the presence of uniformly-random simultaneous data from both parties.

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

4. **DC balance of the encoded bit stream.** A uniformly-distributed ephemeral pubkey (such as a standard curve-point-uniform-encoded ECDH ephemeral) has approximately 50% one-bit density. Combined with the mirror-XOR line code's mathematical bit-stream DC-balance guarantee from Claim 12 (per-slot-pair constant Hamming weight), the encoded bit stream of the wire's slot sequence during message transmission has statistical bit-state distribution indistinguishable from the idle pattern's bit stream. A passive observer who decodes the wire to its bit stream cannot distinguish authenticated-encrypted-message transmission from wire idle by bit-stream statistical analysis. *The corresponding analog-domain wire waveform's DC characteristics additionally depend on the driver electronics' rise/fall asymmetry, the medium's parasitic resonance and ringing behavior, and the pull-down network's linearity; the encoding-layer DC balance is a necessary but not sufficient condition for analog-domain mean-voltage indistinguishability, the latter additionally requiring the physical implementation's analog asymmetries to be small relative to the eavesdropper's measurement precision. Any residual analog-domain distinguishability via direct waveform measurement is a property of the physical implementation rather than of the line code claimed herein.*

5. **Frame leading edge.** The leading-zero-suppression rule of Claim 12a applies to the pubkey field: transmission begins at the first 1 bit of the pubkey, omitting any leading zeros (which are reconstructed by the receiver from the prevailing idle state). The leading 1 bit is therefore the unambiguous start-of-message marker, and combined with the trailing-1 marker of Claim 12a forms the complete framing structure of the message without any separate framing bytes, sync words, or length headers.

The novel contribution is the simultaneity of all five functions in a single K-bit field, exploiting the composition of (i) the line code of Claim 12, (ii) the framing scheme of Claim 12a, (iii) standard ECDH-based hybrid encryption, and (iv) the silent-failure policy of Claim 9a. Prior-art secure-element protocols (e.g., ATECC608A, A71CH, Optiga Trust M, TPM 2.0) use separate fields for each function: command-frame headers and length fields for framing, key-selector or key-handle bytes for key transport, separate MAC or signature fields for authentication, and either don't address line-level DC balance or rely on PHY-layer line codes (NRZI, 8B/10B) with separate DC-balance mechanisms. PIPE collapses all of these into one 256-bit ephemeral pubkey that does five jobs.

**On-chip vs host-side embodiment.** In the preferred on-chip embodiment, the device of Claim 2 implements only the **keyless plaintext variant of Claim 13a** — the chip's silicon does not contain an elliptic-curve scalar-multiplication unit, an ECDH key-agreement primitive, or any other algebraic primitive susceptible to polynomial-time attack by Shor's algorithm. The five-purpose ephemeral pubkey of Claim 13, where required by an embodiment, is generated and consumed **external to the device of Claim 2** — typically in a host-side software stack (CPU, kernel, or trusted-application library) that uses the device's keyed-hash output of Claim 11 as seed material for the ephemeral keypair and any other host-side asymmetric operations. This separation preserves the post-quantum properties of the device claimed under Claim 14 element (d) while permitting hosts to compose the device with elliptic-curve or other asymmetric schemes for compatibility with legacy systems (TLS, blockchain signatures, conventional PKI), without those legacy schemes contaminating the device's own threat surface. The device makes no algebraic-hardness assumption at any internal layer; any such assumption introduced by host-side composition is solely the host's threat-model burden.

### Claim 13a — Keyless plaintext variant: payload hash simultaneously providing framing, DC balance, CSPRNG seed for whitening, and integrity check

The message format of Claim 13, in a further embodiment for transmissions where the sender does not require confidentiality (e.g., publicly-distributed firmware images, public-key material, debug telemetry), wherein the per-message wire structure is:

```
[ leading-zero-suppressed payload-hash | scrambled-payload | trailing 1 ]
```

and wherein:

- The **payload-hash** field of H bits (e.g., H = 256 for BLAKE3) is the cryptographic hash of the plaintext payload. It contains no secret material; the entire transmission is plaintext-recoverable by any wire observer.
- The **scrambled-payload** field is the plaintext payload bitwise-XORed with the keystream of a stream cipher (e.g., ChaCha20) seeded by the payload-hash. Because the payload-hash is uniformly distributed by the cryptographic properties of the hash function, and the stream cipher output is computationally indistinguishable from uniform regardless of seed, the scrambled-payload has approximately 50% one-bit density.
- The receiver decodes the wire, separates the payload-hash and scrambled-payload, descrambles by XORing with ChaCha20(payload-hash), recovers the plaintext, recomputes BLAKE3(plaintext), and compares to the received payload-hash. A match confirms transport integrity; a mismatch indicates wire-level corruption.

The single payload-hash field simultaneously provides four of the five functions of Claim 13's pubkey field, by the same compositional mechanism:

1. **DC balance of the encoded bit stream.** The payload-hash is uniformly distributed by the hash function's properties, and the scrambled-payload is uniformly distributed by the stream cipher's properties. Composed with Claim 12's line code, the encoded bit stream of the entire transmission has statistical bit-state distribution indistinguishable from the idle pattern's bit stream, identically to Claim 13. *The analog-domain wire waveform's DC characteristics depend on the driver electronics' rise/fall asymmetry, the medium's parasitic resonance and ringing behavior, and the pull-down network's linearity per the analog-property hedge of Claim 13 element (4); any residual analog-domain distinguishability via direct waveform measurement is a property of the physical implementation rather than of the line code or framing format claimed herein.*
2. **Frame leading edge.** The leading-zero-suppression rule of Claim 12a applies to the payload-hash field by the same construction as Claim 13.
3. **Integrity checksum.** The payload-hash field functions as a self-attesting tamper-evident integrity check against passive wire errors (noise, glitches, ESD events). The receiver's rehash-and-compare is the integrity signal, occupying no separate field.
4. **CSPRNG seed for whitening.** The payload-hash is reused as the stream cipher seed that produces the uniform-distribution property the scrambled-payload requires for DC balance — replacing the role that the ephemeral pubkey's key-transport-and-decryption function plays in Claim 13's keyed variant. This dual-use is the structural analogue of Claim 13's five-purpose pubkey.

The functions of Claim 13 that are explicitly **not** provided by this variant:

- **No confidentiality.** The transmission is plaintext-recoverable by any wire observer in possession of the standard ChaCha20 specification. This is intentional and is the defining property of the plaintext variant.
- **No authentication against active substitution.** An active adversary in possession of the wire can replace the entire transmission (both payload-hash and scrambled-payload) with a self-consistent forgery, because the integrity check requires no secret. The payload-hash field provides *tamper-evident integrity against passive corruption*, not *cryptographic authentication against active adversaries*. Where authentication is required, the keyed variant of Claim 13 is the appropriate embodiment; alternatively, a digital signature over the payload-hash can be appended as a separate field.

The novel contribution is that four of the five Claim-13 functions (framing, DC balance, integrity, whitening-seed) are obtainable from a single fixed-size hash field of public material, without any shared secret, ephemeral key, or cryptographic envelope — by exploiting the same compositional mechanism that makes Claim 13 work (statistical uniformity of the leading field composed with Claim 12's line code and Claim 12a's framing) and additionally repurposing the integrity-hash as the stream-cipher seed that produces the uniformity property the body field requires. Prior-art line-coded transmission protocols (NRZI-with-CRC, 8B/10B-with-CRC, scrambled-NRZ-with-CRC) provide DC balance and integrity via independent mechanisms (line code + appended CRC field) with strictly additive overhead; this claim provides both from a single shared field at zero additional overhead beyond the integrity check itself. Use cases include single-wire firmware distribution, public-key publication, and telemetry where transport integrity (not adversarial authentication) is the required property.

### Claim 14 (umbrella) — Composite secure communication system integrating silicon trust anchor, post-quantum line code, transparent-hardness hashing, and tamper-evident ceremony with no software-trust gap

A secure communication system, comprising:

(a) **a silicon cryptographic processor** providing a physically-isolated trust anchor as recited in Claim 1, with packaging as recited in Claim 2, said processor exhibiting silent-failure-on-tamper behavior as recited in Claims 6 and 9a, and reporting state only in response to host queries as recited in Claim 9b;

(b) **a multi-ring true random number generator** as recited in Claim 3, with health monitoring per Claims 3c and 3d, providing per-cycle conditioned entropy with statistical health checks performed at the silicon-physics level rather than at a software layer;

(c) **a deferred identity commitment ceremony** as recited in Claim 5, binding the persistent identity of the processor of element (a) to its first-use context, with random pre-burn delay per Claim 8 and ring-enable gating per Claim 9;

(d) **a single-wire bidirectional communication channel** between the cryptographic processor and a host system, employing the line code of Claim 12 with framing of Claim 12a, in some embodiments with full-full duplex per Claim 12b, providing transport without any cryptographic primitive susceptible to polynomial-time attack by Shor's algorithm and providing clock recovery thru constant-state intervals of at least 4096 wire-clock periods as empirically validated in the reference implementation;

(e) **a single-bit-in, 256-bit-out entropy delivery protocol** as recited in Claim 11, providing key material derivable only by parties with prior pairing knowledge of the processor of element (a), structured as the keyless plaintext variant of Claim 13a or, in alternative embodiments, the keyed five-purpose-field variant of Claim 13;

(f) **a transparently-hard cryptographic hash function** providing preimage resistance via combinatorial path explosion of provably-counted operation sequences (rather than via conjectured algebraic hardness), achieving at least approximately 255 bits of classical preimage security and at least 128 bits of quantum preimage security against attacks bounded by Grover's algorithm;

(g) **device-bound at-rest message storage** wherein the device-specific encryption keys are derived from material obtainable only via successful completion of the protocol of element (e) with the cryptographic processor of element (a), such that compromise of the host software or filesystem does not yield the device key absent physical possession of the cryptographic processor of element (a);

wherein the security guarantees provided by elements (a) thru (g) are mutually independent, such that compromise of any single element does not compromise the security guarantees provided by the remaining elements; and wherein the composition of elements (a) thru (g) provides end-to-end communication security from the silicon trust anchor thru the on-wire message format and continuing thru at-rest message storage, with no point in the security chain depending on (i) software-stored secrets, (ii) cryptographic primitives susceptible to polynomial-time quantum attack, or (iii) conjectured (rather than demonstrably-provable) hardness assumptions.

The novel contribution of this claim is the **compositional integration**, rather than any single element thereof. Each element exists in prior-art form in isolation — TPMs provide hardware trust anchors, NIST has standardized post-quantum primitives, memory-hard hashes are documented in the literature, line codes with clock recovery are widely known — but the integrated system providing simultaneously: (i) hardware-rooted trust anchor with tamper-evident silent failure; (ii) post-quantum-by-construction transport, key derivation, and authentication; (iii) transparent (non-conjectural) hardness for both in-transit and at-rest cryptographic operations; and (iv) an unbroken security chain from silicon trust anchor thru application layer with no software-trust gap, is collectively unprecedented in the prior-art secure-communication literature. Prior secure-communication systems achieve at most two of properties (i)-(iv) — typically (i) (via TPM/Secure Enclave) and partial (ii) (via hybrid post-quantum constructions such as Signal's PQXDH) — and none achieve property (iii) for the entire stack or property (iv) without a software-rooted gap at the trust anchor.

---

## Claim 15 (independent) — Hardware-rooted offline provenance attestation via stateless PRF oracle

A method of attesting that arbitrary digital content existed at the prover's election, without disclosing the content, the prover's secret, or any third-party trust anchor, comprising:

(a) computing a **content commitment** by applying a cryptographic hash function (such as BLAKE3) to the content, producing a fixed-width digest;

(b) constructing a **challenge** by applying a cryptographic hash function to a concatenation comprising at least the content commitment and one or more of: a timestamp, a verifier nonce, an unforgeable contemporaneous public value, or a future-evaluable predicate;

(c) submitting the challenge to a **stateless hardware oracle** comprising the device of Claim 2, said oracle producing a response by applying the keyed cryptographic hash core of Claim 2 element (d) using the persistent identity of Claim 4 (or, in alternative embodiments, the ephemeral identity of Claim 10) as the key and the challenge as the input, transmitting the response via the single bidirectional data pin of Claim 2 using the line code and message format of Claims 12, 12a, and 13 (or 13a);

(d) **recording the response prior to any disclosure of the content**, optionally publishing the response to an append-only public log;

(e) at a later time of the prover's election, **revealing the content** and other inputs to the challenge construction such that any verifier may independently reconstruct the challenge, confirm that the recorded response could only have been produced by the device holding the secret of Claim 4, and consequently confirm that the content was in the prover's possession at the time the response was recorded;

wherein, by virtue of the device's properties under Claims 4, 5, 6, 9a, and 11:

1. The oracle's secret is not extractable by any party including the prover (Claim 6: indestructible from outside; Claim 9a: silent-wire on fault);
2. The oracle's secret was generated by physical entropy at first-permanent-attestation rather than provisioned by any manufacturer, distributor, or certificate authority (Claim 5: deferred identity commitment);
3. The oracle retains no record of submitted challenges or emitted responses (Claim 6 implies no persistent state beyond the OTP-committed identity; Claim 9b implies no proactive state reporting);
4. The response is bound by structural cryptographic property to the specific device's IRA, such that no other device — including any device sharing the manufacturer, design, or silicon process — can produce the same response for the same challenge (Claim 11: ira binding);

and wherein the verification of the recorded response is offline and self-contained given (i) the reveal package and (ii) either the ability to subsequently re-query the device or possession of a previously-recorded commitment to the device's identity. **No certificate authority, attestation service, transparency log operator, or other third-party trust anchor is required at attestation time or at verification time.**

### Why this is non-obvious over prior art

The closest commodity equivalents to the use case enabled by this claim are:

| System | Identity origin | Privacy preserved? | Time-binding | Third-party trust required |
|---|---|---|---|---|
| **Adobe C2PA / Content Credentials** | Camera-manufacturer issued certificate | No — metadata is part of capture | Weak (capture timestamp embedded) | Yes — manufacturer CA |
| **OpenTimestamps** | None (timestamp only) | Yes | Yes — via Bitcoin block height | Yes — Bitcoin's PoW economic security |
| **TPM 2.0 attestation** | Manufacturer-issued Attestation Identity Key | No — TPM identity visible | Partial | Yes — manufacturer enrollment authority |
| **Apple "Verified by iCloud"** | Apple Secure Enclave + Apple PKI | No — Apple sees the operation | Yes | Yes — Apple is the third party |
| **RFC 3161 timestamping authority** | TSA's CA-issued certificate | No — TSA sees the hash | Yes | Yes — TSA |
| **Sigsum, Trillian, Certificate Transparency** | Log operator's signing key | Partial | Yes | Yes — log operators + witnesses |
| **This claim** | Physical entropy at first power-on (Claim 5) | Yes — selective disclosure | Composition with Claims 19-21 below | **No** |

The novel contribution is the simultaneous combination of: (i) hardware-rooted secret never provisioned by any external party; (ii) selective disclosure (the response is published *before* the content is revealed); (iii) offline verifiability with no third-party trust anchor; (iv) statelessness on the device side, such that the same device may serve unlimited witnessing operations without persistent state cost. No prior-art system achieves all four simultaneously.

---

## Claim 16 (dependent on 15) — Continuous custody chain via repeated PRF queries on a stable content commitment

The method of Claim 15, performed at each of a plurality of discrete time intervals T_i selected by the prover, with the content commitment H held constant across intervals, each interval producing a response R_i = oracle(challenge constructed from H and T_i), and the resulting sequence of (T_i, R_i) pairs being recorded or published, such that:

(a) the sequence demonstrates continuous device-side possession of the content commitment across the timeline spanned by T_0 through T_n;

(b) the absence of an expected (T_i, R_i) pair at a scheduled interval constitutes evidence of device unavailability at that interval, enabling forensic determination of the device's operational windows;

(c) splicing or insertion of forged (T_i, R_i) pairs into the sequence is computationally infeasible without possession of the device, by Claim 6;

(d) when combined with the timestamping methods of Claims 19 through 21, the chain constitutes a verifiable timeline of continuous custody bounded above and below by external contemporaneous evidence.

This embodiment supports use cases including: proof-of-life heartbeating with cryptographic-quality liveness signaling, dead-man's-switch protocols where chain termination triggers post-conditioned release of secrets to designated parties, and long-duration audit trails for regulated content where chain density determines minimum forgery cost.

---

## Claim 17 (dependent on 15) — Multi-verifier independent witnessing

The method of Claim 15, wherein the challenge construction in Claim 15 step (b) further comprises a per-verifier nonce supplied by each of a plurality of independent verifiers V_1, V_2, …, V_k, such that each verifier's challenge C_k = hash(H || timestamp || verifier_nonce_k) is distinct, and each verifier receives a distinct response R_k = oracle(C_k), such that:

(a) each verifier holds an attestation cryptographically bound to their own session, independent of any other verifier's attestation;

(b) no subset of verifiers can collude to produce evidence binding the prover to a content commitment they did not actually witness, because each forged challenge would require a fresh oracle query;

(c) the prover may witness the same content to mutually-unaware parties (e.g., a journalist, an auditor, a court, and an estate planner) without revealing the existence of the other witnessings, by virtue of the per-verifier nonce mixing into the challenge such that responses are pairwise statistically uncorrelated;

(d) compromise of any one verifier's records does not compromise the integrity of any other verifier's attestation.

The novel contribution is the **independence property**: each verifier's attestation has cryptographic integrity that survives full compromise of any disjoint subset of the verifier set. Prior-art third-party-mediated attestation systems (e.g., timestamping authorities, transparency logs) share a single trust path that, if compromised, undermines all attestations through that path; this claim's per-verifier-nonce construction creates k mutually-isolated attestation paths.

---

## Claim 18 (dependent on 15) — Future-bound conditional reveal

The method of Claim 15, wherein the challenge construction in Claim 15 step (b) incorporates a **future-evaluable predicate** P_t whose value is unknown at the time of oracle query but becomes publicly evaluable at a later time t_eval (such as: "the hash of the Bitcoin block at height N", "the value of the NIST randomness beacon at epoch E", "the closing price of asset A on exchange X on date D"), such that:

(a) the response R = oracle(hash(H || P_t)) is recorded prior to the predicate becoming evaluable;

(b) until t_eval, no party — including the prover and the verifier — can independently confirm or refute that R corresponds to any specific predicate value, because the predicate is part of the challenge construction and its actual value is not yet known;

(c) at t_eval, the predicate value becomes publicly known by mechanisms external to the device (e.g., the Bitcoin block is mined and broadcast, the NIST beacon publishes), at which point any party may reconstruct the challenge and verify the recorded R;

(d) the prover thereby commits, at the time of recording R, to a statement whose disclosure semantics are conditioned on the future evaluation of P_t — a **commit-and-reveal anchored in hardware** without requiring any escrow agent, threshold signature scheme, or other coordination protocol.

This embodiment supports use cases including: sealed-bid auctions (each bidder's bid is committed before the auction closes, revealed afterward), time-locked editorial publication (commit a manuscript to a future publication date), conditional disclosure to estate beneficiaries (release content only after a death certificate is published in a public registry), and game-theoretic commitment devices (publicly bind one's own future action to a present commitment).

---

## Claim 19 (dependent on 15) — Forward time-binding via unforgeable contemporaneous public anchor

The method of Claim 15, wherein the challenge construction in Claim 15 step (b) incorporates an **unforgeable contemporaneous public value** V_τ first published at time τ, such that the device's response R = oracle(hash(H || V_τ || other_inputs)) **could not have been generated by the device before τ**, because the device could not have known V_τ prior to its publication.

Acceptable embodiments of V_τ include but are not limited to:

(i) the block header hash of a proof-of-work blockchain (e.g., Bitcoin) at the most recent confirmed block height — the cost of forging V_τ being equal to the cost of producing an alternate chain of equal or greater accumulated proof-of-work, which is presently estimated to require energy expenditure on the order of 10²¹ joules to overwrite a six-confirmation Bitcoin block;

(ii) a published value of a multi-party randomness beacon employing threshold cryptography (e.g., drand, the League of Entropy beacon), where forgery requires compromise of a threshold of the beacon's signing parties;

(iii) the output of an external, separately-witnessed entropy source whose publication record is contemporaneously verifiable (e.g., the last digit of a published stock-market index closing value at a date-stamped boundary);

(iv) any combination of the above to harden against single-source compromise.

The composition with Claim 15 produces a **forward-bounded** attestation: the verifier confirms `time_of_recording(R) ≥ τ` by virtue of the device's response being computationally inaccessible without prior knowledge of V_τ.

### Claim 19a — Eagle Time embodiment of Claim 19's contemporaneous anchor

The method of Claim 19, wherein the contemporaneous public value V_τ comprises a **measured oscillation count of the hydrogen-1 hyperfine transition** referenced to a defined astronomical epoch and corrected to the barycentric reference frame of the Milky Way-Andromeda galaxy system (or, in alternative embodiments, the solar-system barycenter or other declared inertial reference frame), such that:

(a) V_τ is independently observable by any party with a 21-centimeter-wavelength radio receiver, requiring no infrastructure, certificate authority, blockchain, or centralized authority of any kind;

(b) the time unit ("one Eagle second" or equivalent) is defined as a fixed integer count of oscillations (1,420,407,826 per second per the protium hyperfine transition at the defined reference frame), providing picosecond precision (≈704 picoseconds per oscillation) without floating-point representation drift;

(c) by physical coincidence of the 21-centimeter wavelength with the speed-of-light distance traversed in one oscillation period, the distance-time inequality of Claim 22 below admits an integer formulation: `d_{cm}(L_1, L_2) ≤ 21.1 × ΔN_osc`, where ΔN_osc is the oscillation-count difference between asserted observation events at locations L_1 and L_2;

(d) the reference frame correction (barycentric or equivalent) renders the time measurement frame-independent across all observers within the solar system and surrounding inertial neighborhood, providing the verifiability property required of V_τ across geographically dispersed verifiers without dependence on Earth-rotation-based timekeeping or terrestrial-clock infrastructure (e.g., NTP, GPS, NIST).

The novel contribution of this embodiment is the substitution of **quantum-mechanical and astronomical physical constants** for institutional trust anchors at the time-reference layer. Prior-art time-anchoring schemes for cryptographic attestation universally rely on either (i) a centralized timekeeping authority (NIST, USNO, BIPM), (ii) a satellite-positioning infrastructure (GPS, GLONASS, Galileo, BeiDou), (iii) a blockchain's economic security model (Bitcoin block timestamp, Ethereum block timestamp), or (iv) a federation of trusted clock servers (NTP pool, PTP grandmasters). The hydrogen hyperfine transition is anchored in QED, observable by any radio receiver, and independent of every institutional or infrastructural authority. The Eagle Time epoch is selected at the system designer's election (the embodiment of record uses the Apollo 11 lunar-module landing at 1969-07-20 20:17:40 UTC, an event externally witnessed by approximately 600 million contemporaneous viewers and documented in independently-archived broadcast records); the epoch's specific choice is cryptographically arbitrary and may be re-anchored without altering the time-unit's physical definition.

---

### Claim 19b — Multi-source consensus embodiment of Claim 19's contemporaneous anchor

The method of Claim 19, wherein the contemporaneous public value V_τ comprises a **consensus interval** computed from timestamps obtained from a plurality of independent network time sources, said sources selected from a larger pool of available sources by **cryptographically-random subset selection per query event**, such that:

(a) the pool comprises diverse independent time sources spanning multiple protocols (HTTPS `Date:` headers per RFC 9110, NTP/SNTP per RFC 5905, NTS per RFC 8915, Roughtime per IETF draft, SMTP greeting timestamps per RFC 5321, or any combination), multiple administrative domains (autonomous-system diversity), multiple geographic regions, and multiple operator categories (CDNs, government, broadcasters, universities, central banks, NTP Pool volunteers);

(b) for each query event, a cryptographically-random nonce derived from CSPRNG-quality entropy (such as the device's keyed-hash output of Claim 11) selects a subset S of the pool P, with |S| ≥ a configurable minimum (e.g., 42 sources at "Fast" confidence, 64 at "Thorough", 128 at "Paranoid");

(c) each source i in S responds with a timestamp tᵢ; the prover measures round-trip-time rttᵢ and computes the source's confidence interval [tᵢ − rttᵢ/2, tᵢ + rttᵢ/2];

(d) an outlier-rejection pass removes sources whose intervals do not overlap the median, identifying stale (CDN-cached), lying, or pathologically-slow sources;

(e) the consensus V_τ is reported as an interval bounded by the intersection of surviving intervals, with an explicit confidence bound that shrinks as more sources are added;

(f) an adversary attempting to skew V_τ by pre-positioning false responses must compromise the **unknown random subset** S chosen for any specific query — which requires either knowledge of the prover's CSPRNG nonce (cryptographically infeasible) or simultaneous compromise of a Byzantine fraction of the entire pool P (which is operationally infeasible for diverse pools of practical size).

The novel contribution over single-source contemporaneous anchors is the **substitution of subset-unpredictability for source-trust**: no single source is trusted; the entire system's integrity depends on the adversary's inability to predict and pre-position attacks against the specific random subset chosen per query. This is structurally identical to the trust-elimination property of Claim 23 (no honest-majority assumption) applied at the time-source layer instead of the consensus-node layer.

A working implementation of this claim is provided in the host-side software library `nunc` (referenced in the working codebase), which queries 42–128 randomly-selected sources per query and returns a timestamp with explicit confidence bound. The same pattern admits arbitrary alternative implementations sharing the random-subset-selection-with-outlier-rejection architecture.

### Claim 19c — Trust-free prover-side time verification as precondition for the trust-elimination property

The trust-minimization properties claimed in Claims 15, 19, 20, 21, and 23 are **conditional on the prover possessing means to independently establish wall-clock time without recourse to any single external authority**. Acceptable means comprise at least one of:

(a) **Physical observation of a natural phenomenon** whose value depends only on universal physical constants, such as Claim 19a's measurement of the hydrogen-1 hyperfine transition referenced to a barycentric inertial frame, or analogous embodiments employing other atomic, astronomical, or cosmological observables (e.g., pulsar timing arrays, cosmic-microwave-background-anisotropy fingerprinting, planetary or lunar position measurements corrected for relativistic frame transformation);

(b) **Cryptographically-random multi-source consensus** from a plurality of independent network witnesses as in Claim 19b, with outlier rejection and explicit confidence bound;

(c) **Any combination of (a) and (b)** — for example, online operation using (b) cross-checked against (a) when a 21-centimeter radio receiver is locally available, falling back to (a) alone when offline;

without which means the trust-elimination properties of Claims 15, 19, 20, 21, and 23 collapse into ordinary timestamping-authority-dependent attestation, regardless of the silicon and protocol properties of Claims 1-14.

The novel contribution of this claim is the **explicit acknowledgment that wall-clock-time verifiability is a load-bearing precondition of the entire claim stack**, and the enumeration of the two trust-free embodiment classes (physical observation of natural phenomena; cryptographically-random multi-source consensus) that admit prover-side independent verification. Implementations relying on any single trusted authority for wall-clock time (NIST, USNO, BIPM, GPS satellite constellation, NTP server federations, RFC 3161 timestamping authorities, or any other single point of trust) fall outside the scope of this claim, regardless of the silicon and protocol details of their other layers.

This is the **architectural foundation** of the entire claim stack 1-23: trust elimination is not a property that can be applied at one layer while assuming trusted authorities at adjacent layers. The chip eliminates the manufacturer-identity-CA layer (Claims 5, 6); the protocol eliminates the session-key-distribution layer (Claim 11); the message format eliminates the certificate-and-signature layer (Claim 13a); the attestation primitive eliminates the timestamping-authority layer (Claim 15); the time-binding embodiment must eliminate the wall-clock-authority layer (this claim); and the network-resilience property eliminates the honest-majority layer (Claim 23). Each elimination is necessary for the composition; none is sufficient without the others.

---

## Claim 20 (dependent on 15) — Backward time-binding via append-only public log with verifiable inclusion proofs

The method of Claim 15, wherein the response R (or, in alternative embodiments, the cryptographic hash of a batch comprising R and one or more other responses) is **submitted to an append-only public log** at a publication time τ_pub, such that:

(a) the log produces a verifiable inclusion proof binding R (or the batch root) to a log entry indexed by τ_pub;

(b) the verifier confirms `time_of_recording(R) ≤ τ_pub` by virtue of the inclusion proof, because R could not have been included in the log entry at τ_pub if R did not exist by τ_pub;

(c) when the log supports Merkle-tree batching of many responses into a single anchor commitment (e.g., the OpenTimestamps construction wherein many timestamping requests are aggregated into a single Merkle tree whose root is anchored into a single Bitcoin transaction), the per-response cost of publication amortizes to a negligible fraction of the anchoring transaction cost.

Acceptable embodiments of the append-only public log include but are not limited to:

(i) a proof-of-work blockchain such as Bitcoin, with R or its batch root committed via OP_RETURN or analogous mechanism — providing tamper-resistance equal to the cost of rewriting the blockchain from the anchor block forward;

(ii) a cryptographically-witnessed append-only log such as Certificate Transparency (RFC 6962), Sigsum, or Trillian, with R or its batch root committed as a log entry — providing tamper-resistance equal to the collusion of the log operator with a quorum of witnesses;

(iii) a multi-party gossip protocol with threshold signatures wherein a quorum of independent attestors sign (R, τ_pub) — providing tamper-resistance equal to the corruption of the quorum;

(iv) an RFC 3161-compliant timestamping authority — providing tamper-resistance equal to the corruption of the TSA's CA;

(v) any combination of the above, with the strongest available anchor selected per use-case threat model.

The composition with Claim 15 produces a **backward-bounded** attestation: the verifier confirms `time_of_recording(R) ≤ τ_pub` by virtue of the public log's inclusion proof.

---

## Claim 21 (dependent on Claims 15, 19, and 20) — Bidirectional verifiable time window via composition of forward and backward binding

The method of Claim 15, wherein both the forward-binding of Claim 19 and the backward-binding of Claim 20 are simultaneously applied to the same response R, such that:

(a) the challenge incorporates an unforgeable contemporaneous public value V_τ_low per Claim 19, establishing `time_of_recording(R) ≥ τ_low`;

(b) the response R (or its Merkle batch root) is submitted to an append-only public log producing an inclusion proof at τ_high per Claim 20, establishing `time_of_recording(R) ≤ τ_high`;

(c) the verifier consequently confirms `τ_low ≤ time_of_recording(R) ≤ τ_high`, constituting a **verifiable time window** of width (τ_high − τ_low) within which the recording event provably occurred;

(d) the window width is determined by the prover's choice of (i) the cadence at which fresh V_τ values are obtained (forward-anchor frequency) and (ii) the latency to publication in the append-only log (backward-anchor latency), both of which can be tuned to sub-second precision in practice;

(e) the device's role in this composition is unchanged from Claim 15: the device performs the stateless PRF computation only, and is unaware of the forward or backward anchoring mechanisms in operation — all anchoring machinery resides in the host-side protocol stack.

This composition produces an attestation primitive in which:

- The lower bound τ_low is anchored in the cost of breaking the unforgeable contemporaneous public value (e.g., 10²¹ joules to overwrite Bitcoin's economic security; cosmological-scale resource cost to forge the hydrogen-line measurement of Claim 19a);
- The upper bound τ_high is anchored in the integrity of the append-only public log (e.g., the same Bitcoin economic security if the log is anchored to Bitcoin; the collusion threshold of a witness federation otherwise);
- Neither anchor relies on the chip itself attesting to time — the chip is gullible about time per Claim 15 and makes no temporal claim — but the *composition* with external evidence produces a temporal claim whose strength is bounded by the weaker of the two anchors;
- The system requires no trusted timekeeping authority at any point; both anchors are independently verifiable by any party with access to the underlying physical or cryptographic substrate (a hydrogen-line receiver, a Bitcoin SPV node, a CT log reader, etc.).

This is the **headline composition** of Claims 15-22. Prior-art attestation systems achieve one of the two bounds (Bitcoin's OP_RETURN with OpenTimestamps achieves backward-binding; satellite-time-attested signatures achieve forward-binding partially) but none combine both with full offline verifiability, full hardware-rooted identity binding, and full selective-disclosure privacy in a single composable primitive.

---

## Claim 22 (dependent on Claims 2, 7, 12, and 15) — Locality bounding via line-code-constant response timing and speed-of-light distance limits

A method of bounding the spatial location of the device of Claim 2 with respect to one or more verifier-anchors of known location, comprising:

(a) the verifier-anchor V_a at known location L_a emitting a challenge C onto the bidirectional data pin of the device per the wire protocol of Claim 7;

(b) the verifier-anchor measuring the round-trip time RTT_a between emission of the challenge's first bit and reception of the response's first bit on the wire;

(c) the verifier computing the device's distance bound from L_a as `d(device, L_a) ≤ ½ × (RTT_a − T_compute) × c`, where T_compute is the device's bounded internal computation time between challenge reception and response emission and c is the speed of light in the wire medium (typically 0.6c–0.95c depending on conductor and dielectric);

(d) the bounded computation time T_compute is provably constant by virtue of the line code of Claim 12, which forces every bit of the response to be emitted exactly one slot-time after the corresponding challenge bit is decoded, with no software-controllable variable-latency stage; specifically, the mirror-XOR rule `wire_value = OWN_IDLE XOR own_data XOR other_last_decoded_data` causes each transmitted bit to be a deterministic function of the immediately-preceding received bit, with no opportunity for the prover to introduce latency variation that would inflate the apparent RTT;

(e) at the protocol-level the response is bound to the device's identity by Claim 11, such that the verifier confirms the responding entity is the specific device under attestation rather than a relay or impostor;

(f) consequently, the distance bound `d(device, L_a) ≤ ½ × (RTT_a − T_compute) × c` is a provable upper bound on the device's distance from L_a, **with the proof's tightness limited only by the constancy of the line code's bit-timing and the precision of the verifier's clock**.

For the embodiment of record (enclave_clk ≈ 25 MHz, slot period ≈ 80 ns, T_compute ≈ 1 slot for the keyed-hash core's pipelined response), the distance-bound precision is approximately 12 meters per slot of RTT measurement uncertainty.

### Why this is non-obvious over prior art

The closest prior-art equivalents are distance-bounding protocols in the academic literature:

- Brands and Chaum, "Distance-Bounding Protocols" (1993) — established the speed-of-light framework but assumed an idealized cryptographic responder with zero variable-timing compute;
- Hancke and Kuhn, "An RFID Distance Bounding Protocol" (2005) — practical distance-bounding for RFID with single-bit challenge-response;
- Capkun et al., "Mafia, Distance, and Terrorist Frauds" (various dates 2003–2012) — analyses of fraud classes in distance-bounding;

all of which rely on a critical assumption: that the prover's responder has *bounded and known* compute time between challenge reception and response transmission. Prior-art secure elements (TPMs, ATECC608, A71CH, Optiga Trust M) violate this assumption — their compute-time variance is dominated by software-controlled command processing, bus arbitration, and command-queue depth, none of which are bounded by silicon-physics constraints, and all of which an adversarial prover may manipulate to inflate apparent RTT and thereby overstate apparent distance.

This claim's novelty is the **line-code-physics constancy** of T_compute. The mirror-XOR rule of Claim 12 makes every bit's transmit-time a deterministic function of the previous received bit's decode-time, with no software-controlled latency variation possible at any layer above the line code. The device cannot "go slow" without violating the line-code's mathematical encoding rule, which would be detectable to the verifier as an out-of-band clock-recovery failure. The distance bound therefore reduces to wire-propagation physics + the verifier's clock precision, both of which are externally measurable and not under the prover's control.

### Claim 22a — Multi-anchor trilateration

The method of Claim 22, performed by a plurality of verifier-anchors V_1, V_2, …, V_n at known locations L_1, L_2, …, L_n, each independently computing its respective distance bound d_i, such that the device's location is constrained to the intersection of n balls B(L_i, d_i), this intersection constituting an **upper-bounded location region** within which the device must lie. For sufficient n with verifier-anchors in non-coplanar configuration, the intersection region's volume tends toward zero as the precision of RTT measurement and clock synchronization across anchors improves.

### Claim 22b — Environmental co-witnessing

The method of Claim 22, performed using a shared **ambient physical signal** rather than verifier-emitted challenges, wherein the device and one or more co-located observers each:

(a) receive an ambient signal S(t, location) whose value depends jointly on time and location (such as: ambient radio broadcast modulated by atmospheric conditions, magnetometer readings determined by local geomagnetic variations, accelerometer readings from local seismic activity, optical signals from astronomical sources subject to local atmospheric refraction);

(b) at synchronized intervals, query the oracle of Claim 15 with `BLAKE3(ambient_capture || timestamp || verifier_nonce)` as the content commitment;

(c) the resulting set of responses, each bound to a specific device's IRA per Claim 11 and a specific ambient capture, attests to the joint claim "this device experienced this ambient signal at this time"; co-witnessing observers presenting consistent ambient captures provide independent corroboration of the device's locality at the time of capture.

This embodiment supports use cases where verifier-anchor RTT distance-bounding of Claim 22 is unavailable (e.g., the device is in a distant location with no nearby verifier-anchor infrastructure) but where ambient signals are co-witnessable (e.g., a specific aircraft's ADS-B transmission heard simultaneously by the device and by a reference ADS-B receiver of known location). The locality proof is *via the locality of the ambient signal itself*, transitively binding the device's location to wherever the ambient signal was observable.

---

## Claim 23 (independent) — Non-repudiability-based adversarial resilience without honest-majority assumption

A network attestation system comprising a plurality of devices each instantiating the secure communication system of Claim 14, characterized in that:

(a) each device's persistent identity (Claim 4) is exclusively held by the device's controller, no two devices share an identity, and the identity is unforgeable by parties not in physical possession of the device (Claims 5, 6, 9a);

(b) each device's signed attestations are publicly attestable to that device's identity by any party in possession of (i) the signed message and (ii) a previously-recorded commitment to the device's identity (e.g., a published hash of IRA);

(c) the integrity of any single device's verifiable claims about its own observations is preserved **independently of the fraction of dishonest devices in any region of the network**, provided that condition (a) holds for the honest participant's device and at least one network path exists to any verifier capable of cross-checking the claims against externally-observable evidence (such as the time and locality anchors of Claims 19 through 22);

(d) consequently, the system does not require **honest majority, honest plurality, or any fractional threshold of honest participants at any time** to provide integrity guarantees to any participant; integrity is a property of individual attestations, not of network-wide consensus.

### Why this is non-obvious over prior art

All known Byzantine fault-tolerant consensus systems and all known blockchain consensus systems embed an explicit honest-fraction threshold in their security proofs:

| System | Honest-fraction threshold | Failure mode when threshold breached |
|---|---|---|
| **Practical Byzantine Fault Tolerance (PBFT)** | > 2/3 honest replicas | Liveness lost or safety lost depending on adversary strategy |
| **HotStuff, Tendermint, and BFT variants** | > 2/3 honest validators | Same as PBFT |
| **Bitcoin (Nakamoto consensus)** | > 1/2 honest hash rate | 51% attack — adversary rewrites history |
| **Ethereum proof-of-stake** | > 2/3 honest stake | Finalization stalled or slashed-but-finalized |
| **Solana, Cosmos, Polkadot, Algorand, Cardano (various)** | varies, ≥ 2/3 honest | Comparable failure modes |
| **Centralized timestamping (RFC 3161, BIPM)** | TSA / CA assumed honest | Single point of failure |
| **Federated Byzantine Agreement (Stellar, Ripple)** | quorum slice intersection | Network partition lost |

Every one of these proves its security *contingent on a fractional honesty assumption*. The instant the adversary exceeds the stated threshold, the proof does not degrade — it ceases to apply, and the system's security guarantee disappears.

This claim's novelty is the **absence of any such threshold**. The integrity guarantee is provided per-participant by the unforgeability of that participant's device-rooted signatures, not by network-level honest-fraction arithmetic. The classical Byzantine setting is replaced with a **mechanism-design setting** in which:

(i) Each participant signs at their election; nothing compels them to sign, and nothing compels them to sign accurately;

(ii) Signed lies are permanent and publicly attributable to the device that produced them, by Claims 4, 5, 6, 11;

(iii) Each verifier independently evaluates the consistency of any participant's attestations against externally-observable physics (Claims 19-22) and the participant's own prior attestations (Claim 16);

(iv) The dominant strategy for any participant who anticipates any future verification of their attestations is to sign accurately, because the expected cost of being publicly cryptographically linked to a falsifiable claim exceeds any plausible gain from short-term deception;

(v) Collusion among k dishonest participants does not dilute the cryptographic accountability of any one of them — each colluder signs with their own device's identity, and each colluder's signed lies are independently attributable;

(vi) An honest participant in a region containing arbitrarily many dishonest participants is not bound by, and is not required to engage with, the dishonest participants' consensus; the honest participant operates from their own device's attestations and presents those to any verifier they choose.

The composition of (i)-(vi) yields a system in which:

- **The number of dishonest participants is unbounded.** No fraction threshold exists.
- **The trust model is "each participant trusts their own device".** No participant must trust any other participant or any third party.
- **The verifier's threat model is "evaluate claims against physics and prior attestations".** No network-level voting mechanism enters the security argument.

This is structurally distinct from every prior-art consensus system, every prior-art Byzantine fault-tolerant protocol, and every prior-art timestamping authority. The claim's novelty is the demonstration that **non-repudiable individual hardware-rooted attestation with external evidence cross-check** is *sufficient* for integrity in the adversarial setting, with no honest-fraction assumption of any kind. This is the unique property of the composed system of Claims 1-22 that no prior-art consensus or attestation system can match.

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

Updated 2026-05-31 with **Claims 15-23** capturing the attestation, time-binding, locality, and adversarial-resilience applications surfaced during hardware bring-up of the meal-deal demonstration (FPGA implementation: v1 ceremony + v2 baked-IRA persistence proven on Colorlight 5A-75B ECP5-25F, commit 0d920a0):

- **Claim 15 (independent) — Hardware-rooted offline provenance attestation via stateless PRF oracle.** The composition of Claims 1-14 produces a stateless cryptographic oracle whose key is physically generated by Claim 5's deferred-identity ceremony, whose key never leaves the device by Claim 6's indestructible-from-outside policy, and whose output is bound to that key by Claim 11's ira-binding property. This composition is itself an attestation primitive distinct from any prior secure-element use case: arbitrary content can be witnessed by the oracle, the witness response can be published before the content is revealed, and verification is fully offline and self-contained. The comparison against C2PA, OpenTimestamps, TPM attestation, Apple iCloud verification, RFC 3161 TSAs, and Certificate Transparency demonstrates that no prior commodity attestation system achieves all four of: hardware-rooted secret never provisioned by external party, selective disclosure with response-before-reveal, offline verifiability with no third-party trust anchor, and stateless reusability for unlimited witnessings.

- **Claims 16-18 (dependent on 15) — Continuous custody chains, multi-verifier independent witnessing, future-bound conditional reveals.** Three immediate applications of the Claim 15 primitive that arise from the device's statelessness and the prover's control of challenge construction: (i) repeated queries on a stable content commitment at scheduled intervals produce a tamper-evident timeline of continuous possession, with chain gaps constituting forensic evidence of device unavailability; (ii) per-verifier nonces in the challenge produce mutually-independent witness chains such that compromise of one verifier does not compromise others, supporting use cases like witnessing the same content to a journalist, a court, and an auditor without any of them learning of the others; (iii) future-evaluable predicates in the challenge produce commit-and-reveal primitives whose disclosure is conditioned on the predicate becoming publicly evaluable, without requiring any escrow agent.

- **Claim 19 (dependent on 15) — Forward time-binding via unforgeable contemporaneous public anchor.** The challenge incorporates a public value whose first publication time τ_low cannot be forged or precomputed (Bitcoin block hash, drand beacon output, NIST randomness beacon, or astronomical observation), establishing that the device's response was generated after τ_low because the device could not have known the anchor value before its publication. The forward-binding does not require the device to know what time it is — the device remains stateless and gullible about time — and the temporal claim is enforced at the verifier's evaluation rather than at the device's response generation.

- **Claim 19a — Eagle Time embodiment.** The novel substitution of the 21-centimeter hydrogen-1 hyperfine transition (1,420,407,826 oscillations per second, ~704 picosecond per oscillation, barycentric reference frame) for institutional time-keeping authorities at the contemporaneous-anchor layer. Universal observability by any party with a 21cm receiver eliminates dependence on NIST, USNO, GPS satellite infrastructure, NTP server federations, and proof-of-work blockchain economic security models. The physical coincidence that one oscillation period at this frequency corresponds to the distance light travels in one period (21.1 cm) makes the Claim 22 locality-time inequality reduce to an integer relationship — `d_{cm} ≤ 21.1 × ΔN_osc` — that admits exact verification without floating-point error. The Apollo 11 lunar-landing epoch is selected for its independent witnessing by approximately 600 million contemporaneous viewers and durable broadcast records; the epoch's specific choice is cryptographically arbitrary and may be re-anchored to other independently-witnessed astronomical or cultural events at the system designer's election.

- **Claim 20 (dependent on 15) — Backward time-binding via append-only public log.** Submission of the response (or a Merkle batch root containing many responses) to an append-only public log produces an inclusion proof binding the response to a log entry at publication time τ_high, establishing that the response could not have been generated after τ_high because it would not otherwise be in the log at that index. Acceptable embodiments include proof-of-work blockchains with OP_RETURN anchoring (Bitcoin, OpenTimestamps pattern), cryptographic transparency logs (Certificate Transparency, Sigsum, Trillian), multi-party gossip protocols with threshold signatures, and RFC 3161-compliant timestamping authorities — selected per use-case threat model.

- **Claim 21 (dependent on 15, 19, 20) — Bidirectional verifiable time window.** The composition of forward-binding (Claim 19) and backward-binding (Claim 20) produces a verifiable time window τ_low ≤ time_of_recording(R) ≤ τ_high whose width is determined by the prover's choice of anchor cadence and publication latency. Window widths of sub-second precision are achievable in practice. The chip itself remains stateless and contributes no temporal claim; the temporal property arises from the composition with external anchoring, with security bounded by the weaker of the two anchors. This is the **headline composition** that no prior-art system provides: hardware-rooted identity binding + selective disclosure + bidirectional time window + offline verifiability + no third-party trust anchor at any layer.

- **Claim 22 + 22a + 22b (dependent on 2, 7, 12, 15) — Locality bounding via line-code-constant response timing.** The mirror-XOR line code of Claim 12 makes the device's response-emission time deterministic relative to challenge reception, with no software-controllable variable-latency stage that an adversarial prover could exploit to inflate apparent RTT. The line-code-physics constancy of T_compute is the novel contribution over prior distance-bounding literature (Brands-Chaum 1993, Hancke-Kuhn 2005, Capkun et al. various), all of which assume bounded responder compute time but in practice are deployed atop secure elements whose compute time is software-controllable. Multi-anchor trilateration (Claim 22a) bounds the device's location to the intersection of multiple distance balls; environmental co-witnessing (Claim 22b) attests locality via the locality of an ambient signal that the device and one or more co-witnesses simultaneously observe.

- **Claim 23 (independent) — Non-repudiability-based adversarial resilience without honest-majority assumption.** The unique property of the composed Claim 1-22 system: integrity guarantees for any honest participant's attestations are preserved independently of the fraction of dishonest participants in any region of the network, without requiring honest majority, honest plurality, or any fractional threshold of honest participants at any time. This is structurally distinct from every prior-art Byzantine fault-tolerant consensus system (PBFT, HotStuff, Tendermint), every prior-art blockchain consensus (Bitcoin's Nakamoto consensus at >50% honest hash rate, Ethereum PoS at >2/3 honest stake), every prior-art federated agreement system (Stellar, Ripple), and every prior-art centralized timestamping authority (RFC 3161 TSAs). The security argument is mechanism-design: signed lies are permanent and publicly attributable to the device that produced them, the dominant strategy for any participant anticipating future verification is to sign accurately, collusion among k dishonest participants does not dilute any individual colluder's attributability, and an honest participant in a region containing arbitrarily many dishonest participants is not bound by their consensus. The composition of unforgeable hardware-rooted identity (Claims 1-14) + external evidence cross-check (Claims 19-22) + non-repudiable attribution = sufficient for integrity in the unbounded-adversary setting. **No prior-art consensus or attestation system can make this claim.**

Updated 2026-05-31 (third revision) with **analog-property hedges on Claims 12, 13, and 13a** to scope the DC-balance and transition-density claims to the encoded bit stream (which is mathematically provable from the line code) rather than the analog-domain wire waveform (which depends on physical implementation properties this patent does not claim):

- **Claim 12's "100% transition density in idle"** — clarified that the transition density is a property of the encoded bit stream in the wire's slot sequence; analog-domain edge timing depends on driver slew rate, line capacitance, and reflection-settling characteristics of the physical implementation. The encoding-layer transition density is necessary but not sufficient for receiver clock recovery; sufficiency requires analog edge sharpness adequate to the receiver's sampling precision.
- **Claim 13 element (4) — "DC balance on the wire"** — split into two properties: (i) the encoded bit stream's bit-state distribution is provably indistinguishable from idle (mathematical property of Claim 12's encoding), and (ii) the analog-domain wire waveform's DC characteristics depend on driver rise/fall asymmetry, medium parasitic resonance and ringing, and pull-down linearity. The eavesdropper-defeat property at the bit-stream level is claimed; any residual analog-domain distinguishability via direct waveform measurement (e.g., 49.7% mean voltage instead of 50.0%) is a property of the physical implementation rather than of the line code.
- **Claim 13a element (1)** — same parallel hedge for the keyless variant.

The motivation for the hedge: an examiner or challenger placing an oscilloscope on a real PIPE link could measure a mean voltage that deviates from 50.0% due to ordinary engineering tolerances (driver asymmetry, parasitic L/C ringing, slew-rate mismatch) and assert that the unhedged "DC balance" claim doesn't read on the actual implementation. The hedge bounds the claim to what the line code provably achieves (bit-stream balance) and explicitly delegates analog-domain DC behavior to the physical implementation's responsibility. This strengthens patent defensibility without weakening the substantive novelty — the bit-stream-level eavesdropper-defeat property is preserved and provable.

Updated 2026-05-31 (second revision) with **four additional claims surfaced during PROTOCOL.md L3 design and nunc-integration review**:

- **Claim 9c — Health-attestation queries via domain-separated Message B exchanges.** State queries are unified with arbitrary-content commitments under the existing Message B wire primitive: when message_req matches a recognized domain-separated cryptographic identifier, the device includes the corresponding internal-state vector in the keyed-hash response; otherwise the response is a plain content commitment per Claim 15. Concrete embodiment identifier cited in the claim: `BLAKE3("Kei te ora koe?")` (Māori, "are you well/alive?") = `c0a6cabf9f69f2aff78b51151e9300cd5bd32dfbbecf550600625478ffee8e80`, used as the `q/health` omnibus query identifier in the implementation of record. Internal-state vector includes chip_state (Claim 4 classification), ring_health_mask + ring_health_cnt (Claim 3c/3d), slot_burned_mask (Claim 4), ira_fsm state (Claim 5), session exchange counter, and boot epoch counter. **The unification is the novel contribution**: prior-art secure elements use separate GET_STATUS opcodes with cleartext register-field returns; this claim composes state attestation cleanly with the existing keyed message primitive, providing the same wire-format privacy properties Claim 9b mandates without adding any wire-level primitive.

- **Claim 13 on-chip-vs-host embodiment clarification.** The Claim 13 ephemeral pubkey is host-side; on-chip embodiment is the keyless variant of Claim 13a. The chip contains no elliptic-curve scalar multiplication unit, no ECDH key agreement primitive, and no algebraic-hardness assumption susceptible to Shor's algorithm. ECDH (and any other asymmetric scheme required for compatibility with legacy systems — TLS, blockchain signatures, conventional PKI) is generated and consumed external to the device, with the device's keyed-hash output of Claim 11 supplying seed material. This separation preserves Claim 14 element (d)'s post-quantum property at the silicon layer while permitting hosts to compose with legacy schemes at their own threat-model burden.

- **Claim 19b — Multi-source consensus embodiment of Claim 19's contemporaneous anchor.** The unforgeable contemporaneous public value V_τ can be computed as the consensus interval from a cryptographically-random subset of a large diverse pool of network time sources (HTTPS Date, NTP, NTS, Roughtime, SMTP banners; spanning ASNs, geographies, operator categories) with outlier rejection and explicit confidence bound. Subset is reselected per query event by CSPRNG-quality nonce, defeating pre-positioned attacks: the adversary must compromise an unknown random subset of an arbitrarily-large pool, requiring either knowledge of the prover's nonce (cryptographically infeasible) or simultaneous compromise of a Byzantine fraction of the pool (operationally infeasible at practical scale). Working implementation: the host-side `nunc` library in the codebase, with 42 / 64 / 128 source tiers. The pattern is structurally identical to Claim 23's no-honest-majority property applied at the time-source layer.

- **Claim 19c — Trust-free prover-side time verification as precondition for the trust-elimination property.** The most architecturally important addition: makes explicit that the trust-minimization properties of Claims 15, 19, 20, 21, and 23 are CONDITIONAL on the prover possessing means to independently establish wall-clock time without recourse to any single external authority. Acceptable means: physical observation of natural phenomena (Claim 19a — hydrogen-1 hyperfine measurement; pulsar timing; CMB anisotropy; planetary observations) and/or cryptographically-random multi-source consensus (Claim 19b — nunc-style). Implementations relying on NIST, USNO, BIPM, GPS, NTP federation, or RFC 3161 TSAs for wall-clock authority **fall outside the scope of the trust-elimination claims**, regardless of silicon or protocol details. This precludes a class of incomplete embodiments where chip-layer trust-elimination is rendered moot by time-layer authority dependence. The claim names the architectural foundation: trust elimination is composable only when every layer of the stack independently eliminates its trusted authority — the chip eliminates manufacturer CA (5, 6), the protocol eliminates session-key distribution (11), the message format eliminates cert-and-signature (13a), the attestation primitive eliminates TSA (15), the time-binding embodiment eliminates wall-clock authority (this claim), and the network resilience eliminates honest-majority (23). Each elimination is necessary; none sufficient alone.

Updated 2026-05-16 (second revision) with **round-robin per-ring health monitoring (Variant A)** for the SOT-23 silicon-area target:

- **Single shared `ring_health` instance + scheduler FSM** rather than 16 parallel instances. The scheduler enables one ring at a time, runs a full W=65,536 sample gather with full statistical power (the layered RCT + APT + iterated GF(2) check from Claim 3c), and advances to the next ring. Total KOHI time = 16 × W = 1.75 s at enclave_clk = 600 kHz, which fits comfortably within the per-session handshake latency budget (sessions are long-lived; KOHI fires per session-establish, not per protocol message). The 1.75 s also fits beneath the Claim 8 TATARI random pre-burn delay envelope for the once-per-lifetime OTP burn.
- **Measured synth cost on ECP5-25F (yosys + nextpnr-ecp5)**: 689 LUT4 + 474 FF + 151 carry cells total (the entire 16-ring health-monitoring subsystem). Compared to a parallel-instance equivalent at 9,280 LUT4 + 3,232 FF, this is a 13× LUT reduction and 7× FF reduction. Fmax 100–106 MHz across placement seeds, providing >150× headroom over the 600 kHz enclave_clk target.
- **Silicon estimate at 28 nm**: ~3,500 standard cells ≈ ~0.01 mm² (versus ~0.10 mm² for parallel). At ~2% of a SOT-23 die area budget, this leaves the rest of the die for BLAKE3, OTP, codec, and wire-protocol logic.
- **The patent claim text is unchanged** — "per-ring health monitoring comprising three concurrently-evaluated checks" applies equally to time-multiplexed and parallel embodiments. Claim language already supports the implementation choice.
