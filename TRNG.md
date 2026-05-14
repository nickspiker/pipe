# TRNG — Entropy Source

PIPE's entropy source. Eight ring oscillators with mutually-prime stage counts (the first 8 odd primes), sampled by `enclave_clk` (a slower 9th ring divided down to ~600 kHz). Per enclave_clk cycle: all 8 rings sampled in parallel, 8-way XOR into a single 65,536-bit buffer, 8 running popcount counters for per-ring health attribution. BLAKE3 extraction at end. Output is a 256-bit value (`ira` for permanent provisioning, `wairua` for session keys) — see [IRA.md](IRA.md) for what gets done with the output.

This is the `KOHI` ("gather") phase of the provisioning ceremony. The downstream phases (`TATARI`, `TAHU`) are documented in [IRA.md](IRA.md).

## Eight rings, prime stages

Eight `ring_osc` instances with stage counts **3, 5, 7, 11, 13, 17, 19, 23** — the first 8 odd primes. All mutually incommensurate, so no harmonic correlation can develop between any pair. Frequency spread ~7.4× from fastest to slowest:

| Ring | Stages | Expected frequency on ECP5 speed-6 (measured 3-stage = 512 MHz) |
|---|---|---|
| R₀ | 3 | ~480 MHz (measured 512 MHz) |
| R₁ | 5 | ~290 MHz |
| R₂ | 7 | ~210 MHz |
| R₃ | 11 | ~135 MHz |
| R₄ | 13 | ~115 MHz |
| R₅ | 17 | ~88 MHz |
| R₆ | 19 | ~78 MHz |
| R₇ | 23 | ~65 MHz |

8 is a power of 2, which makes the XOR-tree and popcount-counter widths fit cleanly into native counter sizes. R₇ at ~65 MHz is still ~108× faster than enclave_clk's 600 kHz — the slow-samples-fast regime holds for every ring.

These are nominal — actual placement varies ±10% across seeds due to fabric routing. Each ring is its own `ring_osc.v` instance with the same `(* keep *)` + `(* noglobal *)` attributes that prevent yosys from optimizing the loop away.

**Parity is not a constraint.** The canonical "N inverters in a loop must have N odd" rule does not apply because [ring_osc.v](rtl/ring_osc.v) uses a single inverter plus (N−1) buffers — only one inversion per loop, so any N ≥ 1 oscillates. Even-stage rings would work just as well; we picked these stage counts for *frequency incommensurability*, not parity.

**Why prime**: any two rings of stage counts `m` and `n` produce frequencies in ratio approximately `n/m`. If both are prime, that ratio is irreducible — no integer multiple of one frequency aligns with the other. Result: phase between any two rings drifts continuously, no harmonic lock can form, the metastability sampler always sees the sampled signal in an unpredictable phase relative to the sampler clock. (If we used 6 and 12 stages, for instance, their 1:2 frequency ratio would invite phase-lock; primes avoid this entirely.)

Other valid choices in the same family: **2, 3, 5, 7, 11, 13, 17, 19, 23** are all prime. We could substitute any of these. The 3-through-13 set was picked for a moderate frequency spread (4.3×) that keeps even the slowest ring well above the 1/(BLAKE3 latency) floor while keeping the fastest ring below ECP5 fabric distortion limits.

**Layered decorrelation beyond primes.** Prime stage counts only buy irreducible *rational* ratios. The real-world layered stack pushes ratios into approximately-irrational territory:

| Layer | Mechanism | Defeats |
|---|---|---|
| Prime stage counts | Irreducible `N/M` ratios | Simple harmonics (2:1, 3:1, etc.) |
| Heterogeneous stage delays | One inverter + (N−1) buffers per ring → `period = 2(t_inv + (N−1)·t_buf)`. At silicon, `t_inv ≠ t_buf` typically (buffer = 2× internal inverter delay → slower). On FPGA, routing-delay variation per LUT-to-LUT hop dominates. Effect: a 3-stage and 5-stage ring don't sit at exactly 3:5; they sit at something like **3.1 : 5.1** | Phase-lock at clean M:N integer alignments |
| Independent thermal noise | Each ring has its own ~kT/C noise floor adding stochastic per-cycle phase walk | Sustained phase coherence between any two rings |
| Placement variance (±10% across PnR seeds on FPGA; process variance at silicon) | Each ring instance has a physically-unique absolute frequency that's not predictable from the design | Predictability across nominally-identical chips |

The decorrelation is *multiplicatively strong* — even if one layer were defeated, the other three independently prevent harmonic alignment. This matters because the entropy quality argument doesn't depend on any single physical assumption being perfect.

## enclave_clk as universal sampler

