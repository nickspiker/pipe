#!/usr/bin/env bash
# =============================================================================
# build_pipe_jedec.sh — JEDEC ID readout diagnostic build.
# Verifies whether spi_master.v can actually talk to the GD25Q32 flash chip
# post-configuration. Reuses pipe_meal.lpf (same module port signature).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_meal.lpf"
BUILD="$ROOT/build_pipe_jedec"
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
echo " JEDEC ID readout diagnostic"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
(cd "$BUILD" && yosys -p "
    read_verilog -I $RTL $RTL/spi_master.v
    read_verilog -I $RTL $RTL/ssd1306_i2c.v
    read_verilog -I $RTL $RTL/oled_greyscale_driver.v
    read_verilog -I $RTL $RTL/oled_text_renderer.v
    read_verilog -I $RTL $MEASURE/top_pipe_jedec.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_jedec -json pipe_jedec.json
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
    --json "$BUILD/pipe_jedec.json" \
    --textcfg "$BUILD/pipe_jedec.config" \
    --ignore-loops --timing-allow-fail \
    > "$BUILD/pnr.log" 2>&1

if grep -q 'ERROR' "$BUILD/pnr.log"; then
    echo "PNR ERROR — see $BUILD/pnr.log"; tail -40 "$BUILD/pnr.log"; exit 1
fi
grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/pnr.log" | head -8

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/pipe_jedec.svf" "$BUILD/pipe_jedec.config" "$BUILD/pipe_jedec.bit"
echo "Bitstream: $BUILD/pipe_jedec.bit ($(stat -c%s "$BUILD/pipe_jedec.bit") bytes)"

if [ "$FLASH" -eq 1 ]; then
    openFPGALoader -c ft232 --write-flash "$BUILD/pipe_jedec.bit"
fi

if [ "$PROGRAM" -eq 1 ]; then
    openFPGALoader -c ft232 "$BUILD/pipe_jedec.svf"
fi

echo ""
echo "Done."
