# IRA — Life-essence and Provisioning Ceremony

In Māori, `ira` means *essence, life-principle, gene, the spark of identity that makes a thing what it is*. PIPE's `ira` is the device's 256-bit boot secret — derived once from on-die entropy (see [TRNG.md](TRNG.md)), burned into OTP, and never modifiable thereafter. Every cryptographic key the chip uses derives from it.

The provisioning ceremony — the act of imprinting `ira` into the silicon — is a three-phase persistent state machine: **KOHI** (gather), **TATARI** (wait), **TAHU** (burn / kindle / set alight). After TAHU, the chip enters its operational life with an immutable identity.

## `ira` and `wairua` — persistent and ephemeral

PIPE has **two parallel 4-inverted-pair structures**, identical in layout and verification, differing only in storage backend and lifetime:

| Name | Storage | Lifetime | Failure recovery |
|---|---|---|---|
| **`ira_set`** | eFuse (8 slots, 4 inverted pairs) | Permanent — burned at provisioning, never modified | XOR-check failure on boot → STATE 1 (NGARO), refuse all operation |
| **`wairua_set`** | RAM (8 slots, 4 inverted pairs) | Ephemeral — established per session via handshake, destroyed on power-off | XOR-check failure mid-session → brick session, refuse all messages, require power-cycle to re-handshake |

The Māori pairing: `ira` is the gene/essence of the device — its persistent identity burned into silicon. `wairua` is the spirit — the ephemeral animating force of each session, alive only while powered. Body and spirit, persistent and transient, sharing the same 4-pair inverted-XOR verification machinery to defend against cosmic-ray bit flips on either side.

**Why not silently re-derive a failed `wairua_set`?** Because session keys derived from a freshly-regenerated `wairua_set` would no longer match what the client expects — the message chain would break, but the device wouldn't know that the chain was already corrupted. Forcing a power-cycle handshake is the only safe recovery: the client sees the silence, sees no response, drops the line, opens fresh handshake → both sides re-derive in lock-step.

## What's stored — just `ira` (and `wairua`)

PIPE's OTP holds **only the 256-bit `ira`**. RAM holds **only the 256-bit `wairua`** during a session. Neither stores device IDs, attestation keys, killswitch policy, or any other derived material — those are computed on demand via domain-separated BLAKE3:

```
device_id        = BLAKE3("ferros-pipe/device-id"   || ira)
attestation_key  = BLAKE3("ferros-pipe/attestation" || ira)
session_seed_i   = BLAKE3("ferros-pipe/session"     || ira || nonce_i)
```

Each domain tag produces a cryptographically-independent derived key. Knowing any derived key tells you nothing about `ira` or any other derived key (BLAKE3 is preimage-resistant). Independence is computational, but for security purposes that's identical to statistical independence.

Storing only `ira` and deriving everything from it has three benefits:
- **Minimum eFuse area** — 256 bits × redundancy, not multiple independent keys
- **Faster TAHU** — fewer fuses to burn means shorter power-fail window
- **Cleaner threat model** — there is one secret. Compromising the chip exposes that one secret. There is no scenario where one derived key leaks but the others don't, because they're all functions of the same input.

## OTP geometry — 8 slots, 4 inverted pairs

| Slot | Contents | Bits |
|---|---|---|
| 0A | `ira` | 256 |
| 1A | `ira` | 256 |
| 2A | `ira` | 256 |
| 3A | `ira` | 256 |
| 0B | `~ira` (bitwise inverse) | 256 |
| 1B | `~ira` | 256 |
| 2B | `~ira` | 256 |
| 3B | `~ira` | 256 |
| **Total** | | **2,048 bits = 2¹¹** |

The chip stores `ira` four times and `~ira` four times. Each pair `(slot_iA, slot_iB)` is a self-checking unit: `slot_iA XOR slot_iB` should equal all-ones if the pair was burned cleanly.

**Why inverted pairs**: a single test (`A XOR B == 0xFFFF...F`) distinguishes three pair states from one comparison:

| `A XOR B` | Pair classification |
|---|---|
| All zeros | **kore** — both slots unburned |
| All ones | **valid** — proper inverted burn |
| Anything else | **corrupt** — partial burn, aging drift, attack |

No sentinel fuses, no separate "provisioned" indicator. Slot equality and inversion together encode all needed state.

## The five lifelong states

PIPE has exactly five states reachable from power-on reset. State transitions happen only via silicon physics (provisioning, aging, interruption) — no command, no host, no protocol can drive the chip between states.

