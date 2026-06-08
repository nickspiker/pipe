# PIPE wire protocol

Single-wire, full-duplex, self-clocking, DC-balanced line code for the PIPE attestation channel. This document is the canonical reference both the silicon (Verilog) and host (Rust) implementations build against.

## Layer 0 — physical topology

The wire is a single PCB trace with a 400 Ω series resistor between each side's I/O pin and a passive 5 kΩ pull-down to GND:

```
ECP5 pin ──/\/\──┬──/\/\──FT232H pin
       400 Ω    │    400 Ω
                ⏚ 5 kΩ pull-down to GND
```

**Drive rules.** Neither side ever actively drives LOW. They drive HIGH (overriding the pull-down) or release to HIGH-Z (pull-down wins, line goes LOW). LOW is a *passive* state of the wire, set by the pull-down whenever no driver is active. This makes the wire's behavior deterministic in every regime — silent, half-driven, contended — without any "what-if-both-tristate" edge cases.

## Layer 1 — slot ownership

Time on the wire is divided into **slots**, each one bit-time `T` long. Slot index `s` increments every `T`. Slots alternate ownership:

| s mod 2 | owner | direction |
|---|---|---|
| 0 (even) | enclave | drives HIGH or releases; host samples |
| 1 (odd)  | host    | drives HIGH or releases; enclave samples |

Only the slot owner is permitted to drive. The off-side is always HIGH-Z. Within an owner's slot, whether the owner drives or releases depends on the codec's `wire_out` (see Layer 2): drive HIGH if `wire_out == 1`, release if `wire_out == 0`.

In idle, this gives the enclave 100% drive duty on its even slots (idle `wire_out` = 1) and 0% drive duty on the host's odd slots (idle `wire_out` = 0, pull-down handles it). The host is fully passive in idle — zero current.

Slot phase is established at boot from the idle pattern (see Layer 2) and tracked thereafter by the host's CDR.

## Layer 2 — line code: mirror-XOR with asymmetric drive

Each side maintains a **data stream** — a sequence of bits it intends to communicate. In idle, both streams are constant zero; activity is signaled simply by inserting non-zero bits.

### Encode rule

When it is your slot, compute:

```
wire_out  = own_idle  XOR  own_data[i]  XOR  other_last_data
drive_en  = my_slot  AND  wire_out
```

If `drive_en == 1` → drive the pin HIGH. If `drive_en == 0` → release the pin (HIGH-Z, pull-down holds the line LOW).

where:

- `own_idle` = `1` for the enclave, `0` for the host
- `own_data[i]` = your i-th data bit (i increments once per slot you own)
- `other_last_data` = the last data bit you decoded from the other side (initialized to 0)

### Decode rule

When it is the **other side's** slot, sample `wire[s]` and recover their data bit:

```
other_data[j] = wire[s]  XOR  other_idle  XOR  own_last_data
```

where:

- `other_idle` = the other side's idle value (the inverse of yours)
- `own_last_data` = your most recently transmitted bit (initialized to 0)

### State per side

Two single-bit registers, both initialized to 0:

- `own_last_data` — what you most recently drove (updated at end of each of your slots)
- `other_last_data` — what you most recently decoded from the other side (updated at end of each of their slots)

### Properties

1. **Self-clocking idle.** Both streams = 0 → wire = `1 0 1 0 1 0 …`. Enclave actively drives the `1`s on even slots; pull-down handles the `0`s on odd slots. 100% edge density.
2. **Host is fully passive in idle.** With `own_idle = 0`, idle `wire_out = 0`, so `drive_en = 0`. Host's pin sits HIGH-Z drawing zero current; the pull-down resistor accounts for the host's contribution to the heartbeat.
3. **CDR locks to enclave drives, ignores pull-down level.** Edge density is 100% in idle, and all edges are produced by the enclave's active HIGH drives on even slots.
4. **DC-balanced for arbitrary data.** A `1` from one side gets compensated on the next slot's other-side drive via the `other_last_data` XOR term. Wire mean stays 50/50 after at most a 2-slot transient.
5. **No doorbell, no framing primitive at this layer.** A `1` in your data stream is enough — the receiver picks it up the same slot it appears.
6. **Full duplex with independent streams.** Encode and decode are self-inverse XOR operations; the two streams are decoded independently by each side without coordination.
7. **Mirror-XOR compensation can force a side to drive HIGH even with its own data = 0.** If `other_last_data = 1` and `own_data = 0`, the host's `wire_out = 0 XOR 0 XOR 1 = 1` → host drives HIGH. The compensation is what maintains DC balance after the other side transmitted a `1`.
8. **Wire is deterministic in every regime.** Both sides driving, one silent, both silent — all map to defined wire patterns via the pull-down. There is no floating state to design around.

