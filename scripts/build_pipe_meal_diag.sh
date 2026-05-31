#!/usr/bin/env bash
# =============================================================================
# build_pipe_meal_diag.sh — DIAGNOSTIC variant of the meal build.
# Removes chal_resp_fsm + wire_io + blake3 sharing to test whether reducing
# LUT density restores ring health (i.e., is the chal_resp_fsm load causing
# PnR to cluster the ring oscillators in a way that correlates them).
#
# Keeps: otp_persistent + spi_master (so flash persistence is still wired).
# Drops: chal_resp_fsm, wire_io, blake3_tree_shared (use plain blake3_tree).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_meal.lpf"
BUILD="$ROOT/build_pipe_meal_diag"
SEED="${SEED:-4}"

PROGRAM=0
FLASH=0
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
        --flash)   FLASH=1   ;;
    esac
done

mkdir -p "$BUILD"
cp "$ROOT/rtl/glyph_atlas.mem"    "$BUILD/"
cp "$ROOT/rtl/glyph_advance.mem"  "$BUILD/"

echo "================================================================"
echo " DIAG: meal without chal_resp_fsm — test if rings recover"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
(cd "$BUILD" && yosys -p "
    read_verilog -I $RTL $RTL/blake3/blake3.v
    read_verilog -I $RTL $RTL/blake3_tree.v
    read_verilog -I $RTL $RTL/ring_health.v
    read_verilog -I $RTL $RTL/ring_scheduler.v
    read_verilog -I $RTL $RTL/trng.v
    read_verilog -I $RTL $RTL/spi_master.v
    read_verilog -I $RTL $RTL/otp_persistent.v
    read_verilog -I $RTL $RTL/inverted_pair_verify.v
    read_verilog -I $RTL $RTL/ira_fsm.v
    read_verilog -I $RTL $RTL/ssd1306_i2c.v
    read_verilog -I $RTL $RTL/oled_greyscale_driver.v
    read_verilog -I $RTL $RTL/oled_text_renderer.v
    read_verilog -I $RTL $RTL/oled_mode_fsm.v
    read_verilog -I $RTL $RTL/keypad.v
    read_verilog -I $RTL $MEASURE/top_pipe_meal_diag.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_meal_diag -json pipe_meal_diag.json
    stat
") > "$BUILD/yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/yosys.log"; tail -40 "$BUILD/yosys.log"; exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --lpf "$LPF" \
    --json "$BUILD/pipe_meal_diag.json" \
    --textcfg "$BUILD/pipe_meal_diag.config" \
    --ignore-loops --timing-allow-fail \
    > "$BUILD/pnr.log" 2>&1

if grep -q 'ERROR' "$BUILD/pnr.log"; then
    echo "PNR ERROR — see $BUILD/pnr.log"; tail -40 "$BUILD/pnr.log"; exit 1
fi
grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/pnr.log" | head -8

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/pipe_meal_diag.svf" "$BUILD/pipe_meal_diag.config" "$BUILD/pipe_meal_diag.bit"
echo "Bitstream: $BUILD/pipe_meal_diag.bit ($(stat -c%s "$BUILD/pipe_meal_diag.bit") bytes)"

if [ "$FLASH" -eq 1 ]; then
    echo ""
    echo "--- Write flash (non-volatile) ---"
    openFPGALoader -c ft232 --write-flash "$BUILD/pipe_meal_diag.bit"
fi

if [ "$PROGRAM" -eq 1 ]; then
    echo ""
    echo "--- Program SRAM (volatile) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_meal_diag.svf"
fi

echo ""
echo "Done."
