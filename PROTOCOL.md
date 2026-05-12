# PIPE wire protocol

Single-wire, full-duplex, self-clocking, DC-balanced line code for the PIPE attestation channel. This document is the canonical reference both the silicon (Verilog) and host (Rust) implementations build against.

## Layer 1 — slot ownership

Time on the wire is divided into **slots**, each one bit-time `T` long. Slot index `s` increments every `T`. Slots alternate ownership:

| s mod 2 | owner | direction |
|---|---|---|
| 0 (even) | enclave | drives push-pull; host samples |
| 1 (odd)  | host    | drives push-pull; enclave samples |

Both sides drive their own slots **always** — even in idle. The off-side is HIGH-Z. There is no pull-up or pull-down on the line; with exactly one driver per slot at all times, the line is never floating and never contended.

Slot phase (which slot count is currently `s mod 2 == 0`) is established at boot from the idle pattern (see Layer 2) and tracked thereafter by the host's CDR.

## Layer 2 — line code: mirror-XOR

Each side maintains a **data stream** — a sequence of bits it intends to communicate. In idle, both streams are constant zero; activity is signaled simply by inserting non-zero bits.

### Encode rule

When it is your slot, drive the wire with:

```
wire[s] = own_idle  XOR  own_data[i]  XOR  other_last_data
```

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

### Properties (verified by example below)

1. **Self-clocking idle.** Both streams = 0 → wire = `1 0 1 0 1 0 …` (alternation by slot ownership). 100% edge density.
2. **DC-balanced for arbitrary data.** A `1` from one side gets compensated on the next slot's other-side drive via the `other_last_data` XOR term. Wire mean stays 50/50 after at most a 1-slot startup transient.
3. **No doorbell, no framing primitive at this layer.** A `1` in your data stream is enough — the receiver picks it up the same slot it appears.
4. **Full duplex with independent streams.** Encode and decode are self-inverse XOR operations; the two streams are decoded independently by each side without coordination.
5. **Single-edge interference window.** A data bit perturbs the wire only at its own slot and the next slot; thereafter the wire returns to a phase-shifted alternation that is still 50/50 and still self-clocking.

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

**Idle (both sides forever 0):**

```
slot:    0 1 2 3 4 5 6 7
own:     e h e h e h e h
e_data:  0 . 0 . 0 . 0 .
h_data:  . 0 . 0 . 0 . 0
wire:    1 0 1 0 1 0 1 0       (E h E h E h E h)
```

**Host injects one `1` at slot 11 (otherwise idle):**

```
slot:     8 9 10 11 12 13 14
own:      e h e  h  e  h  e
e_data:   0 . 0  .  0  .  0
h_data:   . 0 .  1  .  0  .
wire[8]  = 1 ^ 0 ^ 0           = 1   E
wire[9]  = 0 ^ 0 ^ 0           = 0   h
wire[10] = 1 ^ 0 ^ h_data[9]=0 = 1   E
wire[11] = 0 ^ 1 ^ e_data[10]=0 = 1  H   ← host's 1
wire[12] = 1 ^ 0 ^ h_data[11]=1 = 0  e   ← enclave compensates
wire[13] = 0 ^ 0 ^ e_data[12]=0 = 0  h
wire[14] = 1 ^ 0 ^ h_data[13]=0 = 1  E
```

DC over the 4-slot window `EHeh` is `1 1 0 0` = 50/50 ✓

**Both inject `1` at the same window:**

```
e_data:   . 0 . 1 . 0 .
h_data:   1 . 0 . 0 . 0       (host_data[5]=1, host_data[6]=0)
wire[10] = 1 ^ 0 ^ 0           = 1  E
wire[11] = 0 ^ 1 ^ 0           = 1  H
wire[12] = 1 ^ 1 ^ 1           = 1  E   ← enclave drives 1 (its data), no compensation
wire[13] = 0 ^ 0 ^ 1           = 1  H   ← host mirrors enclave's 1
wire[14] = 1 ^ 0 ^ 0           = 1  E
```

Pattern `EHEH` over 4 slots = all-1s instantaneously, but offset by surrounding 50/50 idle and a brief 1-slot debit.

**Pathological all-ones host stream (forever):**

```
host_data: . 1 . 1 . 1 . 1 . 1
e_data:    0 . 0 . 0 . 0 . 0 .
wire[0]  = 1 ^ 0 ^ 0 = 1   E
wire[1]  = 0 ^ 1 ^ 0 = 1   H
wire[2]  = 1 ^ 0 ^ 1 = 0   e
wire[3]  = 0 ^ 1 ^ 0 = 1   H
wire[4]  = 1 ^ 0 ^ 1 = 0   e
wire[5]  = 0 ^ 1 ^ 0 = 1   H
...
wire = 1 1 0 1 0 1 0 1 0 1 ...
```

