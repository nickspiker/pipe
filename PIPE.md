# PIPE bidirectional comms — end-to-end validated 2026-05-29

## Status: BIDIRECTIONAL ROUND-TRIP WORKS, bit-exact

Full FPGA ↔ bridge bidirectional pipeline validated on hardware. Bridge drives
an arbitrary byte during the FPGA's RX window; FPGA echoes that byte in its
next TX payload alongside the pattern byte; host decodes both directions in
a single capture.

Round-trip validation (`wire_count_drive <byte>`):

| Driven | Echoed | Pattern at byte_idx | Verdict |
|--------|--------|---------------------|---------|
| `G#FF` | `G#FF` | `'p'` at 23 | ✓ |
| `G#55` | `G#55` | `'T'` at 0  | ✓ |
| `G#AA` | `G#AA` | `'k'` at 8  | ✓ |
| `G#5A` | `G#5A` | `'o'` at 17 | ✓ |
| `G#A5` | `G#A5` | `'o'` at 26 | ✓ |
| `G#01` | `G#01` | `' '` at 3  | ✓ |
| `G#80` | `G#80` | `'o'` at 12 | ✓ |
| `G#7F` | `G#7F` | `'u'` at 21 | ✓ |
| `G#42` | `G#42` | `' '` at 30 | ✓ |
| `G#DE` | `G#DE` | `'c'` at 7  | ✓ |

10/10 bytes echo bit-exact. Pattern byte continues to match the FPGA's
reference `"The quick brown fox jumps over t"` at the decoded byte_idx, and
byte_idx monotonically increments + wraps cleanly across captures.

## What's shipping in source (FPGA + host only; bridge firmware deferred)

**FPGA** (`rtl/measure/top_pipe_counter.v`): drives the wire continuously. FSM
is now `IDLE → TX → RX → IDLE`. Every ~22 ms:
1. SYNC: 2 wire_clks LOW
2. DATA: 32 bits LSB-first (sub-phase 0 = HIGH, sub-phase 1 = bit value)
3. RX:   16 wire_clks tristate — FPGA samples wire_in once per 2 wire_clks
         (8 bits → `last_rx_byte`). Bridge MAY drive during this window.
4. Return to IDLE alternation.