### XOR offset N — generalization for line delay

The encode rule above uses `other_last_data` — implicitly, the other side's bit from one slot ago. That works when the wire's one-way propagation delay `τ_prop` is small compared to one slot time `T` (FT232H + 30 cm PCB prototype: `τ_prop` is sub-nanosecond, `T = 1 µs` → ratio ~10⁻³, irrelevant).

For arbitrary link length the rule generalizes by introducing an integer offset `N`:

```
wire[s] = own_idle  XOR  own_data[i]  XOR  other_data[i - N]
```

Each side XORs in the *N-th most recent* bit it decoded from the other side, not the immediately previous one. The decode rule mirrors:

```
other_data[j] = wire[s]  XOR  other_idle  XOR  own_data[j - N]
```

`N = ceil(τ_prop / T) + 1`. Both sides agree on `N` at boot (length-of-link configuration constant, or measured during heartbeat lock).

**Consequence:** bit rate is no longer constrained by `1 / (2 · τ_prop)` (the round-trip floor that limits feedback-style codes). It is bounded only by the wire's **signal spread** — the rise/fall time set by line impedance and capacitance. Long links, fiber spans, isolator-coupled segments — all reachable without changing the line code, just by picking a larger `N`.

Both sides need a small shift register of length `N` instead of a single-bit `last_data` register; encode/decode cost is otherwise unchanged.

For the current FT232H prototype, `N = 1` and this section is dormant.

### Worked examples

Notation per slot column: the action taken (`drive HIGH` or `release → pull-down LOW`) and the resulting wire value. Both sides see the same wire.

**Example 1 — Pure idle (both data streams forever 0).**

```
slot:    0    1    2    3    4    5    6    7
owner:   E    H    E    H    E    H    E    H
e_data:  0         0         0         0
h_data:       0         0         0         0

E slot:  wire_out = 1^0^0 = 1 → drive HIGH
H slot:  wire_out = 0^0^0 = 0 → release   (pull-down → LOW)

wire:    1    0    1    0    1    0    1    0
```

Enclave drives 100% of the highs. Host stays HIGH-Z, draws zero current. Pull-down handles every LOW.

**Example 2 — Host sends a single 1 at slot 5.**

```
slot:    0  1  2  3  4  5  6  7  8
owner:   E  H  E  H  E  H  E  H  E
h_data:     0     0     1     0
e_data:  0     0     0     0     0

slot 4 (E):  wire_out = 1^0^0 = 1 → drive HIGH       wire = 1
slot 5 (H):  wire_out = 0^1^0 = 1 → drive HIGH       wire = 1   ← host's 1
             enclave decodes: wire(1) ^ 0 ^ own_last(0) = 1
             enclave's other_last ← 1
slot 6 (E):  wire_out = 1^0^1 = 0 → release          wire = 0   ← enclave compensates
slot 7 (H):  wire_out = 0^0^0 = 0 → release          wire = 0
slot 8 (E):  wire_out = 1^0^0 = 1 → drive HIGH       wire = 1
```

Slots 4–7 form a `1 1 0 0` window — DC-balanced ✓. Enclave's release on slot 6 is the mirror-XOR compensation that restores balance.

**Example 3 — Enclave sends a single 1 at slot 4.**

```
slot:    0  1  2  3  4  5  6  7  8
owner:   E  H  E  H  E  H  E  H  E
e_data:  0     0     1     0     0
h_data:     0     0     0     0

slot 3 (H):  wire_out = 0^0^0 = 0 → release          wire = 0
slot 4 (E):  wire_out = 1^1^0 = 0 → release          wire = 0   ← enclave's 1
             host decodes: wire(0) ^ 1 ^ own_last(0) = 1
             host's other_last ← 1
slot 5 (H):  wire_out = 0^0^1 = 1 → drive HIGH       wire = 1   ← host compensates
slot 6 (E):  wire_out = 1^0^0 = 1 → drive HIGH       wire = 1
slot 7 (H):  wire_out = 0^0^0 = 0 → release          wire = 0
```