Earlier drafts of this design proposed a 20-combination schedule where each ring took turns sampling each other ring. That scheme had a **fundamental flaw**: fast-clock-sampling-slow-signal produces deterministic patterns, not entropy. A 3-stage ring at ~480 MHz sampling an 11-stage ring at ~135 MHz fires 3.6× per source half-period and outputs `111000011110001110...` — the actual entropy rate collapses to ~1 bit per *ring-period of phase drift*, not per sample.

The fix: **always sample slow-clock-on-fast-signal**. Use `enclave_clk` (~600 kHz, derived from a 9th ring oscillator divided by SLOT_DIV) as the sole sampling clock for all 8 entropy rings. Between two enclave_clk edges (~1.6 µs apart), each entropy ring traverses 100–800 of its own cycles — far more than a single transition's worth — so its phase walks randomly under thermal noise. Each enclave_clk edge catches each ring in essentially uniformly-random phase.

## Sampling, accumulation, and health check — all per-cycle, single buffer

```
Per enclave_clk cycle (1.6 µs, ~600 kHz):
  for i in 0..7:
    sample[i]    = sample_ff(ring[i].clk_out, enclave_clk.posedge)
    popcount[i] += sample[i]                       // 17-bit running counter

  buffer[cycle_idx] = sample[0] ^ sample[1] ^ sample[2] ^ sample[3] ^
                      sample[4] ^ sample[5] ^ sample[6] ^ sample[7]
  cycle_idx        += 1

After 65,536 cycles (~110 ms):
  health_pass = (for all i: popcount[i] ∈ [16384, 49152])

  if health_pass:
    output = BLAKE3(buffer)[0..31]                 // 256 bits
  else:
    abort KOHI permanently — broken silicon → STATE 1 FUCKED
```

**Memory**: one 65,536-bit buffer (8 KB BRAM) + 8 × 17-bit popcount counters (≈17 LUT-FF pairs) + 8 single-bit sampling FFs. Total fabric cost: ~8 KB BRAM + ~150 LUT4s.

**Why combined per-cycle XOR, not 8 parallel buffers**: 5× less RAM, identical entropy quality, identical per-ring fault attribution (the popcount counters track each ring independently regardless of how their samples get combined downstream). If any ring's popcount drifts outside [16384, 49152], we know exactly which ring failed.

Fixed wiring everywhere — no state-machine multiplexing, no combination schedule, no FSM N-stage counter. 8 sampling FFs each reading their own ring on every enclave_clk edge.

## Per-ring health check — quarter-three-quarter bound

Each ring has its own running popcount counter that increments live as samples are taken. After 65,536 cycles, each ring's popcount must fall in `[16384, 49152]` — i.e., between 1/4 and 3/4 of the cycle count. Eight independent checks (one per ring), all must pass.

This is a *device-health* check, not a cryptographic property. It catches:
- Dead ring oscillator (output stuck at 0 or 1) → buffer is all-zeros or all-ones → reject
- Crystal-influenced ring (somehow coupling to a fixed external frequency) → strongly biased pattern → reject
- Catastrophic placement failure (ring degenerated to a constant during PnR) → reject

The bound is intentionally loose. A fair-coin 65,536-bit buffer has expected count 32,768 with standard deviation ~128. The 1/4–3/4 window is wider than ±125σ — it doesn't catch subtle bias, it catches *broken silicon*. Subtle bias is the XOR accumulator's and BLAKE3's job to mop up.

**On health-check failure: provisioning aborts.** No retry, no fallback ring set. A failed ring is broken silicon and the device is unprovisioneable. The chip stays in STATE 0 (VIRGIN) and refuses to operate.

## XOR accumulator

The single buffer IS the conditioned pool — each bit is already the 8-way XOR of all 8 rings' samples at one enclave_clk edge. Eight-way XOR of independent thermal-noise sources averages individual-source bias toward zero:

> Residual bias after XOR of N ~independent sources, each with bias p, scales as `p^N` for small p. With 8 streams at ~5% individual bias: residual ≈ 5%⁸ ≈ 4×10⁻¹¹. Statistically indistinguishable from uniform for any reasonable use.

The input to BLAKE3 is already close to uniformly distributed before the extractor runs.

## BLAKE3 extraction

The final 65,536-bit XOR'd buffer is hashed with BLAKE3 (using the existing `rtl/blake3/blake3.v` core). Output: **256 bits** — the `ira`.

BLAKE3's role here isn't whitening; the XOR already did that. BLAKE3 provides three things the XOR can't:

1. **Cryptographic seal** — one-way from input to output. Even an attacker who could observe the raw XOR'd buffer (impossible in normal operation, but defense-in-depth) cannot reverse-engineer individual ring contributions from the 256-bit output.
2. **Fixed-length output** — 65,536 bits in, 256 bits out, deterministically. The eFuse needs a fixed-width word; BLAKE3 provides one.
3. **Avalanche** — any single-bit difference in the input flips ~50% of output bits. Makes the construction tamper-evident: any silent corruption of the XOR buffer would produce an unrelated `ira`, not a subtly-biased one.

