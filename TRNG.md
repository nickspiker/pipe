# TRNG — Entropy Source

PIPE's entropy source. Sixteen ring oscillators with mutually-prime stage counts (the first 16 odd primes), sampled by `enclave_clk` (a slower 17th ring divided down to ~600 kHz). Per enclave_clk cycle: all 16 rings sampled in parallel, 16-way XOR into a single 65,536-bit buffer, 16 running popcount counters AND 16 running toggle counters for per-ring health attribution. BLAKE3 extraction at end. Output is a 256-bit value (`ira` for permanent provisioning, `wairua` for session keys) — see [IRA.md](IRA.md) for what gets done with the output.

This is the `KOHI` ("gather") phase of the provisioning ceremony. The downstream phases (`TATARI`, `TAHU`) are documented in [IRA.md](IRA.md).

## Sixteen rings, prime stages

Sixteen `ring_osc` instances with stage counts **3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59** — the first 16 odd primes (we skip 2 because at 2 stages the ring period drops below ECP5 fabric distortion limits). All mutually incommensurate. Frequency spread ~25× from fastest to slowest:

| Ring | Stages | Expected frequency on ECP5 speed-6 (measured 3-stage = 512 MHz) |
|---|---|---|
| R₀  | 3  | ~480 MHz (measured 512 MHz) |
| R₁  | 5  | ~290 MHz |
| R₂  | 7  | ~210 MHz |
| R₃  | 11 | ~135 MHz |
| R₄  | 13 | ~115 MHz |
| R₅  | 17 | ~88 MHz  |
| R₆  | 19 | ~78 MHz  |
| R₇  | 23 | ~65 MHz  |
| R₈  | 29 | ~52 MHz  |
| R₉  | 31 | ~48 MHz  |
| R₁₀ | 37 | ~40 MHz  |
| R₁₁ | 41 | ~36 MHz  |
| R₁₂ | 43 | ~35 MHz  |
| R₁₃ | 47 | ~32 MHz  |
| R₁₄ | 53 | ~28 MHz  |
| R₁₅ | 59 | ~25 MHz  |

16 is a power of 2, which makes the XOR tree fit cleanly. R₁₅ at ~25 MHz is still ~42× faster than enclave_clk's 600 kHz — the slow-samples-fast regime holds for every ring with comfortable margin.

These are nominal — actual placement varies ±10% across seeds due to fabric routing. Each ring is its own `ring_osc.v` instance with the same `(* keep *)` + `(* noglobal *)` attributes that prevent yosys from optimizing the loop away.

**Parity is not a constraint.** The canonical "N inverters in a loop must have N odd" rule does not apply because [ring_osc.v](rtl/ring_osc.v) uses a single inverter plus (N−1) buffers — only one inversion per loop, so any N ≥ 1 oscillates. Even-stage rings would work just as well; we picked these stage counts for *frequency incommensurability*, not parity.

**Why prime**: any two rings of stage counts `m` and `n` produce frequencies in ratio approximately `n/m`. If both are prime, that ratio is irreducible — no integer multiple of one frequency aligns with the other. Result: phase between any two rings drifts continuously, no harmonic lock can form, the metastability sampler always sees the sampled signal in an unpredictable phase relative to the sampler clock. (If we used 6 and 12 stages, for instance, their 1:2 frequency ratio would invite phase-lock; primes avoid this entirely.)

Other valid choices in the same family: **2, 3, 5, 7, 11, 13, 17, 19, 23** are all prime. We could substitute any of these. The 3-thru-13 set was picked for a moderate frequency spread (4.3×) that keeps even the slowest ring well above the 1/(BLAKE3 latency) floor while keeping the fastest ring below ECP5 fabric distortion limits.

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

The fix: **always sample slow-clock-on-fast-signal**. Use `enclave_clk` (~600 kHz, derived from a 17th ring oscillator divided by SLOT_DIV) as the sole sampling clock for all 16 entropy rings. Between two enclave_clk edges (~1.6 µs apart), each entropy ring traverses 40–800 of its own cycles — far more than a single transition's worth — so its phase walks randomly under thermal noise. Each enclave_clk edge catches each ring in essentially uniformly-random phase.

## Sampling, accumulation, and health check — all per-cycle, single buffer

```
Per enclave_clk cycle (1.6 µs, ~600 kHz):
  for i in 0..15:
    sample[i]    = sample_ff(ring[i].clk_out, enclave_clk.posedge)
    popcount[i] += sample[i]                       // 17-bit running counter
    toggles[i]  += (sample[i] != prev_sample[i])   // 17-bit running counter
  prev_sample = sample

  buffer[cycle_idx] = sample[0] ^ sample[1] ^ … ^ sample[15]   // 16-way XOR
  cycle_idx        += 1

After 65,536 cycles (~110 ms):
  for i in 0..15:
    ring_pass[i] = (popcount[i] ∈ [8192, 57344])   // 1/8 to 7/8 — popcount band
                 ∧ (toggles[i]  ≥ 256)             // N/256 — toggle floor
  healthy_count = Σ ring_pass[i]

  if healthy_count ≥ 8:
    output = BLAKE3(buffer)[0..31]                 // 256 bits
  else:
    abort KOHI permanently — broken silicon → STATE 1 NGARO, silent wire
```