Slots 4–7 = `0 1 1 0`, DC-balanced ✓. **Critical:** in slot 5 the host actively drove HIGH even though its data was 0. The compensation term forced it. Host's `drive_en` is *not* "only when I have data" — it's `my_slot AND wire_out`, and the XOR coupling can make `wire_out = 1` with `own_data = 0`.

**Example 4 — Both sides send 1 in the same exchange window.**

```
slot:    0  1  2  3  4  5  6  7  8
owner:   E  H  E  H  E  H  E  H  E
e_data:  0     0     1     0     0
h_data:     0     0     1     0     0

slot 4 (E):  wire_out = 1^1^0 = 0 → release          wire = 0  ← E's 1
             host decodes: wire(0)^1^0 = 1 → other_last_h ← 1
slot 5 (H):  wire_out = 0^1^1 = 0 → release          wire = 0  ← H's 1 (XOR'd away by cross-term)
             enclave decodes: wire(0)^0^own_last_e(=1) = 1 → other_last_e ← 1
slot 6 (E):  wire_out = 1^0^1 = 0 → release          wire = 0
             host decodes: wire(0)^1^own_last_h(=1) = 0 → other_last_h ← 0
slot 7 (H):  wire_out = 0^0^0 = 0 → release          wire = 0
slot 8 (E):  wire_out = 1^0^0 = 1 → drive HIGH       wire = 1
```

Four consecutive LOWs on the wire, but both sides correctly decode the other's 1, and the chain converges back to idle by slot 8. CDR has enough edge history from prior idle to coast through the dropout.

**Example 5 — Host sends a 4-bit message `1 0 1 1` starting at slot 1.**

```
slot:    0  1  2  3  4  5  6  7  8  9
owner:   E  H  E  H  E  H  E  H  E  H
e_data:  0     0     0     0     0     0
h_data:     1     0     1     1     0     0

wire:    1  1  0  0  1  1  0  1  0  0  …

slot 0 (E): 1^0^0=1 → HIGH                                       (idle)
slot 1 (H): 0^1^0=1 → HIGH      E rx = 1^0^0 = 1, ol_e ← 1
slot 2 (E): 1^0^1=0 → release   H rx = 0^1^1 = 0, ol_h ← 0       (E compensates)
slot 3 (H): 0^0^0=0 → release   E rx = 0^0^0 = 0, ol_e ← 0
slot 4 (E): 1^0^0=1 → HIGH      H rx = 1^1^0 = 0, ol_h ← 0
slot 5 (H): 0^1^0=1 → HIGH      E rx = 1^0^0 = 1, ol_e ← 1
slot 6 (E): 1^0^1=0 → release   H rx = 0^1^1 = 0, ol_h ← 0
slot 7 (H): 0^1^0=1 → HIGH      E rx = 1^0^0 = 1, ol_e ← 1
slot 8 (E): 1^0^1=0 → release   H rx = 0^1^1 = 0, ol_h ← 0
slot 9 (H): 0^0^0=0 → release   E rx = 0^0^0 = 0, ol_e ← 0       (back to idle)
```

Decoded by enclave: `1, 0, 1, 1` ✓. Each host `1` triggers a one-slot enclave compensation (release in next E slot). The pattern is fully self-clocking and DC-balanced over each pair.

## Layer 2.5 — host clock recovery

The host samples the wire continuously; its CDR locks to the slot boundaries. **The host's own emissions must be subtracted before edge detection**, because:

- Host knows everything about its own emissions (it generates them); the edges they create or destroy carry no information about the enclave's clock.
- Failing to subtract them means the CDR locks partly to the host's own clock, which defeats the purpose — the whole point of the protocol is that the host tracks the enclave's clock, not the other way around.

The host computes an "enclave-only" projection:

```
effective[s] = wire[s]  XOR  host_emission[s]
```

where `host_emission[s]` is what the host either drove (during odd slots) or what its `host_last_data` XOR contribution to wire was (during even slots — the host knows its `host_last_data` because it sent it). After subtraction, `effective[s]` reflects only the enclave's contribution. The CDR locks to edge transitions in `effective[s]`.

In practice, `effective[s]` looks like:

