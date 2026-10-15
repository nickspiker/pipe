# Keypad — Dozenal 18-key topology

PIPE's debugging input device. Vendored physical layout from the dozenal calculator hardware (`/mnt/Harbor/Code/fpga/`). Measured 2026-05-13 by pin-ID-scanner bitstream at 8× speed.

## Physical wiring

Eleven GPIO pins on the Colorlight 5A-75B v8.0, all with `PULLMODE=UP`. The layout is **a 4-row × 4-col matrix for rows 0–3, plus 3 ad-hoc 2-pin keys for row 4 cols 0–2.**

### Pin → FPGA site

| Pin | FPGA site | Role |
|---|---|---|
| p27 | H14 | matrix row 0 |
| p28 | H15 | matrix row 1 |
| p44 | N14 | matrix row 2 |
| p51 | P14 | matrix row 3 |
| p49 | P12 | matrix col 0 |
| p63 | T14 | matrix col 1 |
| p62 | T13 | matrix col 2 |
| p56 | R13 | matrix col 3 |
| p50 | P13 | ad-hoc (Negate) |
| p57 | R14 | ad-hoc (Decimal) |
| p58 | R15 | ad-hoc (Divide) |

### Per-key pin pairs

```
┌──────────────┬──────────────┬──────────────┬──────────────┐
│   Stelor B   │   Stela  A   │   Stel   9   │   Multiply   │
│   27 + 49    │   27 + 63    │   27 + 62    │  62 + GND    │  row 0
├──────────────┼──────────────┼──────────────┼──────────────┤
│   Lunor  8   │   Luna   7   │   Lun    6   │              │
│   28 + 49    │   28 + 63    │   28 + 62    │              │  row 1
├──────────────┼──────────────┼──────────────┤   Add  +     │
│   Teror  5   │   Tera   4   │   Ter    3   │   28 + 56    │
│   44 + 49    │   44 + 63    │   44 + 62    │              │  row 2
├──────────────┼──────────────┼──────────────┼──────────────┤
│   Zilor  2   │   Zila   1   │   Zil    0   │              │
│   49 + 51    │   51 + 63    │   51 + 62    │              │  row 3
├──────────────┼──────────────┼──────────────┤   Enter  ▲   │
│  Divide  ÷   │  Decimal ·   │  Negate  Ƨ   │   51 + 56    │
│   58 + 63    │   44 + 57    │   50 + 62    │              │  row 4
└──────────────┴──────────────┴──────────────┴──────────────┘
```

### Special case: Multiply wired to GND

The Multiply key (row 0, col 3) is the **only key wired between a GPIO pin and hardwired GND** on the PCB. Pin 62 is one terminal; the other is a literal ground tab.

This means:
- Pin 62 itself is **NOT** permanently grounded — it floats with pull-up when no key is pressed, and is shorted to ground *only when Multiply is held*
- When Multiply is held, pin 62 reads LOW regardless of which row pin the scanner is driving
- This produces a detectable signature: "pin 62 column dark in **all** rows of the matrix scan" → Multiply

All other 17 keys are standard two-GPIO switches.

## Inferred topology

### Matrix region (rows 0–3, all 4 cols) — 16 cells, 14 keys

A clean **4×4 active-low matrix**. Row pin LOW + col pin LOW = key at (row, col) pressed. Scan by driving each row LOW in turn, sensing all 4 col pins for the active column.

| | col 0 (p49) | col 1 (p63) | col 2 (p62) | col 3 (p56) |
|---|---|---|---|---|
| **row 0 (p27)** | Stelor | Stela | Stel | Multiply |
| **row 1 (p28)** | Lunor | Luna | Lun | Add (rowspan 1-2) |
| **row 2 (p44)** | Teror | Tera | Ter | — (Add continues visually) |
| **row 3 (p51)** | Zilor | Zila | Zil | Enter (rowspan 3-4) |

The visual rowspan-2 cells (Add, Enter) are physically **one switch each**, wired to one matrix intersection. The "continued" cell in the row below is empty in the scan matrix.

### Ad-hoc region (row 4 cols 0–2) — 3 keys, 3 dedicated pin pairs

Three keys each have their own unique pin pair that doesn't follow the matrix pattern:

| Key | Pin pair | Notes |
|---|---|---|
| Divide ÷ | p58 + p63 | p58 is ad-hoc; p63 shared with matrix col 1 |
| Decimal · | p44 + p57 | p44 shared with matrix row 2; p57 is ad-hoc |
| Negate Ƨ | p50 + p62 | p50 is ad-hoc; p62 shared with matrix col 2 |

These three keys cannot be scanned by the matrix logic alone — they need their own decoder paths.

## Scanner design (for `pipe/rtl/keypad.v`)

A three-phase scanner:

```
PHASE 0 — Multiply detect (all-tristate):
  Tristate all 11 pins. Read pin 62.
  If LOW → Multiply pressed (its other terminal is GND, so
           the key shorts pin 62 to ground even with no driver).

PHASE A — matrix scan (rows 0-3):
  For r in {27, 28, 44, 51}:
    Drive p[r] LOW, tristate all other 10 pins.
    Read (p49, p63, p62, p56).
    Any col reading LOW = key pressed at (r, col).

PHASE B — ad-hoc scan (row 4):
  Test sequence for each of {Divide, Decimal, Negate}:
    Drive p[ad-hoc-pin] LOW, tristate everything else.
    Read the corresponding shared pin.
    If LOW = that ad-hoc key pressed.

  Specifically:
    Drive p58 LOW, read p63: Divide
    Drive p57 LOW, read p44: Decimal
    Drive p50 LOW, read p62: Negate

Total phase cycle: 1 (multiply) + 4 (matrix rows) + 3 (ad-hoc keys) = 8 phases per full scan.
```

