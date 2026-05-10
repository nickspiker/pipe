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

## Layer 3 — framing (per-application)

Mirror-XOR is a stream code; it does not impose framing. For attestation, the convention is:

- **Idle:** both data streams = 0.
- **Host attestation request:** stream `1` (start bit) || 256 challenge bits || `0…`.
- **Enclave response (when host's start bit is detected):** capture next 256 bits as challenge, compute `r = ragu(key, kernel_layered_input(challenge))`, stream `1` (start bit) || 256 ragu bits || `0…`.
- **Host (when enclave's start bit is detected):** capture next 256 bits as ragu, verify.

Total transaction = 257 bits each direction = 514 slots. At a 1 MHz slot rate, ~514 µs. Both directions can stream concurrently — host is allowed to begin its 257-bit request while the enclave is still finishing a previous response, and vice versa.

The single `1` start bit is sufficient because a noise-induced bit-error rate over a short PCB-level wire is effectively zero. For an isolated/optical embodiment with non-zero BER, this layer is replaced by a longer sync sequence (e.g., a Barker code) — Layer 1 doesn't change.

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