| state | `effective` pattern | edge density |
|---|---|---|
| idle (`enclave_data = 0`) | `1 0 1 0 1 0 …` | 100% |
| random `enclave_data` | mix | ~50% |
| `enclave_data = 1` constant | `1 0 1 0 …` (shifted phase) | 100% |
| `enclave_data` alternating | `0 1 1 0 0 1 1 0 …` | 50% |

The CDR PLL needs τ wide enough to coast through the worst case (alternating enclave data → 50% edges) without unlocking, which is easy: a few slots of edge dropout doesn't budge a properly-tuned loop.

## Layer 3 — messaging and authentication (protocol v0)

Mirror-XOR is a stream code; it does not impose framing. Layer 3 provides framing, mode signaling, integrity, freshness, and recovery — all built from BLAKE3, XOR, and bitwise complement. No HMAC construction, no length fields, no opcodes. Two message shapes only.

**Threat model assumed.** Eavesdropping is out of scope — the wire is on-die or close to it. Injection requires inside-package physical access, which is also out of scope. The protocol defends against: replay across sessions, single-bit corruption inside a session (detected via hash mismatch → fresh-session reset), and reuse of an attestation across the SESSION/PERMANENT modes.

### State (each side maintains)

```
session_secret : 256 bits   — root of the current session
H_req          : 256 bits   — XOR pad for the "message" half of next exchange
H_resp         : 256 bits   — XOR pad for the "hash" half of next exchange
```

`H_req` and `H_resp` ratchet on every verified exchange (see below). All three reset on fresh-session.

### Frame bit

**Every message from either side begins with a single logical `1` as its first transmitted bit, and this bit is pure framing — it is NOT part of the payload.** It announces "I am about to transmit a message": the wire transitions out of idle LOW (host slot held LOW by pull-down, or enclave slot released to pull-down) into a driven HIGH. Without it, a payload whose first bit happens to be `0` would be indistinguishable from continued idle.

The frame bit is overhead, one bit per message per direction. The receiver consumes it and discards it; the message proper begins on the next slot. Concretely:

  * Fresh-session = `1` (frame) + `0×256` (payload) = **257 wire bits** total.
  * Message B    = `1` (frame) + 256-bit X1 + 256-bit X2 = **513 wire bits** per direction.

Because the frame bit is not derived from `message_req XOR H_req`, the host can put any 256-bit value in `message_req` — including canonical identifiers like Q_HEALTH or BLAKE3("motuhake") whose bits are determined by hash output and cannot be edited. This is what makes the same `message_req` produce the same response across exchanges in a session (determinism: A==B), and what makes canonical domain identifiers work unconditionally in every fresh-session.

This is Claim 12a's leading-edge marker applied to L3 framing: a single 1-bit transition announces "frame begins now," after which a fixed-length payload follows. No length field, no opcode, no extra framing — one bit of overhead.

### Message shape A — fresh-session (host → enclave, then enclave → host)

Host signal: 257 wire bits — leading frame-`1`, then 256 zero data bits. The frame bit is consumed and discarded; the payload is the all-zero 256-bit value.

Enclave response:
```
session_secret ← TRNG.draw(256)
H_req          ← BLAKE3(session_secret)
H_resp         ← BLAKE3(~session_secret)
```
Enclave emits 257 wire bits: leading frame-`1`, then `session_secret` (256 bits) MSB-first.

Host, on receiving the 256-bit secret, performs the same `H_req` / `H_resp` derivation. Both sides are now synchronized.

Detection: after consuming the frame bit, the enclave buffers the host's first 256 data bits. If they are exactly zero it is a fresh-session request; any other pattern is the start of a Message B exchange (probability of Message B's X1 accidentally matching: 2⁻²⁵⁶).

### Message shape B — authenticated exchange (513 bits each direction)

Host's request, 513 wire bits sent over 513 host slots: leading frame-`1`, then 256 X1 bits, then 256 X2 bits:

```
slot 0       :  frame bit = 1 (consumed and discarded by enclave)
slots 1..256 :  X1 = message_req  XOR  H_req
slots 257..512: X2 =  BLAKE3(message_req)  XOR  H_resp        (mode = SESSION)
                X2 = ~BLAKE3(message_req)  XOR  H_resp        (mode = PERMANENT)
```

Enclave verifies by recovering `message_req = X1 XOR H_req`, computing `BLAKE3(message_req)`, and checking which of `BLAKE3(message_req) XOR H_resp` or `~BLAKE3(message_req) XOR H_resp` equals `X2`. The matching case determines mode. No match → corruption → drop, do not advance pads (host will retry or fresh-session).

