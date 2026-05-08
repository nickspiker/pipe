# Measurement-only RTL

This directory holds bringup tools used during Phase B (ring-oscillator
characterization) and Phase C (BLAKE3 silicon Fmax measurement).

**These files are NEVER synthesized into a production PIPE bitstream.**
They use the 25 MHz crystal as a measurement reference, which is the entire
reason they exist — the production design has no governed clock at all.

`scripts/build_pipe.sh` only reads `rtl/*.v` (excluding `rtl/measure/`).
`scripts/build_freq_counter.sh` is the only consumer of this directory.

## Files

- `top_extclk.v` — frequency counter top with internal ring oscillator. Stage 0 is a NOT (LUT4 INIT=h5555); stages 1..N-1 are BUFs (INIT=hAAAA). One inversion per loop, so any N ≥ 1 oscillates. Each additional buffer adds ~340 ps of LUT delay on ECP5 fabric. RING_STAGES set via build script `--ring=N`.
- `ssd1306_i2c.v` — I2C bit-bang driver for the OLED display.

See `pipe/README.md` for the phase plan and `pipe/phase_b_results.csv` for measured frequencies.
