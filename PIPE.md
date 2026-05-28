# PIPE listen pipeline — end-to-end validated 2026-05-28

## Status: FPGA→bridge bit-exact decode WORKS

The listen pipeline is proven end-to-end. The bridge correctly receives and decodes
arbitrary FPGA-side data, bit-by-bit, against the known reference pattern.

## What's shipping at HEAD (3248778)

**FPGA** (`rtl/measure/top_pipe_counter.v`): drives the wire continuously. Every
~22 ms transmits one byte from the 32-char pattern "The quick brown fox jumps
over t". byte_idx wraps 0..31, so consecutive transmissions reveal the pattern
in sequence.

**Bridge** (PIO0 SM0 edge-timestamper + standard wire_trace command): captures
8192 raw GP0 samples per request, at ~10 µs per sample (~82 ms window).

**Host decoder** (`bridge wire_count_decode` / `wire_count_watch`):
1. Find all edges in the sample stream
2. Median of inter-edge intervals = initial wire_clk_period estimate
3. P-controller refines: at each edge within ±25% of median, snap phase and
   update period via period_est += K_p × error (K_p = 0.05)
4. Outlier rejection: edges outside ±25% snap phase but don't update period
   (coast through TX/sync without disturbing the lock)
5. Sync detection: any LOW run > 1.5 × period_est
6. Bit extraction at sync_end + (2N + 1.5) × period_est for bit N

## Live verification

Multi-byte capture sequence (high-cadence mode, 22ms between transmissions):

```
$ for i in $(seq 1 60); do
    ./bridge wire_count_decode 8192 10000 | grep -oP "G#000000[0-9A-F]{2}"
  done | sort | uniq -c | sort -rn | head -20
```

Captured byte values include (decoded ASCII):
- `0x54` = 'T' (start of "The")
- `0x68` = 'h'  
- `0x65` = 'e'
- `0x20` = ' '
- `0x71` = 'q', `0x75` = 'u', `0x69` = 'i', `0x63` = 'c', `0x6B` = 'k'
- `0x62` = 'b', `0x72` = 'r', `0x6F` = 'o', `0x77` = 'w', `0x6E` = 'n'
- `0x66` = 'f', `0x78` = 'x'
- `0x6A` = 'j', `0x6D` = 'm', `0x70` = 'p', `0x73` = 's'
- `0x76` = 'v', `0x74` = 't'

Every byte read matches the FPGA's reference pattern bit-exact.

## Trying to read in sequence

A single 8192-sample capture catches 2-3 transmissions. Each transmission carries
one pattern byte. In live runs:

```
$ for i in $(seq 1 200); do ./bridge wire_count_decode 8192 10000 ...; done
"er the qick brown fox"   (missed 'u' once; rest is bit-exact)
"u, i, c, k, _, b, r, o"  (8 consecutive bytes captured cleanly)
```

## What's NOT shipping yet

**Bidirectional**: bridge→FPGA path. The mirror-XOR FPGA bitstream
(`top_pipe_mirror_xor.v`) has been validated for the 256-bit single-window
demonstration (commit `aaf0b14`, Claims 7 + 12 patent-clean), but reliable
continuous-mode bidirectional requires the FPGA's `data_mode` handshake to
latch deterministically (a documented open question — see
`memory/pipe_2026_05_28_session.md`).

For a clean continuous bidirectional demo:
1. Add an RX window to `top_pipe_counter.v`: every Nth wire_clk, FPGA tristates
   and samples `wire_in_sync` into a register
2. Modify bridge to drive a known byte sequence during the RX window
3. FPGA includes last-received-byte in its TX payload (upper bits of count)
4. Bridge verifies round-trip: each captured count's upper bits == byte the
   bridge drove last RX window

This is ~50 lines of new verilog + a parameter for the bridge's TX scheduler.
Doable in a follow-up session.

## Run instructions

```bash
# Flash FPGA (counter / pattern-byte bitstream):
$ cd /mnt/Octopus/Code/pipe
$ openFPGALoader -c ft232 -f build_pipe_counter/pipe_counter.bit

# Bridge firmware is currently in SRAM. If wedged, reload:
$ cargo run -p pipe-host --release --bin bridge -- load_dev \
      tools/pipe-bridge-rp2040/target/thumbv6m-none-eabi/release/pipe-bridge-rp2040

# Single-shot decode (verbose):
$ cargo run -p pipe-host --release --bin bridge -- wire_count_decode 8192 10000

# Continuous watch (live tick counter — works best at 1 Hz cadence,
# i.e. IDLE_TICKS=11600 in the verilog):
$ cargo run -p pipe-host --release --bin bridge -- wire_count_watch 10000
```

## Memory pointers

- `memory/pipe_2026_05_28_session.md` — full session narrative including
  proof-test confirming both clocks are clean, SM2 sampler architecture, and
  the data_mode latch open question
- `~/.claude/plans/ancient-launching-lemur.md` — original SM2 sampler plan,
  still applies for mirror-XOR refinement