Enclave computes:
```
active_key   = session_secret    (SESSION)
             = permanent_key     (PERMANENT, eFuse-backed; burn-on-first-use)
message_resp = BLAKE3.keyed(active_key, message_req)
```

Enclave's response, 513 wire bits sent over 513 enclave slots (leading frame-`1`, then 256 X1' bits, then 256 X2' bits), mirrors the requested mode:

```
slot 0       :  frame bit = 1 (consumed and discarded by host)
slots 1..256 :  X1' = message_resp  XOR  H_req
slots 257..512: X2' =  BLAKE3(message_resp)  XOR  H_resp        (SESSION echo)
                X2' = ~BLAKE3(message_resp)  XOR  H_resp        (PERMANENT echo)
```

Host verifies the same way the enclave did. On successful verification both sides advance:
```
H_req  ← BLAKE3(message_req)
H_resp ← BLAKE3(message_resp)
```

A mismatch on either side is detected at verify time. The corrupted exchange is dropped, pads are *not* advanced, the other side will be desynced on next attempt → host issues fresh-session and both sides reset.

### Domain identifiers (well-known `message_req` values)

`message_req` is an arbitrary 256-bit value at the wire level — the protocol does not interpret it. By convention, certain `message_req` values are reserved as **domain identifiers**: they are the BLAKE3 of a short Māori phrase, and they trigger either a behavioural variation on the enclave (q/health) or simply mark the exchange as belonging to a specific test/use category.

| Name      | Phrase (gloss)                            | `message_req` value                                                  | Effect                                                                                                          |
|-----------|-------------------------------------------|----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| Q_HEALTH  | "Kei te ora koe?" (are you alive/well?)   | `c0a6cabf 9f69f2af f78b5115 1e9300cd 5bd32dfb becf5506 00625478 ffee8e80` | Triggers q/health state-vector response (see next section). Behaviour change is implementation-visible.        |
| MOTUHAKE  | "motuhake" (independent, distinct)        | `BLAKE3("motuhake")` (32 bytes, ASCII without trailing NUL)          | Conventional canonical-test domain separator. No behavioural change — exchange behaves as a vanilla Message B. |

The MOTUHAKE identifier is the canonical end-to-end test the chip ships with. It enables a host to assert all five demo properties at once with two SESSION + two PERMANENT exchanges using identical `message_req`:

```
A = PIPE(motuhake | active_key=WAIRUA)   // SESSION
B = PIPE(motuhake | active_key=WAIRUA)   // SESSION, same session
C = PIPE(motuhake | active_key=IRA)      // PERMANENT
D = PIPE(motuhake | active_key=IRA)      // PERMANENT, same session

Expected:
  A == B                                  // deterministic given (session, key, message)
  C == D                                  // deterministic
  A != C                                  // SESSION and PERMANENT live in different keyspaces
  C == BLAKE3.keyed(IRA, motuhake)        // host can recompute the PERMANENT side standalone
  // A is not host-recomputable — host does not know WAIRUA from the wire alone
  // (host does know WAIRUA: it was sent in cleartext during fresh-session)
  // After power cycle: IRA unchanged → C and D still match; WAIRUA fresh → new A,B
```

Why Māori: ferros is named after a Māori concept (ira = "essential genetic/spiritual code"); the protocol's named values follow suit. They are arbitrary domain separators — any other 256-bit values would work — but consistency in naming makes the demo arc legible and gives the q/health response a stable identifier across silicon revisions.

### Q_HEALTH state vector (claim 9c "clever" embodiment)

When `message_req == Q_HEALTH`, the enclave composes its BLAKE3 input as a **single 64-byte block** with `message_req` in the low half and a packed 32-byte **state vector** in the high half:

```
mblock[255  :   0] = message_req           (= Q_HEALTH)
mblock[511  : 256] = state_block           (packed, 256 bits, LSB at bit 256)
numbytes           = 64
message_resp       = BLAKE3.keyed(active_key, mblock, 64 bytes)
```

This is still **one BLAKE3 compression** — q/health responses are not slower than vanilla Message B. The host verifies by composing the same 64-byte block in the same byte order and hashing under the same `active_key`.

State block layout (matches `rtl/l3_session_fsm.v`):