After a 1-slot startup transient, wire = `1 0 1 0 1 0 …` — same alternating pattern as idle, just phase-shifted. DC = 50/50 ✓

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

### Message shape A — fresh-session (host → enclave, then enclave → host)

Host signal: a single `1` followed by 255 zeros in the host's data stream — a 256-bit pattern of `1, 0, 0, …, 0`.

Enclave response:
```
session_secret ← TRNG.draw(256)
H_req          ← BLAKE3(session_secret)
H_resp         ← BLAKE3(~session_secret)
```
Enclave emits `session_secret` (256 bits) in its data stream.

Host, on receiving the 256-bit secret, performs the same `H_req` / `H_resp` derivation. Both sides are now synchronized.

Detection: enclave buffers the host's first 256 data bits after idle. If they are exactly `1, 0, 0, …, 0` it is a fresh-session request; any other pattern is the start of a message-B exchange (probability of message B accidentally matching: 2⁻²⁵⁵).

### Message shape B — authenticated exchange (512 bits each direction)

Host's request, 512 bits sent over 512 host slots:

```
bits   0..255 :  X1 = message_req  XOR  H_req
bits 256..511 :  X2 =  BLAKE3(message_req)  XOR  H_resp        (mode = SESSION)
                 X2 = ~BLAKE3(message_req)  XOR  H_resp        (mode = PERMANENT)
```

Enclave verifies by recovering `message_req = X1 XOR H_req`, computing `BLAKE3(message_req)`, and checking which of `BLAKE3(message_req) XOR H_resp` or `~BLAKE3(message_req) XOR H_resp` equals `X2`. The matching case determines mode. No match → corruption → drop, do not advance pads (host will retry or fresh-session).

Enclave computes:
```
active_key   = session_secret    (SESSION)
             = permanent_key     (PERMANENT, eFuse-backed; burn-on-first-use)
message_resp = BLAKE3.keyed(active_key, message_req)
```

Enclave's response, 512 bits sent over 512 enclave slots, mirrors the requested mode:

```
bits   0..255 :  X1 = message_resp  XOR  H_req
bits 256..511 :  X2 =  BLAKE3(message_resp)  XOR  H_resp        (SESSION echo)
                 X2 = ~BLAKE3(message_resp)  XOR  H_resp        (PERMANENT echo)
```

Host verifies the same way the enclave did. On successful verification both sides advance:
```
H_req  ← BLAKE3(message_req)
H_resp ← BLAKE3(message_resp)
```

A mismatch on either side is detected at verify time. The corrupted exchange is dropped, pads are *not* advanced, the other side will be desynced on next attempt → host issues fresh-session and both sides reset.

### Properties

- **One escape hatch for everything.** Bit error, lost response, suspicious payload, host software lost state, enclave hung mid-burn — fresh-session resets all of it. No partial-recovery protocol to design.
- **Forward secrecy after exchange 1.** Pads ratchet via one-way hashes; recovering state at exchange N reveals nothing about exchanges < N.
- **Cross-session repetition hidden after exchange 1.** Two sessions doing the same exchange-2 produce entirely different wire bytes because `H_req` and `H_resp` at exchange 2 depend on session-specific exchange-1 message hashes. (Exchange 1 leaks `msg XOR BLAKE3(msg) XOR K_session` to anyone computing X1 XOR X2 — this is the known residue of the dual-init from a single seed, intentionally accepted because eavesdropping is out of scope.)
- **Mode-confusion immune.** Same `message_req` under SESSION vs PERMANENT produces different second-halves (hash vs bit-flipped hash). An attacker cannot replay a SESSION response as a PERMANENT response.
- **Burn timing observable but unexploitable.** First PERMANENT request takes ~1–2 s (entropy spin-up + TRNG-randomized burn timing + read-verify), subsequent requests are ~ms. The wire reveals "the burn happened around now" but not "when within that window each fuse blew" or "what bits got burned."
- **Bandwidth-bounded.** At 50 kHz slot rate, one exchange (~2 × 1024 slots after counting both directions) is ~40 ms. Brute-forcing a 256-bit key over the wire is ≈ 2²⁵⁶ × 0.04 s = beyond cosmological. Slow is the security property.
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