| State | Name | Condition | Behavior |
|---|---|---|---|
| **0** | KORE | All 4 pairs have `A=B=0` (XOR = 0) | Enter provisioning mode (KOHI → TATARI → TAHU) |
| **1** | NGARO | 0 or 1 valid pairs, OR multiple valid pairs disagree on `ira` | Refuse to operate. OTP preserved for diagnosis. |
| **2** | WHARA | Exactly 2 valid pairs, agreeing on `ira` | Operate. Status byte reports `pair_valid_count=2` (MARGINAL) — host warns user to retire chip. |
| **3** | HARA | Exactly 3 valid pairs, agreeing on `ira` | Operate. Status byte reports `pair_valid_count=3` (HARA). |
| **4** | ORA | All 4 pairs valid, all agreeing on `ira` | Operate. Status byte reports `pair_valid_count=4` (ORA). |

There is no STATE 5 (deliberate-destruct), no transient-failure-counter, no scorch indicator. See "Indestructible from outside" below for why.

## Boot decision logic

```
1. For each of 8 slots: read 3 times, take per-bit majority. (Layer 1 robustness)
2. For each of 4 pairs i: compute A_i XOR B_i
3. Classify each pair: kore (=0), valid (=all-ones), or corrupt
4. Decision:
   - all 4 kore                                  → STATE 0, enter provisioning
   - ≥ 2 valid AND all valid agree on same ira     → STATE 2/3/4, operate
   - anything else                                  → STATE 1, refuse
```

Per-bit majority across 3 reads reduces effective bit-read error rate from ~10⁻⁹ to ~10⁻¹⁸, so transient cosmic-ray-style upsets are recovered before they reach pair classification.

## When KOHI runs

Rings are **gated off** by default. Five triggers can spin them up:

| Trigger | KOHI output destination | Notes |
|---|---|---|
| **Handshake** (single `He` break in a clean 256-cycle envelope on either side) | `wairua_set` in RAM | First KOHI of a session. Generates session-side keys + chain init. |
| **Permanent attest request** (PROVISIONED device) | `wairua_set` refresh in RAM | Per-attest freshness — every permanent attest gets fresh entropy mixed with stored `ira`. |
| **First permanent attest request** (KORE device) | `ira_set` in eFuse | One-time provisioning ceremony. KOHI → TATARI → TAHU. Irreversible. |
| **Fresh-session "1" bit** on wire mid-conversation | `wairua_set` reset in RAM | Same as handshake — reset session state, generate new keys. |
| **OLED mode = RING-DETAIL** (local diagnostic) | None (display only) | Rings spin so the user can read frequencies. |

**Chain-instant for everything in between**: once `wairua_set` is established, every subsequent message in a session is authenticated by chaining off the previous message's hash. No new KOHI per message — "pretty much instant" after the first.

## KOHI — gather (the operation itself)

Run the sixteen-ring entropy gathering described in [TRNG.md](TRNG.md). 16 rings sampled by enclave_clk in parallel, per-cycle 16-way XOR into a 65,536-bit buffer, 16 running popcount counters AND 16 running toggle counters for per-ring dual health checks (popcount ∈ [N/8, 7N/8] AND toggles ≥ N/256), BLAKE3 extraction. Output: 256-bit value in SRAM, plus a `gather_complete` strobe.

If any combo fails its health check: KOHI aborts permanently. The chip remains in STATE 0 and refuses to operate. No retry — failed health check means broken silicon.

Expected duration: dominated by enclave_clk rate (~600 kHz). 5 sampling FFs fill 5 parallel 65,536-bit buffers in 65,536 enclave_clk cycles ≈ **110 ms**. Plus BLAKE3 (~1 ms). Total KOHI: **~111 ms** in the typical case.

## TATARI — wait

Random pre-burn delay, computed from the gathered `ira`:

```
delay_seed = BLAKE3("ferros-pipe/burn-delay" || ira)[0..3]
delay_ms   = (delay_seed mod 1024) + 256
```

Range: **256–1280 ms** uniform. Average ~768 ms.

**Purpose**: defeat timing-based power-cut attacks. An attacker who knows TAHU starts at fixed time T after power-on can rig a microcontroller to yank VDD at exactly T+Δms. Random TATARI breaks the prediction — the attacker has to gamble within a ~1-second window.

The 10 bits of timing information revealed via observation of the delay are public, but `delay_seed = BLAKE3(...)` is one-way, so revealing 10 bits of the BLAKE3 output doesn't compromise `ira`. The reverse cost goes from 2²⁵⁶ to 2²⁴⁶ — meaningless.

