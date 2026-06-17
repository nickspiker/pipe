# PIPE — Physically Isolated Processing Enclave

> **Patent Pending** — U.S. Provisional Application No. 63/093,040, filed June 17, 2026: *Method and Apparatus for Vendor-Free Domain-Separated Device Attestation via Owner-Initiated Cryptographic Provisioning.* The full provisional specification is in [`patent/`](patent/). Source-available for reading and audit, not open source — see [LICENSE](LICENSE); implementation is by agreement.

Single-wire authenticated channel between an FPGA enclave and a host. Idle is a continuous heartbeat; either side initiates with one unexpected bit; data is raw ragu output (chaos-amplified keyed-BLAKE3, random by construction → no encoding, no framing); done returns to heartbeat.

The enclave holds a write-once key, runs on a ring oscillator (no external clock, no PLL, no governed timebase), and exposes exactly one bidirectional IO pin to the outside world.

This is the FPGA prototype of the same write-once-key anchor that Glyph silicon will hold in a custom CSR. ferros's `ferros_vault::anchor` consumes the ragu output in both cases.

For the protocol description, see [ferros/PIPE.md](../ferros/PIPE.md).

## Documents

| Document | Topic |
|---|---|
| [TRNG.md](TRNG.md) | Entropy source — 16 ring oscillators, slow universal sampler, per-ring popcount+toggle dual health check, 8-of-16 byzantine threshold, BLAKE3 extraction, silicon-tapeout mapping |
| [IRA.md](IRA.md) | The 256-bit boot secret (`ira`), 8-slot inverted-pair OTP geometry, KOHI/TATARI/TAHU provisioning ceremony, 5-state model, indestructible-from-outside principle |
| [PROTOCOL.md](PROTOCOL.md) | Wire-layer protocol (mirror-XOR codec, slot ownership, asymmetric drive, session secrets) |

## Status

**Phase D characterization complete.** Clock architecture chosen: small fast ring + /N divider.

| Phase | What | Status |
|---|---|---|
| A | Scaffold + vendored BLAKE3 + module skeletons | done |
| B | Ring osc characterization (32 stages → 46.22 MHz) | done — see `phase_b_results.csv` |
| C | BLAKE3 silicon Fmax (125 MHz stable, 131 MHz marginal) | done — see `phase_c_results.csv` |
| D | Ring + DCCA bringup, blake3 on ring, ring-vs-Fmax boundary (12-stage pass, 11-stage fail) | done |
| E.1 | Wire bringup, codec, OLED instrumentation, host CDR | done |
| E.2 | 16-ring TRNG (odd primes 3..59, slow universal sampler, popcount+toggle dual health, 8-of-16 byzantine, BLAKE3 extraction) | sim PASS — see [TRNG.md](TRNG.md) |
| E.3 | `ira_fsm` (KOHI → TATARI → TAHU), 8-slot inverted-pair OTP, 5-state classifier, NGARO-silent wire | sim PASS — see [IRA.md](IRA.md) |
| E.4 | Production PIPE bitstream (TRNG + ira_fsm + codec, no crystal) | synth-clean, PnR convergence WIP (top_pipe_ira) |

**Key lesson from D:** any ring oscillator output that drives more than a handful of FFs needs an explicit DCCA buffer between the ring loop and the synchronous logic. The `(* noglobal *)` attribute on the loop wires keeps the oscillator fast, but downstream distribution requires DCCA — without it, fabric routing skew causes setup/hold violations far below silicon Fmax. See `rtl/ring_osc.v` header.

**Host CDR precision target.** The bridge ([`tools/pipe-bridge-rp2040`](tools/pipe-bridge-rp2040)) recovers slot timing via PIO0 SM0 edge timestamping at 2 sys_clk resolution; per-edge measurement std is ~1 cyc (16 ns) and the proportional tracker reaches 2^12 stability per slot at `p_shift=8` (verified via `bridge tune_p`). A 256-bit exchange only needs 2^8 (1 slot drift over 256 slots). 2^12 over 2^8 is **2^4 = 16× margin** over the requirement.

**Where the floors actually sit.** Three noise sources stacked:
1. PIO 2-cyc quantization — ~1 cyc/edge std. The current measurement floor.
2. Ring-osc cycle-to-cycle jitter — ~0.07 cyc/edge (200 ppm × 365-cyc slot, from OLED freq variance). ~14× below the PIO floor.
3. Thermal drift — ~700 ppm/sec. Negligible at exchange scale (740 µs), dominant past ~140 edges of averaging.

Theoretical exchange-scale floor with measurement noise removed: **~2^16** at `p_shift=8`, ring-osc jitter as the wall. Thermal drift then caps any longer averaging window in the same ballpark. We deliberately stopped at 2^12 — going to 2^16 would mean a 1-cycle PIO loop or a dedicated counter SM, and we already have 2^4 margin over the protocol minimum. The 4 bits we left on the table buy a simpler, more reviewable PIO program; quantum/electronic floors (kT/C, supply noise, fabric coupling) sit further down at ~2^28+ but you can't get there from FPGA fabric.

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
  ring_osc.v        the only clock source (LUT4 NOT-cascade) — 16 instances (odd primes 3..59) inlined per top
  trng.v            16-ring slow-sampler entropy gather, per-ring popcount + toggle health, single XOR'd buffer
  blake3_tree.v     full BLAKE3 tree wrapper over the trng buffer (8 chunks → 4 → 2 → 1 root); spec-tested vs Rust reference
  ira_fsm.v         persistent provisioning state machine: KOHI → TATARI → TAHU → OPERATIONAL (trap)
  otp.v             8-slot inverted-pair eFuse interface (silicon: native macro; FPGA: SPI flash emulator)
  inverted_pair_verify.v  shared 4-pair XOR-to-all-ones classifier with popcount+toggle slot sanity (used by both OTP and wairua RAM)
  key_register.v    256b write-once, fanout=1 to blake3.i_chain
  prng.v            ChaCha20 nonce generator
  ping_pong.v       blake3 ↔ shift_tx double buffer
  codec.v           mirror-XOR codec (asymmetric pull-down drive)
  slot_clk.v        bit-slot clock generator
  wire_io.v         BB primitive + 2-FF input synchronizer
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
host/                       PC-side challenge / ragu verifier
data/                       on-chip ROM data (font, etc.)
patent/                     claim drafts + synthesis evidence
```

## Hard invariants (enforced by netlist_assertions.py)

1. `key_register.key_out` has fanout == 1 (single sink: blake3.i_chain)
2. Zero PCLKT pad usage (no external clock)
3. Exactly one bidirectional IO pin (pipe_pad)
4. `ira_fsm` has no transition out of OPERATIONAL (trap state) and no transition that decreases `state` value (provisioning is forward-only)
5. Zero forbidden clock primitives (EHXPLLL, EHXPLLL_CORE, OSCG, PLLREFCS)
6. `ira_fsm` has no input that could trigger a state-machine reset other than POR (no host-authenticated self-destruct path exists)

Any commit that breaks one of these changes the threat model. See [IRA.md](IRA.md) for why the chip has no killswitch and why state transitions are forward-only.

## Conventions

- Numeric values in prose follow ferros convention: `G#` prefix for hex, `A#` prefix for decimal. (Verilog literals stay standard `8'h...`.)
- BLAKE3 vendored from [spirix](../spirix/fpga/bench/blake3.v) at commit `a23538ee`. Pristine; PIPE-specific wrappers go beside it, never as patches.

## Author

Nick Spiker — fractaldecoder@proton.me
