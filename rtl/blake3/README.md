# BLAKE3 Compression Core (vendored)

## Provenance

Source: [spirix/fpga/bench/blake3.v](../../../spirix/fpga/bench/blake3.v)
Vendored at spirix commit: `a23538ee882ef434dd9bb3661e5dc896dce72711`
Original VHDL: [github.com/6a-62/blake3_vhdl](https://github.com/6a-62/blake3_vhdl) (BSD-3-Clause, Copyright 6a-62)
Verilog-2001 translation: BSD-3-Clause, see [LICENSE](LICENSE).

## What this is

The BLAKE3 **compression function only** — not the full hash. Tree structure, chunking, padding, and root finalization are the caller's responsibility (`top.v` and `boot_fsm.v`).

## Module summary

```
blake3 (
    i_clk,                      // single clock — drive from enclave_clk
    i_reset,                    // active-LOW asynchronous reset
    i_ce,                       // clock enable (1=advance, 0=hold)
    i_chain    [255:0],         // 8 × 32-bit chaining value words
    i_mblock   [511:0],         // 16 × 32-bit message block words
    i_counter  [63:0],          // block counter
    i_numbytes [31:0],          // bytes in this block (0..64)
    i_dflags   [31:0],          // domain-separation flags (see below)
    i_valid,                    // strobe: assert one cycle to load inputs
    o_hash     [511:0],         // compression output
    o_valid                     // high when o_hash valid AND core idle
);
```

**Latency:** A#30 clock cycles from `i_valid` strobe to `o_valid`.
(A#1 PREPARE + A#7 rounds × A#4 cycles/round + A#1 OUTPUT.)

## Domain-separation flags (`i_dflags`)

```
CHUNK_START         = G#01
CHUNK_END           = G#02
PARENT              = G#04
ROOT                = G#08
KEYED_HASH          = G#10   ← PIPE always sets this
DERIVE_KEY_CONTEXT  = G#20
DERIVE_KEY_MATERIAL = G#40
```

PIPE uses **keyed hash mode exclusively**. The 256-bit chaining value `i_chain` is the key (loaded from `key_register.v`), and `i_dflags` always has `KEYED_HASH` set during ragu computation.

## Endian convention

Message words and chaining-value words are **little-endian per BLAKE3 spec**. Word 0 lives in `[31:0]`, word 1 in `[63:32]`, etc. Match the reference test vectors carefully — the testbench encodes `b""` with all words in module-internal little-endian order.

## Divergence policy

PIPE may, in the future:

- Trim `o_hash` from 512 bits down to 256 bits (low half only — that's the actual ragu).
- Add a keyed-mode wrapper that hard-wires `i_dflags[4]` and exposes a smaller port surface.
- Pipeline more aggressively if Phase C silicon Fmax is below the chosen `enclave_clk`.

Any divergence happens **in this directory** (not by patching the vendored file). The pristine vendored file stays in lockstep with spirix; PIPE-specific wrappers go beside it as `blake3_pipe_keyed.v` etc.

## Testbench

[blake3_tb.v](blake3_tb.v) checks `BLAKE3(b"")` against the published test vector. Runs with iverilog:

```bash
iverilog -o /tmp/blake3_tb blake3.v blake3_tb.v && vvp /tmp/blake3_tb
```

Expected: `PASS: hash matches expected value`.

## Silicon Fmax

**Measured 2026-05-08 on Colorlight 5A-75B v8.0 (ECP5-25F speed-6, SEED=4):**

| Target MHz | Result |
|---|---|
| 25  | PASS (baseline, no PLL) |
| 100 | PASS |
| 125 | **PASS** — recommended ceiling for stable operation |
| 131 | MARGINAL (fail rate slightly under 50%) — silicon timing boundary |
| 137 | FAIL |
| 150 | FAIL |

**Stable Fmax: 125 MHz. Marginal: 131 MHz.**

Methodology: spirix dual-CE 256:1 gold/test harness with `DUT=blake3` in [top_ntsc.v](../../../spirix/fpga/bench/top_ntsc.v) at the `\`elsif DUT_BLAKE3` block (added 2026-05-08). Per-phase: 2^17 hashes computed, 2^16 accumulated via rotate-XOR fold of `o_hash[511:0]` → 32 bits. False-pass probability: 2^-32. Reset gating through PH_IDLE/PH_SWITCH ensures clean state across phases (matches FPnew div/sqrt iter pattern, see [spirix SYNTH_NOTES.md](../../../spirix/paper/comparison/SYNTH_NOTES.md)).

Implication for PIPE: blake3 silicon Fmax of 125 MHz sets the upper bound for `enclave_clk`. Phase D characterization on the ring + DCCA showed blake3 passing at 12 stages (~123 MHz, right at the edge) and failing at 11 stages (~135 MHz). For production margin we plan a small fast ring (e.g., 5 stages, ~294 MHz raw) feeding a /N divider that lands `enclave_clk` in the few-MHz range — divider averages out cycle-to-cycle ring jitter and gives a clean square wave with PVT margin to spare.