**Memory**: one 65,536-bit buffer (8 KB BRAM) + 16 × 17-bit popcount counters + 16 × 17-bit toggle counters + 16 single-bit sampling FFs + 16 single-bit prev-sample FFs. Total fabric cost: ~8 KB BRAM + ~600 LUT-FF pairs.

**Why combined per-cycle XOR, not 16 parallel buffers**: 16× less RAM, identical entropy quality, identical per-ring fault attribution (the popcount and toggle counters track each ring independently regardless of how their samples get combined downstream). If any ring fails either check, we know exactly which ring failed.

Fixed wiring everywhere — no state-machine multiplexing, no combination schedule, no FSM N-stage counter. 16 sampling FFs each reading their own ring on every enclave_clk edge.

## Per-ring dual health check — popcount AND toggle

Each ring has TWO running counters that increment live as samples are taken:

1. **Popcount counter** — increments by 1 each cycle the ring's sample is 1. After 65,536 cycles, must fall in `[8192, 57344]` (1/8 to 7/8 of the cycle count, ±75% bias tolerated).
2. **Toggle counter** — increments by 1 each cycle the ring's sample differs from its prior-cycle sample (edge detect). After 65,536 cycles, must be `≥ 256` (= N/256, at least 1/256 of expected N/2 toggles for true random).

A ring is healthy iff BOTH checks pass. The popcount band is wider than earlier drafts' 1/4-3/4 because rings have real PVT bias that BLAKE3 + 16-way XOR easily absorb. The toggle floor is the cryptographically meaningful test — it catches patterns that the popcount alone misses:

**Why toggle counter matters.** Popcount alone passes "stuck-then-stuck" patterns. Consider a ring whose center frequency lands near an exact integer multiple of `enclave_clk`. With a frequency offset `Δf = 10 Hz` from the nearest subharmonic of a 1 MHz sampler, the output bit changes once every `f_sample / (2Δf) = 50,000` samples — over a 65,536-sample gather, that's **about 1 toggle total**, but popcount is ≈ 32,768 (perfect 50%). Popcount sees a "perfect ring", toggle sees "completely stuck".

The math: under deterministic stable-frequency analysis with uniformly-distributed frequency offset Δf, toggle count over N samples is **uniformly** distributed in [0, N] — NOT Gaussian like popcount. So the per-ring toggle-fail probability for a threshold of TOG_MIN/N is exactly TOG_MIN/N. At N/256, that's 0.39% per ring.

Real silicon has thermal jitter that knocks rings off resonance constantly, so the deterministic worst case overstates the failure rate by orders of magnitude. But the worst case is what the patent claim has to defend against, and N/256 with 8-of-16 byzantine gives a per-chip failure probability of ~10⁻¹⁵ per KOHI — satellite-fleet-safe over centuries.

## Byzantine-tolerant ring threshold (8 of 16)

Earlier drafts required ALL rings to pass health checks. With 16 rings, this would multiply the per-ring failure rate by 16× into the per-chip rate — unacceptable for a fleet at scale even if individual rings are very reliable.

Instead: require ≥8 of 16 rings to pass. Tolerate up to 8 ring failures. Per-chip failure (≤7 healthy) requires ≥9 of 16 to fail simultaneously:

```
P(≥9 fail of 16) ≈ C(16, 9) · p⁹ = 11,440 · p⁹  for small p
```

For our target `P_chip < 10⁻¹⁵ per KOHI` (fleet-safe over 10¹² KOHIs/year × 100 years), we need per-ring failure rate `p < 7.9 × 10⁻³`. Our actual `p ≈ 0.39%` (toggle) sits comfortably under that ceiling with ~2× margin.

**Why XOR'd output stays good with partial-ring health**: XOR of N independent sources is uniform if and only if at least one input is uniform. So even one healthy ring is theoretically sufficient for cryptographic uniformity; the ≥8 threshold is defense-in-depth, not strict necessity. Output ira_seed quality is unaffected by which subset of rings happen to pass.

**On health-check failure: provisioning silently fails.** No retry, no fallback. The chip latches NGARO, ceases driving its wire forever (host sees indistinguishable-from-absent), and the only paths out are physical destruction or replacement. See [IRA.md §NGARO-silent](IRA.md#ngaro-state--silent-wire) for the wire-level behavior.

## XOR accumulator

The single buffer IS the conditioned pool — each bit is already the 16-way XOR of all 16 rings' samples at one enclave_clk edge. Sixteen-way XOR of independent thermal-noise sources averages individual-source bias toward zero:

> Residual bias after XOR of N ~independent sources, each with bias p, scales as `p^N` for small p. With 16 streams at ~5% individual bias: residual ≈ 5%¹⁶ ≈ 1.5×10⁻²¹. Statistically indistinguishable from uniform for any reasonable use; cosmically indistinguishable from uniform for any *unreasonable* use.

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

The FPGA implementation uses 16 ring oscillators as the entropy primitive because FPGA fabric offers no other physically-noisy element accessible from RTL. At silicon, the topology stays identical (16 sources sampled by enclave_clk into one XOR'd buffer, per-ring popcount + toggle dual health check, 16-way per-cycle XOR, BLAKE3) but each ring is replaced with a different physics source for true source-independence:

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