During TATARI the chip is intentionally idle (low power signature). External observer sees Phase 1's busy oscillations end, then ~1 second of quiet, then sudden burn-current spike. No distinguishable transition trigger.

## TAHU — burn

Burn sequence (atomic; cannot be interrupted by the FSM itself, only by external power loss):

```
1.  ira  → Slot 0A           (any partial-burn leaves all pairs corrupt)
2.  ira  → Slot 1A
3.  ira  → Slot 2A
4.  ira  → Slot 3A
5. ~ira  → Slot 0B           (B-burns transition pairs from corrupt to valid)
6. ~ira  → Slot 1B
7. ~ira  → Slot 2B
8. ~ira  → Slot 3B
9. (read-back verify each slot — fault if any mismatch, but cannot un-burn)
```

**All-A's-first ordering** is deliberate: any power-cut before step 8 completes leaves the chip in one of five well-defined intermediate states (described below in "Failure tolerance"). No power-cut point exposes a complete `(ira, ~ira)` cohort in any single pair until the final B is burned.

Burn duration on silicon eFuse (~10 µs/bit): 8 slots × 256 bits ≈ 17 ms. On SPI flash (FPGA emulation, ~3 ms/page): ~24 ms. Both well inside a reasonable tank-cap budget.

## Failure tolerance

The 4-pair design's operating threshold is "≥ 2 valid pairs agreeing on `ira`." Whether the chip survives a given number of failed slots depends on distribution:

| Failures (worst-case distribution) | Result |
|---|---|
| 1 slot | STATE 3 (HARA, operates) |
| 2 slots | STATE 2 or 3 (operates) |
| 3 slots distributed across 3 different pairs | STATE 1 (NGARO, brick) |
| 4 slots distributed 1-per-pair | STATE 1 (NGARO, brick) |
| 4 slots clustered in 2 pairs (both A and B die in same pair) | STATE 2 (operates) |
| 5+ slots distributed | STATE 1 (NGARO) |

**Guaranteed-survival number: 2 slot failures** (any distribution).

In practice, failures cluster spatially (localized defects, localized aging). The silicon layout places the 4 pairs in 4 physically-separated regions (NW/NE/SW/SE die quadrants) so a single localized defect can only kill one pair. Under this layout the realistic tolerance is "the chip survives the loss of any 2 pairs" — equivalently, "any 4 slot failures that happen to cluster into ≤2 pairs."

The pathological "exactly one failure per pair across all four pairs simultaneously" case requires a physical mechanism that selectively damages spatially-distant regions of the die at the same time. No such mechanism exists outside contrived adversarial conditions.

## Power-fail attack stack (defense in depth)