**Order matters**: Phase 0 must run before Phase A. During Phase A, driving any matrix row LOW would also pull pin 62 LOW *thru* the Multiply key if it's held — producing false matches on the col-2 keys (Stel/Lun/Ter/Zil). With Phase 0 first, we know whether Multiply is held *before* doing matrix scans and can mask its false-positive signature out.

Implementation: latch `multiply_held` from Phase 0. During Phase A's col-2 reads, ignore "pressed" signal if `multiply_held` is set (or report both Multiply *and* the col-2 key if you want to support that combination).

At 25 MHz clock with one-phase-per-cycle and minimal settle time, full scan ≈ 280 ns. Even with 1 ms per phase for human-scale debouncing, full scan ≈ 7 ms — well under any human keypress duration.

## o_key encoding for pipe

Flatten the 18 keys into a 5-bit `o_key[4:0]` index:

| o_key | Key | Pin pair | Region |
|---|---|---|---|
| 0 | Stelor (B) | 27 + 49 | matrix |
| 1 | Stela (A) | 27 + 63 | matrix |
| 2 | Stel (9) | 27 + 62 | matrix |
| 3 | Multiply | 62 + GND (single-ended) | special |
| 4 | Lunor (8) | 28 + 49 | matrix |
| 5 | Luna (7) | 28 + 63 | matrix |
| 6 | Lun (6) | 28 + 62 | matrix |
| 7 | Add | 28 + 56 | matrix |
| 8 | Teror (5) | 44 + 49 | matrix |
| 9 | Tera (4) | 44 + 63 | matrix |
| 10 | Ter (3) | 44 + 62 | matrix |
| 11 | (unused — Add visually here) | — | — |
| 12 | Zilor (2) | 49 + 51 | matrix |
| 13 | Zila (1) | 51 + 63 | matrix |
| 14 | Zil (0) | 51 + 62 | matrix |
| 15 | Enter ▲ | 51 + 56 | matrix |
| 16 | Divide ÷ | 58 + 63 | ad-hoc |
| 17 | Decimal · | 44 + 57 | ad-hoc |
| 18 | Negate Ƨ | 50 + 62 | ad-hoc |
| 19 | (unused — Enter visually here) | — | — |

Codes 11 and 19 are never emitted; they correspond to the visual continuation of the rowspan-2 keys. The decoder maps both Add positions to o_key=7 and both Enter positions to o_key=15.

## Shift modifier handling

Per the HTML calculator layout, **Decimal (o_key=17)** is the shift modifier — its alt-function label is "Shift ▽". Two ways to handle this in the FSM:

1. **Chord (hold-and-press)**: hold Decimal while pressing another key → that key's alt-function fires. Standard mechanical-keyboard behavior, requires the scanner to detect two simultaneous presses. The matrix scanner naturally supports this since each key is at a unique row/col intersection.

2. **Sticky toggle (one-shot modifier)**: press Decimal, release, then press the next key → that key's alt fires, then shift mode auto-clears. Easier on the user's fingers but requires FSM state.

Recommend chord on a 4×4 matrix because the scanner can detect both presses concurrently with no extra state.

## IRA-function mapping (proposed)

Number keys 0–8 → 9 OLED display modes. Math ops → IRA control actions. See conversation `2026-05-13` for full proposal; capturing in the IRA FSM Verilog when we get there.

| o_key | Key | IRA function (base) | IRA function (shift) |
|---|---|---|---|
| 0 | Stelor | reserved | Sine alt — reserved |
| 1 | Stela | reserved | Cosine alt — reserved |
| 2 | Stel | reserved | Tangent alt — reserved |
| 3 | Multiply | KOHI-↻ (full ceremony restart) | Power alt — manual fast-forward |
| 4 | Lunor | OLED mode 8: TIMING | Arcsine alt — reserved |
| 5 | Luna | OLED mode 7: HISTORY | Arccosine alt — reserved |
| 6 | Lun | OLED mode 6: IRA-DETAIL | Arctangent alt — reserved |
| 7 | Add | KOHI GO (start gather) | Subtract — step backward |
| 8 | Teror | OLED mode 5: SLOT-MAP | ln alt — reserved |
| 9 | Tera | OLED mode 4: COMBO-GRID | Gamma alt — reserved |
| 10 | Ter | OLED mode 3: RING-DETAIL | Swap alt — reserved |
| 12 | Zilor | OLED mode 2: HEATMAP-FROZEN | π alt — reserved |
| 13 | Zila | OLED mode 1: HEATMAP-LIVE | e alt — reserved |
| 14 | Zil | OLED mode 0: STATUS (default) | Random — trigger entropy reseed |
| 15 | Enter | STEP advance (one state forward) | Clear — exit STEP, return to AUTO |
| 16 | Divide | ABORT (cancel current operation) | Modulo alt — pause without abort |
| 17 | Decimal | SHIFT modifier (chord) | (self) |
| 18 | Negate | RESET display | Clear Entry — wipe transient state |

## What this replaces

The `spirix_keypad.v` module at `/mnt/Harbor/Code/fpga/rtl/spirix_keypad.v` was designed for a clean 4-col × 5-row matrix. **It does not match this hardware** — there is no 5th row pin; row 4 keys are wired ad-hoc to 3 separate pin pairs. PIPE's `keypad.v` will be a new module with the hybrid matrix+ad-hoc scanner described above.