| Bits (within mblock) | Width | Field                | Notes                                                            |
|---------------------:|------:|----------------------|------------------------------------------------------------------|
|              258:256 |     3 | chip_state           | 0=KORE, 1=NGARO, 2=WHARA, 3=HARA, 4=ORA        |
|              274:259 |    16 | ring_health_mask     | Per-ring pass bits (16 rings, LSB = ring 0)                      |
|              279:275 |     5 | ring_health_cnt      | Ora-ring count (0–16)                                        |
|              287:280 |     8 | slot_burned_mask     | OTP slot burned bits (8 slots, LSB = slot 0)                     |
|              290:288 |     3 | fsm_state            | Ceremony FSM state (debug-only)                                  |
|              354:291 |    64 | session_counter      | Verified Message-B exchanges in this session                     |
|              418:355 |    64 | boot_epoch           | Enclave_clk cycles since power-on (free-running)                 |
|              482:419 |    64 | drop_counter         | Lifetime count of dropped exchanges (corrupt / failed verify)    |
|              511:483 |    29 | reserved zero        | Future fields                                                    |

All counters are 64-bit: the chain-state advancement they encode is integrity-bearing data even during a health-check response, and the state block has 29 bits of headroom for future additions. The host that wants to prove a property — "this chip has handled at least N exchanges since boot," "this chip has had zero drops in the last K seconds," "ring 7 is currently failing TRNG health" — issues `PIPE(Q_HEALTH | active_key)`, recomputes the expected hash over the asserted state, and checks for a match.

### Properties

- **One escape hatch for everything.** Bit error, lost response, suspicious payload, host software lost state, enclave hung mid-burn — fresh-session resets all of it. No partial-recovery protocol to design.
- **Forward secrecy after exchange 1.** Pads ratchet via one-way hashes; recovering state at exchange N reveals nothing about exchanges < N.
- **Cross-session repetition hidden after exchange 1.** Two sessions doing the same exchange-2 produce entirely different wire bytes because `H_req` and `H_resp` at exchange 2 depend on session-specific exchange-1 message hashes. (Exchange 1 leaks `msg XOR BLAKE3(msg) XOR K_session` to anyone computing X1 XOR X2 — this is the known residue of the dual-init from a single seed, intentionally accepted because eavesdropping is out of scope.)
- **Mode-confusion immune.** Same `message_req` under SESSION vs PERMANENT produces different second-halves (hash vs bit-flipped hash). An attacker cannot replay a SESSION response as a PERMANENT response.
- **Burn timing observable but unexploitable.** First PERMANENT request takes ~1–2 s (entropy spin-up + TRNG-randomized burn timing + read-verify), subsequent requests are ~ms. The wire reveals "the burn happened around now" but not "when within that window each fuse blew" or "what bits got burned."
- **Bandwidth-bounded.** At 50 kHz slot rate, one exchange (513 host slots + 513 enclave slots = ~1026 slots after counting both directions) is ~20 ms. Brute-forcing a 256-bit key over the wire is ≈ 2²⁵⁶ × 0.02 s = beyond cosmological. Slow is the security property.
- **Statistically uniform.** Every bit on the wire is either TRNG output, BLAKE3 output, an XOR of two such, or a bit-flip thereof. No structure for an eavesdropper to lock onto, even if eavesdropping returned to scope.

### What about the first authenticated exchange after fresh-session?

`H_req XOR H_resp = BLAKE3(session_secret) XOR BLAKE3(~session_secret)`, a session-specific 256-bit constant. So for exchange 1 in any session, `X1 XOR X2 = message_req XOR BLAKE3(message_req) XOR (that constant)`. The constant cancels across exchanges within the session, leaving a per-message fingerprint visible to anyone computing `X1 XOR X2`. The fingerprint is unique per message and gives no other information; under the stated threat model it is invisible. From exchange 2 onward the chain replaces the per-session constant with per-message hashes, killing even this residue.

If eavesdropping ever moves into scope, the fix is one extra hash at session init: derive `H_req = BLAKE3(session_secret || 0x00)` and `H_resp = BLAKE3(session_secret || 0x01)` instead, so the two pads are unrelated derivations. Same wire shape, marginally more init cost, fingerprint gone.

### Why this is v0

This is the simplest protocol we found that hits the threat model exactly. v1 is what we will need when someone discovers a real flaw or when the threat model widens (eavesdropping in scope, link-level errors common, mutual auth needed, etc.). Naming it v0 keeps the door open for breaking changes without anyone arguing about whether they are "really breaking" — every version bump is breaking; that is the point of the number.