| Attacker capability | Defense |
|---|---|
| Pulls cable by hand (~100 ms reaction) | Random TATARI delay (256–1280 ms range) |
| Scripted relay with ms timing precision | Random TATARI + tank cap holds Phase 3 to completion |
| Logic analyzer + power-signature-triggered cutoff (µs precision) | Tank cap (≥100 µF on integrator's board) completes TAHU even after external VDD is yanked at first burn-current spike |
| Successful interruption despite tank cap | Brick: any A != B pattern leaves the chip in STATE 1, refusing all operation |

The integrator's datasheet specifies the tank cap requirement (≥100 µF for silicon, ≥150 µF for SPI-flash emulation) plus a brown-out detector that prevents TAHU from *starting* until VDD has been stable above threshold for some pre-arm interval.

## Indestructible from outside

PIPE deliberately omits any self-destruct path. There is no host-authenticated brick command, no scorch indicator, no retry-exhaustion counter, no fail-after-N-attempts logic. This is intentional.

**The reasoning**: PIPE's `ira` is 256 bits of entropy. The *meaning* of those bits comes from being bound to a user's TOKEN in the ferros identity layer — that binding is what makes the device's attestations authoritative. Without the TOKEN context, raw `ira` bits cannot impersonate anyone.

Every supposed use case for chip-level destruction dissolves:

| Stated use case | Why it doesn't need chip-level kill |
|---|---|
| Sell device, prevent new owner using old identity | Old TOKEN unbinds; new owner binds a different TOKEN — old `ira` cannot produce signed-by-old-owner messages because the signature framework doesn't recognize naked `ira` |
| End-of-life forensics protection | Raw `ira` bits without TOKEN binding are unattributable noise |
| Manufacturer recall | Revoke manufacturer's signature in the verification registry; individual chips don't need to participate |
| Government seizure | Same — extracted bits without TOKEN are meaningless |

The architectural payoff: **no command, key, host, or attacker can move the chip between its five lifelong states.** State transitions happen only via silicon physics. The chip is unrooted from any centralized authority.

## Runtime status byte

The chip naturally computes its state on every boot. Expose it through a status byte in every protocol response:

```
struct chip_status {
    state:                       u3,  // 0=KORE, 1=NGARO, 2/3/4=operating health levels
    layer1_retries_this_boot:    u4,  // 0=clean, higher=read flakiness rising
    reserved:                    u1
}
```

Hosts get full visibility:
- `state=4`: nominal
- `state=3`: device is fine; suggest replacement at next maintenance window
- `state=2`: device in marginal state; suggest replacement soon
- `state=1`: device bricked; host stops trying
- `state=0`: device not yet provisioned

`layer1_retries_this_boot` tracks how many of the 8 slot-reads needed majority-vote disagreement to resolve. Ora chips report 0; chips with rising aging report 1+. Host can track this metric over time to predict failure.

No fuses spent on status. It's a live readout the chip computes anyway.

## NGARO state — silent wire

When the chip enters STATE 1 (NGARO), it **permanently ceases driving the bidirectional data pin**. No heartbeat, no slot transitions, nothing. The host's pull-down resistor holds the line at quiescent zero forever.

A NGARO PIPE is **wire-level indistinguishable from an absent or unpowered device**. Both look like "no PIPE here" to the host, which prompts identical retry/alert behavior. This is the correct outcome — for the host's purposes there is no functional difference between "chip is broken" and "no chip", because neither produces a usable attestation.

**What triggers NGARO → silent wire**:

| Trigger | Source |
|---|---|
| Fewer than 8 of 16 ring health checks pass during KOHI | [TRNG.md §Byzantine-tolerant ring threshold](TRNG.md) |
| Fewer than Byzantine-majority valid OTP pairs at boot | [§Boot decision logic](#boot-decision-logic) |
| Multiple valid OTP pairs disagree on `ira` | same |
| TAHU burn ceremony interrupted partway | [§Failure tolerance](#failure-tolerance) |

All four triggers are **silicon-level truth conditions**, not protocol-driven. **No host command, no incoming wire pattern, no debug sequence, no malformed message can transition the chip into the silent-wire state**. The chip's silence describes a pre-existing physical reality; it is never a response to a remote action. This preserves the indestructible-from-outside invariant (§"Indestructible from outside") — the chip's destructibility is purely intrinsic.

**Forensic accessibility**: A silent chip's OTP and internal registers remain electrically readable (e.g., via decapsulation + microprobe). The state is preserved, not destroyed. The chip is *silently-bricked-from-the-wire*, not *destroyed*. This matters for failure-mode analysis and for the warranty/RMA pipeline — manufacturers can determine the specific failure mode from a returned silent chip.

**One-line implementation**: in the codec wrapper, `tx_drive_enable = !chip_ngaro`, where `chip_ngaro = trng.health_fail || otp_byzantine_fail || burn_interrupted_latched`. The codec is otherwise unchanged; silence is just the absence of drive.

## Host asks — enclave answers (no proactive state push)

The enclave **never proactively reports state on the wire**. The heartbeat carries no information beyond "I'm alive enough to drive"; the message layer is purely request-response. This is a deliberate side-channel-elimination measure:

- **Heartbeat layer**: pure idle pattern. Either present (chip alive) or absent (chip NGARO, unpowered, or unplugged). Three-way ambiguity in the absent case, by design.
- **Message layer**: the chip transmits only in direct response to a host-initiated request, and the response is a cryptographic derivation (e.g., domain-separated keyed-BLAKE3 over the request, the relevant state, and `ira` or `wairua`), never raw register fields in the clear.
- **No periodic state pings**, no wakeup advertisements, no auto-notifications on degradation events. A HARA or WHARA chip heartbeats identically to a ORA chip from the wire's perspective; the host learns the degradation level only by asking for an attestation, which exposes only an opaque derivation that bakes the state into the cryptographic output but reveals nothing of the input directly.

Designed-out side-channels: timing-based (no spontaneous transmissions reveal internal events), frequency-based (no periodic patterns leak clock characteristics), DC-level-based (the heartbeat is balanced and stateless). Anything the host needs to know about the chip's internal state has to be **asked for explicitly**.

When designing new modules (`handshake_fsm`, attest handlers, codec wrappers), the default question is: "what does the host need to ask for to get this information?" — never "when should I send this information?"

## What we test on FPGA

| Test | Validates |
|---|---|
| KOHI sim with behavioral clocks (Icarus) | 16-ring parallel sample + 16-way XOR, popcount AND toggle health checks fire, XOR pool fills, BLAKE3 hand-off triggers, ceremony reaches ORA |
| TATARI delay sim | `delay_ms` derives correctly from `ira`, FSM idles for the computed duration |
| TAHU sim with OTP emulator | Burn order correct, per-slot verify catches deliberate-corruption test injections |
| 5-state classifier sim | Pre-seed OTP emulator with each state's signature pattern, verify boot logic classifies correctly |
| Power-cut simulation | Halt FSM mid-burn at 8 different points, "boot" again, verify expected state |
| Real-silicon entropy gather | Flashed bitstream, OLED shows combo progression and final `ira` value (differs per power cycle) |

## What only silicon can validate

- Real eFuse physics (programming voltage, write-disturb, true OTP semantics)
- Tank-capacitor power-fail resilience (board level)
- Layer 1 read-error rates over device lifetime (accelerated aging)
- Metastability cell / TERO / subthreshold / shot-noise diode entropy (see [TRNG.md](TRNG.md) silicon section)
- NIST SP800-90B health tests on real silicon outputs

## Handshake protocol — line bringup → session

Wire framing (using slot-ownership notation: `h`/`H` = host slot value 0/1, `e`/`E` = enclave slot value 0/1):

**Idle pattern**: `hEhEhEhE...` — DC-balanced, every slot pair sums to `0+1 = 1`.

**Handshake event**: one `He` break (host inverts to 1, enclave's mirror-XOR codec auto-inverts to 0) embedded in a clean idle envelope.

**Envelope requirement**: `≥256 cycles of clean hE before` + `1 cycle of He` + `≥256 cycles of clean hE after`. Total handshake window ≈ 513 cycles ≈ 1024 individual slot positions. Two 8-bit counters (one per side of the break) gate the FSM.

**Handshake FSM**:

```
State PRE_HANDSHAKE:
  counter = 0 (8-bit)
  per cycle:
    if cycle is clean hE:
      counter++ (saturate at 255)
    elif cycle is He break:
      if counter == 255:           # had a full 256-cycle clean prefix
        → state CONFIRM_AFTER, counter = 0
      else:                        # premature break, no clean prefix
        → state PRE_HANDSHAKE, counter = 0
    else:                          # malformed
      → state PRE_HANDSHAKE, counter = 0

State CONFIRM_AFTER:
  per cycle:
    if cycle is clean hE:
      counter++ (saturate at 255)
      if counter == 255:           # full 256-cycle clean suffix
        → handshake confirmed
        → trigger KOHI #1 → wairua_set
        → state SESSION_LIVE
    else:                          # any break in confirmation window
      → state PRE_HANDSHAKE, counter = 0   # tear down, await fresh handshake
```

If **more than one break** appears anywhere in the 256+1+256 envelope, it's not a handshake — it's a 256-bit message attempt. Since the enclave has no `wairua_set` yet (no handshake), it silently ignores the attempted message. Host has wasted those bits and must retry with a proper handshake.

## Message framing — 256 bits, padded

Same envelope discipline as the handshake, just longer payload:

```
[256 cycles clean hE pad] [256-cycle message payload] [256 cycles clean hE pad]
```

- **256-cycle pre-pad**: lets the receiver know "a message is about to start" via the 8-bit counter reaching max
- **256-cycle payload**: the actual message bits, each bit encoded by one cycle (sender's slot value carries the bit; mirror-XOR codec keeps DC balance)
- **256-cycle post-pad**: separates this message from the next, lets the receiver finalize parsing

Back-to-back messages share the boundary pad (one message's post-pad serves as the next message's pre-pad), so steady-state throughput is one message per 512 cycles. At ~50 kHz slot rate (one slot pair = 1 cycle = 20 µs), one message = 10.24 ms = ~100 messages/sec sustained.

**All messages are 256 bits.** No length field, no variable framing. The 256-cycle envelope makes message boundaries unambiguous from the wire alone.

## Cross-reference

- Entropy source: [TRNG.md](TRNG.md)
- Protocol layer (uses `wairua` and `ira` to derive session secrets): [PROTOCOL.md](PROTOCOL.md)
- Physical topology (the wire `ira` ultimately serves): see header of [rtl/codec.v](rtl/codec.v)
