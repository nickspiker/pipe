#!/usr/bin/env bash
# =============================================================================
# build_pipe.sh — Production PIPE bitstream for Colorlight 5A-75B (ECP5-25F).
# =============================================================================
#
# Hard rules:
#   - NO ecppll. PLL is a governed clock; PIPE has none.
#   - NO crystal pin in pipe.lpf. The board's 25 MHz oscillator is physically
#     present but the FPGA pin sits floating.
#   - The synthesized netlist is checked against netlist_assertions.py BEFORE
#     ecppack runs. Any forbidden clock primitive (EHXPLLL, OSCG, PLLREFCS)
#     fails the build.
#
# This script does NOT cover the measurement bitstream. For Phase B, see
# scripts/build_freq_counter.sh.
#
# Usage:
#   ./build_pipe.sh [--program]
#
# Phase A status: stub only. The synth/PnR commands will not produce a working
# bitstream until the ten production modules in rtl/ have real logic.
#
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
LPF="$ROOT/constraints/pipe.lpf"
ASSERTIONS="$ROOT/constraints/netlist_assertions.py"
BUILD="$ROOT/build"
SEED="${SEED:-1}"

PROGRAM=0
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
    esac
done

mkdir -p "$BUILD"

# -----------------------------------------------------------------------------
# Synthesize — production sources only (rtl/, NOT rtl/measure/)
# -----------------------------------------------------------------------------
echo "================================================================"
echo " PIPE production build — ring oscillator, no crystal, no PLL"
echo "================================================================"
echo ""
echo "--- Synthesize ---"
yosys -p "
    read_verilog $RTL/blake3/blake3.v
    read_verilog $RTL/ring_osc.v
    read_verilog $RTL/trng.v
    read_verilog $RTL/key_register.v
    read_verilog $RTL/boot_fsm.v
    read_verilog $RTL/prng.v
    read_verilog $RTL/ping_pong.v
    read_verilog $RTL/shift_tx.v
    read_verilog $RTL/shift_rx.v
    read_verilog $RTL/cdc.v
    read_verilog $RTL/top.v
    synth_ecp5 -nodsp -top top -json $BUILD/pipe.json
    stat
" 2>&1 | tee "$BUILD/pipe_yosys.log" | grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|EHXPLLL|OSCG|DP16KD)$' || true

if grep -q 'ERROR' "$BUILD/pipe_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/pipe_yosys.log"
    exit 1
fi

# -----------------------------------------------------------------------------
# Netlist assertions (run BEFORE PnR — fail fast if a clock primitive snuck in)
# -----------------------------------------------------------------------------
echo ""
echo "--- Netlist assertions ---"
python3 "$ASSERTIONS" "$BUILD/pipe.json"

# -----------------------------------------------------------------------------
# Place and route
#
# --ignore-loops is REQUIRED because ring_osc.v is a deliberate combinational
# loop. Future versions should scope this to ring_osc only via a constraint;
# applying it globally hides real bugs elsewhere.
# -----------------------------------------------------------------------------
echo ""
echo "--- Place & Route ---"
nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --ignore-loops --timing-allow-fail \
    --json "$BUILD/pipe.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe.config" \
    > "$BUILD/pipe_pnr.log" 2>&1 || true

grep -E '(Max frequency|logic,)' "$BUILD/pipe_pnr.log" || true
if grep -q 'ERROR' "$BUILD/pipe_pnr.log"; then
    echo "PNR ERROR — see $BUILD/pipe_pnr.log"
    exit 1
fi

# -----------------------------------------------------------------------------
# Pack
# -----------------------------------------------------------------------------
echo ""
echo "--- Pack ---"
ecppack --svf "$BUILD/pipe.svf" "$BUILD/pipe.config" "$BUILD/pipe.bit"
echo "Bitstream: $BUILD/pipe.bit ($(stat -c%s "$BUILD/pipe.bit") bytes)"

if [ "$PROGRAM" -eq 1 ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe.svf"
    echo "Done."
else
    echo ""
    echo "Done. To program:"
    echo "  openFPGALoader -c ft232 $BUILD/pipe.svf"
fi