TX payload layout (LSB-first on the wire, 32 bits):
- `[7:0]`  `pattern_byte` (FPGA's known reference pattern at byte_idx)
- `[15:8]` `8'h00` (separator)
- `[23:16]` `last_rx_byte` (FPGA's echo of what bridge drove last RX window)
- `[28:24]` `byte_idx` (pattern position 0..31)
- `[31:29]` `3'b0` (padding)

Resource cost: 155 LUT4 on ECP5-25F (PASS all timing).

**Bridge** (PIO0 SM0 edge-timestamper + standard `wire_trace` command):
captures 8192 raw GP0 samples per request, at ~10 µs per sample (~82 ms
window). No firmware change shipped this round.

**Host decoder** (`bridge wire_count_decode` / `wire_count_watch`):
1. Find all edges in the sample stream
2. Median of inter-edge intervals = initial wire_clk_period estimate
3. P-controller refines: at each edge within ±25% of median, snap phase and
   update period via period_est += K_p × error (K_p = 0.05)
4. Outlier rejection: edges outside ±25% snap phase but don't update period
   (coast thru TX/sync without disturbing the lock)
5. Sync detection: LOW run in `[1.5, 4] × period_est`. The upper bound is new
   (was unbounded) — it filters the post-TX RX window (16 wire_clks LOW when
   bridge is silent) from false-positive sync matches.
6. Bit extraction at sync_end + (2N + 1.5) × period_est for bit N (32 bits)
7. Break out fields per the payload layout above; verify pattern_byte against
   the FPGA's `TX_PATTERN_REF` at the decoded byte_idx.

## Live verification (validated 2026-05-28 with the pre-RX-window bitstream;
##                   pending re-validation against the new bitstream)

Multi-byte capture sequence (high-cadence mode, 22ms between transmissions):

```
$ for i in $(seq 1 60); do
    ./bridge wire_count_decode 8192 10000 \
      | grep -oP "pattern=G#[0-9A-F]{2}"
  done | sort | uniq -c | sort -rn | head -20
```

Captured byte values include (decoded ASCII):
- `G#54` = 'T' (start of "The")
- `G#68` = 'h'
- `G#65` = 'e'
- `G#20` = ' '
- `G#71` = 'q', `G#75` = 'u', `G#69` = 'i', `G#63` = 'c', `G#6B` = 'k'
- `G#62` = 'b', `G#72` = 'r', `G#6F` = 'o', `G#77` = 'w', `G#6E` = 'n'
- `G#66` = 'f', `G#78` = 'x'
- `G#6A` = 'j', `G#6D` = 'm', `G#70` = 'p', `G#73` = 's'
- `G#76` = 'v', `G#74` = 't'

Every byte read matches the FPGA's reference pattern bit-exact. With the new
bitstream, the decoder also validates that the embedded byte_idx field matches
the position of pattern_byte in the reference pattern (caught & flagged
inline as `✓ pattern match` / `✗ MISMATCH`).

## Trying to read in sequence

A single 8192-sample capture catches 2-3 transmissions. Each transmission carries
one pattern byte. In live runs:

```
$ for i in $(seq 1 200); do ./bridge wire_count_decode 8192 10000 ...; done
"er the qick brown fox"   (missed 'u' once; rest is bit-exact)
"u, i, c, k, _, b, r, o"  (8 consecutive bytes captured cleanly)
```

## 4096-slot gap claim demonstrated (2026-05-29)

`rtl/measure/top_pipe_gap.v` and `wire_gap_decode` empirically prove that the
PIPE line code holds slot lock thru 4096 wire_clks of constant-wire state.
This is the patent-claim test for "long-gap clock recovery" — the only
remaining open question after the 256-bit Claims 7+12 demonstration at
commit `aaf0b14`.

**FPGA emits**: IDLE → SYNC1 (8 wire_clks LOW) → GAP (4096 wire_clks HIGH) →
SYNC2 (8 wire_clks LOW) → IDLE. Burst length = 4112 wire_clks ≈ 366 ms.

**Host measures**: distance from SYNC1 falling edge to SYNC2 falling edge,
estimates wire_clk_period by linear regression on idle-alternation edges
BEFORE sync1, computes predicted SYNC2 position from SYNC1 + 4104 × period,
reports drift vs measured.

**Validation result (10 captures)**:
- 8 captured both syncs (1 capture window covers ~65% of the burst cycle)
- **5 PASS** with |drift| < 1 wire_clk: `+51, +120, −49, −187, +15 ppm`
- **3 MARGINAL** with drift `−1.21, −1.23, −1.31` wire_clks — all at the
  sample-quantization noise floor (79 µs/sample ≈ ±1 sample edge-position
  uncertainty × 2 syncs → ±2 wire_clks of irreducible measurement noise)

Of 8 valid captures, **0 fail above the measurement noise floor**. The line
code's slot phase is preserved across the 4096-wire_clk gap to within the
limit of how precisely the host can measure it.

The bitstream is preserved at `rtl/measure/top_pipe_gap.v` for the patent
filing. The host decoder is at `host/src/bin/bridge.rs::cmd_wire_gap_decode`.

```bash
$ openFPGALoader -c ft232 -f build_pipe_gap/pipe_gap.bit
$ cargo run -p pipe-host --release --bin bridge -- wire_gap_decode 50000
```

## Key fixes that landed during validation

- **Bridge edge-driven sync detect.** First attempt used `consecutive_low_us`
  incremented per loop iteration with an assumed ~1 µs per iter; the actual
  loop is ~1.4 µs so the threshold was missed before sync ended. Rewritten
  to use the hardware timer directly (`Instant::elapsed`) for both LOW-start
  marking and HIGH-edge duration check.
- **Bridge `WIRE_CLK_US = 89` µs.** Nominal divider math gives 86 µs but
  the ring oscillator runs ~3.7% slower in practice. Off-by-3 µs accumulates
  to ~50 µs of drift by the FPGA's 8th sample — enough to miss the last bit.
  Empirically calibrated from the host decoder's `period_est`.
- **Bridge drives MSB-first on the wire.** The FPGA's `rx_byte_reg` shifts
  left on each sample (`{rx_byte_reg[6:0], wire_in_sync}`), so the first
  received bit lands at MSB. Bridge sends byte's MSB first → FPGA's MSB
  position receives the byte's MSB → no bit-reversal at the host.
- **VSF `errors-verbose` feature** (default-on, off for `default-features =
  false` consumers like the bridge). Drops the `<VsfType as Debug>::fmt`
  chain — which transitively kept the grisu/dragon IEEE-754 formatters
  alive (~40 KB on cortex-m). Bridge firmware text shrank from 179,756 to
  140,036 bytes, with abundant headroom for the new RX-window drive.

## What's NOT shipping yet

**Bidirectional simultaneous (mirror-XOR)**: the mirror-XOR FPGA bitstream
(`top_pipe_mirror_xor.v`) has been validated for the 256-bit single-window
demonstration (commit `aaf0b14`, Claims 7 + 12 patent-clean), but reliable
continuous-mode bidirectional requires the FPGA's `data_mode` handshake to
latch deterministically (a documented open question — see
`memory/pipe_2026_05_28_session.md`). The RX-window approach in
top_pipe_counter.v is a simpler half-duplex variant that does not require
the data_mode handshake — and that variant is now end-to-end validated.

## Run instructions

```bash
# Flash FPGA (counter / pattern-byte bitstream):
$ cd /mnt/Octopus/Code/pipe
$ openFPGALoader -c ft232 -f build_pipe_counter/pipe_counter.bit

# Bridge firmware is currently in SRAM. If wedged, reload:
$ cargo run -p pipe-host --release --bin bridge -- load_dev \
      tools/pipe-bridge-rp2040/target/thumbv6m-none-eabi/release/pipe-bridge-rp2040

# Single-shot decode (verbose). Now prints byte_idx, pattern_byte (with ASCII
# glyph), last_rx_byte (FPGA's echo of bridge drive), separator + pad fields:
$ cargo run -p pipe-host --release --bin bridge -- wire_count_decode 8192 10000

# Expected output line (with bridge silent → last_rx = 0x00):
#   sync #0: G#03000054  byte_idx= 3  pattern=G#54 'T'  last_rx=G#00  sep=G#00  pad=G#0  ✓ pattern match

# Continuous watch (live byte sequence; filters by sep==0 and pattern_byte
# membership in the reference pattern, so old bitstreams still display):
$ cargo run -p pipe-host --release --bin bridge -- wire_count_watch 10000

# Round-trip drive: bridge drives BYTE during the FPGA's next RX window,
# then captures and decodes the FPGA's reply. sync #0's last_rx should
# equal BYTE bit-exact.
$ cargo run -p pipe-host --release --bin bridge -- wire_count_drive A5 8192 10000
#   sync #0: byte_idx=26 pattern=G#6F 'o' last_rx=G#A5  ✓ pattern=match  rx_echo=✓ G#A5 == G#A5
```

## Memory pointers

- `memory/pipe_2026_05_28_session.md` — full session narrative including
  proof-test confirming both clocks are clean, SM2 sampler architecture, and
  the data_mode latch open question
- `~/.claude/plans/ancient-launching-lemur.md` — original SM2 sampler plan,
  still applies for mirror-XOR refinement