The BLAKE3 core takes ~30 cycles to process the 65,536-bit input (compression chain across 2,048 message blocks of 64 bytes each, parameterized for streaming). At enclave_clk ≈ 30 MHz, that's ~1 ms — negligible against the multi-second KOHI gather time.

## Output: the 256-bit `ira`

Once BLAKE3 completes, `ira[255:0]` is stable in SRAM and the FSM advances to the next phase (`TATARI` — random pre-burn delay; see IRA.md).

The `ira` is the device's *life-essence*. Every cryptographic key the chip uses derives from it via domain-separated BLAKE3:

```
device_id        = BLAKE3("ferros-pipe/device-id"   || ira)
attestation_key  = BLAKE3("ferros-pipe/attestation" || ira)
session_seed     = BLAKE3("ferros-pipe/session"     || ira || nonce)
burn_delay_seed  = BLAKE3("ferros-pipe/burn-delay"  || ira)
```

Storage cost is 256 bits in OTP. Everything else is computed on demand. See IRA.md for why this is the right design (no separate fuses for derived keys).

## Silicon-tapeout mapping

The FPGA implementation uses 8 ring oscillators as the entropy primitive because FPGA fabric offers no other physically-noisy element accessible from RTL. At silicon, the topology stays identical (8 sources sampled by enclave_clk into one XOR'd buffer, per-ring 1/4–3/4 health check via running popcounts, 8-way per-cycle XOR, BLAKE3) but each ring is replaced with a different physics source for true source-independence:

| FPGA ring | Silicon replacement | Physics |
|---|---|---|
| R₀ (3 stages) | Metastability cell | Cross-coupled inverters, deliberate setup violation. Smallest area, cleanest thermal-noise extraction. |
| R₁ (5 stages) | TERO cell #1 | Two inverter chains, enable pulse triggers both, count transitions to stability. Transition-count variance = entropy. |
| R₂ (7 stages) | TERO cell #2 | Second TERO at different chain length for source diversity. |
| R₃ (11 stages) | Free-running ring | The one source that survives the FPGA→ASIC port unchanged. Phase noise from thermal/voltage fluctuations. |
| R₄ (13 stages) | Current-starved subthreshold inverter chain | Narrow PMOS in series. Subthreshold operation pushes thermal noise above deterministic delay. |
| R₅ (17 stages) | Shot-noise diode #1 | Reverse-biased junction, amplified, digitized. Quantum-statistical electron arrival. |
| R₆ (19 stages) | Shot-noise diode #2 | Second shot-noise source from a physically-separated diode for spatial diversity. |
| R₇ (23 stages) | Pink-noise resistor or 1/f flicker source | Long-time-constant noise to complement the high-frequency sources. |

The independence argument is stronger at silicon because each source has *different physics*, not just different stage counts. Quantum (shot noise) vs thermal (everything else) vs flicker (1/f) is a particularly clean three-way separation.

The sampling FFs (clocked by enclave_clk), the per-ring popcount counters, the per-cycle 8-way XOR, and the BLAKE3 extraction are all unchanged. Only the source modules differ at tapeout time.

**SPICE caveat**: ring oscillators on FPGA can validate architecture and post-processing, but they cannot faithfully simulate metastability or subthreshold dynamics. Both physics sources must be validated separately in SPICE with process-corner Monte Carlo before layout commit. NIST SP800-90B health tests run on real silicon outputs.

## What we test on FPGA

| Test | Validates |
|---|---|
| Universal-sampler sim (Icarus, behavioral clock generators) | 8 sampling FFs latch correctly on enclave_clk, per-cycle 8-way XOR populates the single buffer, 8 running popcounts increment correctly, per-ring health check fires correctly, BLAKE3 hand-off triggers exactly once |
| Stub one ring to constant, run KOHI | Health check fires on the stubbed ring's buffer, KOHI aborts cleanly, no garbage propagates to BLAKE3 |
| Flashed bitstream, real entropy gather | OLED shows per-ring fill progress, final `ira`/`wairua` value visible (different each power cycle), no bias obvious to eye |
| Two-instance comparison (same bitstream, two boards) | `ira` values differ between boards (proves per-device uniqueness from ring-placement variation) |

## What only silicon can validate

- Real metastability resolution statistics (vs FPGA FF setup-violation behavior)
- TERO transition-count distributions at process corners
- Subthreshold noise floor over temperature
- Shot-noise spectrum from the reverse-biased junction
- NIST SP800-90B basic and adaptive proportion tests on real silicon outputs
- Long-term entropy quality under thermal cycling and aging