## Reference encode/decode

### Verilog (per-side codec)

```verilog
// Pseudocode for one slot tick on the enclave side.
// host side is identical with own_idle/other_idle swapped (0/1).
//
// Inputs at the start of slot s:
//   slot_phase     : 1'b0 if this slot is enclave's, 1'b1 if host's
//   tx_data        : data bit to transmit when slot_phase == 0
//   wire_in        : sampled wire value when slot_phase == 1
//
// State (registered, both init to 0):
//   own_last       : what enclave most recently drove
//   other_last     : what enclave most recently decoded from host
//
// Outputs:
//   wire_out       : drive value (only meaningful when slot_phase == 0)
//   drive_en       : tristate enable
//   rx_data        : decoded host bit (valid one slot after host's slot)
//   rx_valid       : pulse one slot after a host bit decode

localparam OWN_IDLE   = 1'b1;  // enclave
localparam OTHER_IDLE = 1'b0;  // host

assign wire_out = OWN_IDLE ^ tx_data ^ other_last;
assign drive_en = (slot_phase == 1'b0);

always @(posedge slot_clk) begin
    rx_valid <= 1'b0;
    if (slot_phase == 1'b0) begin
        own_last <= tx_data;
    end else begin
        rx_data    <= wire_in ^ OTHER_IDLE ^ own_last;
        other_last <= wire_in ^ OTHER_IDLE ^ own_last;
        rx_valid   <= 1'b1;
    end
end
```

### Rust (host loop)

```rust
const HOST_IDLE: u8 = 0;
const ENCLAVE_IDLE: u8 = 1;

struct Codec {
    own_last: u8,
    other_last: u8,
}

impl Codec {
    fn tx(&mut self, data: u8) -> u8 {
        let wire = HOST_IDLE ^ data ^ self.other_last;
        self.own_last = data;
        wire
    }

    fn rx(&mut self, wire: u8) -> u8 {
        let data = wire ^ ENCLAVE_IDLE ^ self.own_last;
        self.other_last = data;
        data
    }
}

// Main bit-bang loop (simplified; CDR + sample timing not shown):
fn pipe_loop(ftdi: &mut Ftdi, codec: &mut Codec) {
    loop {
        wait_for_slot_boundary();

        if is_host_slot() {
            let bit = next_tx_bit();           // from outgoing message buffer
            ftdi.write_bit(codec.tx(bit));
        } else {
            let wire = ftdi.read_bit_with_oversample();
            let bit = codec.rx(wire);
            push_rx_bit(bit);                  // into incoming message buffer
        }
    }
}
```

## Verilog modules to write (Phase E.5)

The existing `rtl/shift_tx.v`, `rtl/shift_rx.v`, `rtl/cdc.v` skeletons describe the old half-duplex doorbell-based design and need to be rewritten around mirror-XOR. New module split:

- **codec.v** — per-side encode + decode + state. Pure combinational tx encoder and a registered rx decoder. Two instantiations: one with `OWN_IDLE=1` (enclave) and one with `OWN_IDLE=0` (host) — though only the enclave instance ships in silicon.
- **slot_clk.v** — divides `enclave_clk` down to the slot rate. Generates `slot_phase` (toggles each tick).
- **wire_io.v** — bidirectional pad with tristate enable from `slot_phase`. 2-flop synchronizer on the input path.

Total RTL footprint for the wire layer: < 50 LUT4. The protocol's complexity lives almost entirely in the application layer (FSM that drives `tx_data` from the message buffer and gathers `rx_data` into the receive buffer).

## What this protocol explicitly does NOT do

- **No power-saving deep-idle.** Both sides drive constantly. Power cost: negligible at 1 MHz on a 3.3 V signal through a 430 Ω series resistor.
- **No flow control.** Both sides assume the other is keeping up. For attestation this is fine — transactions are bounded length, both sides know the schedule.
- **No error correction.** Single-bit flips silently corrupt one data bit. The ragu layer detects corruption end-to-end (a corrupted ragu won't verify against the expected ragu), so the attestation protocol is naturally fail-safe — corrupted = retry.
- **No crypto in line code.** Mirror-XOR is purely a balanced framing primitive. The attestation primitive (chaos_amp + BLAKE3 keyed) is the security layer; the line code just gets bits across cleanly.
