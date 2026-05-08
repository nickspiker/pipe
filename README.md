# PIPE — Physically Isolated Processing Enclave

Single-wire authenticated channel between an FPGA enclave and a host. Idle is a continuous heartbeat; either side initiates with one unexpected bit; data is raw keyed-BLAKE3 MAC output (random by construction → no encoding, no framing); done returns to heartbeat.

The enclave holds a write-once key, runs on a ring oscillator (no external clock, no PLL, no governed timebase), and exposes exactly one bidirectional IO pin to the outside world.

This is the FPGA prototype of the same write-once-key anchor that Glyph silicon will hold in a custom CSR. ferros's `ferros_vault::anchor` consumes the keyed-MAC output in both cases.

For the protocol description, see [ferros/PIPE.md](../ferros/PIPE.md).

## Status

**Phase D characterization complete.** Clock architecture chosen: small fast ring + /N divider.

| Phase | What | Status |
|---|---|---|
| A | Scaffold + vendored BLAKE3 + module skeletons | done |
| B | Ring osc characterization (32 stages → 46.22 MHz) | done — see `phase_b_results.csv` |
| C | BLAKE3 silicon Fmax (125 MHz stable, 131 MHz marginal) | done — see `phase_c_results.csv` |
| D | Ring + DCCA bringup, blake3 on ring, ring-vs-Fmax boundary (12-stage pass, 11-stage fail) | done |
| E | Production PIPE bitstream (5-stage ring + /N divider, no crystal) | next |

**Key lesson from D:** any ring oscillator output that drives more than a handful of FFs needs an explicit DCCA buffer between the ring loop and the synchronous logic. The `(* noglobal *)` attribute on the loop wires keeps the oscillator fast, but downstream distribution requires DCCA — without it, fabric routing skew causes setup/hold violations far below silicon Fmax. See `rtl/ring_osc.v` header.

## Build

**Production build** (will not work until module skeletons are filled in):

```bash
bash scripts/build_pipe.sh
```

**Measurement build** (Phase B — ready):

```bash
# Single stage count
bash scripts/build_freq_counter.sh --ring=7 --program
# read milli-MHz off the OLED

# Full sweep
for n in 3 5 7 9 11 13 17 21 25 31; do
    bash scripts/build_freq_counter.sh --ring=$n --program
    # read frequency off OLED, append to phase_b_results.csv
done
```

`RING_STAGES` must be odd (script enforces this). The bitstream uses the
25 MHz crystal as the **measurement reference only** — it is not the
production PIPE bitstream.

## Layout

```
rtl/                production sources — synthesized into pipe.bit
  blake3/           vendored BLAKE3 compression core (BSD-3, 6a-62)
  ring_osc.v        the only clock source (LUT4 NOT-cascade)
  trng.v            entropy accumulator → boot secret
  key_register.v    256b write-once, fanout=1 to blake3.i_chain
  boot_fsm.v        WAIT_ENTROPY → HASH_SEED → LOCK_KEY → SEED_PRNG → OPERATIONAL (trap)
  prng.v            ChaCha20 nonce generator
  ping_pong.v       blake3 ↔ shift_tx double buffer
  shift_tx.v        idle heartbeat + TX initiate
  shift_rx.v        8x oversample CDR + RX initiate detect
  cdc.v             2-flop synchronizer + half-duplex IO
  top.v             integration

rtl/measure/        measurement-only sources (Phase B/C bringup tools)
                    uses 25 MHz crystal as reference; never in pipe.bit
  top_extclk.v      vendored from spirix — RING_TEST mode = N-stage internal ring osc
  ssd1306_i2c.v     vendored from spirix — I2C bit-bang driver for OLED display

constraints/
  pipe.lpf                  production: no crystal pin, single bidir IO
  freq_counter.lpf          measurement-only (Phase B)
  netlist_assertions.py     5 invariants enforced post-synth

scripts/
  build_pipe.sh             production build
  build_freq_counter.sh     measurement build (Phase B)

sim/                        testbenches (Icarus / Verilator)
host/                       PC-side challenge/MAC verifier
data/                       on-chip ROM data (font, etc.)
patent/                     claim drafts + synthesis evidence
```

## Hard invariants (enforced by netlist_assertions.py)

1. `key_register.key_out` has fanout == 1 (single sink: blake3.i_chain)
2. Zero PCLKT pad usage (no external clock)
3. Exactly one bidirectional IO pin (pipe_pad)
4. boot_fsm OPERATIONAL is a trap state (no exit edge)
5. Zero forbidden clock primitives (EHXPLLL, EHXPLLL_CORE, OSCG, PLLREFCS)

Any commit that breaks one of these changes the threat model.

## Conventions

- Numeric values in prose follow ferros convention: `G#` prefix for hex, `A#` prefix for decimal. (Verilog literals stay standard `8'h...`.)
- BLAKE3 vendored from [spirix](../spirix/fpga/bench/blake3.v) at commit `a23538ee`. Pristine; PIPE-specific wrappers go beside it, never as patches.

## Author

Nick Spiker — fractaldecoder@proton.me
