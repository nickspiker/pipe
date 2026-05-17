# OpenLane Sky130 ASIC flow for PIPE

This directory holds the OpenLane configuration that pushes PIPE through the open Sky130 ASIC flow: yosys synthesis → OpenROAD floorplan/place/route → magic/klayout DRC+LVS → GDS layout.

The goal is a **wake-up-call silicon footprint**: real measured area numbers on Sky130 130nm, replacing the back-of-envelope estimates.

## What this delivers (when run)

- Post-synthesis gate count
- Post-place-and-route die area
- Timing closure report at the target enclave_clk frequency
- GDSII layout file
- DRC/LVS sign-off reports

## Status

`pipe_digital/` contains the config + a placeholder top (`rtl/top_pipe_silicon.v`) that intentionally does NOT yet instantiate the production blocks. This is so you can validate the OpenLane install end-to-end before wrestling with the production-integration top.

Next step after install validation: fill in the placeholder body of `top_pipe_silicon.v` with the real instantiations (trng + blake3_tree + chaos_amp_v2 + otp + ira_fsm + boot_fsm + codec + slot_clk + ping_pong + wire_io + prng + key_register).

## Install (OpenLane 2 + Sky130 PDK)

OpenLane 2 is the current actively-maintained version. It's Nix-based and installs cleanly on Linux.

```bash
# 1. Install Nix (one-time, ~5 min)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# 2. Install OpenLane 2 via pipx (recommended)
pipx install openlane

# 3. First run will fetch Sky130 PDK automatically (~10 GB, one-time, ~30 min)
openlane --help
```

Alternative: OpenLane 1 + Docker (older, heavier, but well-documented):

```bash
# Docker required
git clone https://github.com/The-OpenROAD-Project/OpenLane.git ~/OpenLane
cd ~/OpenLane
make pull-openlane                 # ~10 GB docker pull
make pdk PDK=sky130A               # ~5 GB
```

Disk usage: ~15 GB total (PDK + tool images).

## Run the PIPE flow

After install:

```bash
cd /mnt/Octopus/Code/pipe
openlane openlane/pipe_digital/config.json
```

Output appears in `openlane/pipe_digital/runs/<timestamp>/`:
- `final/gds/top_pipe_silicon.gds` — the actual mask layout
- `final/reports/metrics.csv` — area, fmax, utilization
- `final/reports/synthesis/` — gate count breakdown
- `final/reports/floorplan/` — die area, pin placement

## Important caveats

1. **Ring oscillators are NOT in this synthesis.** The 16 entropy rings live in `top_pipe_ira.v` as ECP5-specific LUT4 primitives. On Sky130 silicon, they'd be custom analog cells (inverter chains with `(* keep *)` hints) outside the digital RTL. This config treats `ring_in[15:0]` as external inputs.

2. **OTP storage** in `rtl/otp.v` is currently RAM-based (placeholder for eFuse). Real silicon needs the foundry's actual eFuse macro, which Sky130 has experimentally but isn't drop-in.

3. **SRAM macros**: the trng buffer is 8 KB. OpenLane can either:
   - Synthesize as flip-flop array (heavy: ~65,000 FF, but no macro dependency)
   - Use OpenRAM-generated SRAM macros (smaller, requires macro generation step)

   First-pass synthesis will use flop arrays. To use OpenRAM SRAM, add a macro generation step before the main flow.

4. **Power supplies, bandgap, brown-out detector**: not in this synthesis. Those are top-level wrapper concerns added when going to Caravel.

5. **3-pin SOT-23 vs DFN-3**: this synthesis exposes ~21 pins (clk, reset_n, 16× ring_in, 3× pipe pad signals). The chip-level wrapper bonds the ring_in pins to internal analog and the 3 pipe signals to one bidirectional pad. Net external pin count: 3 (VDD, VSS, pipe). The OpenLane synth itself doesn't care about package — it just reports digital area.

## When you have numbers

Update the chip-area table in `patent/claims.md` and `MEMORY.md` with the actual measured numbers. Compare against the estimate in this session's notes:

| Block | Estimated | Measured |
|---|---|---|
| Digital total | ~0.6 mm² | (TBD) |
| With 8KB SRAM macro | ~0.7 mm² | (TBD) |
| With OTP + analog + pads + power mgmt | ~1.3 mm² | (TBD) |
| Package fit | DFN-3 / SC-70-5 comfortable | (TBD) |

Submit to eFabless Caravel MPW (~$10K) or Tiny Tapeout (~$300, smaller slot) once timing and DRC are clean.
