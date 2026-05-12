#!/usr/bin/env bash
# =============================================================================
# build_pipe_oled.sh — OLED bring-up (Phase 1: dithered grey-band test pattern)
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_oled.lpf"
BUILD="$ROOT/build_pipe_oled"
SEED="${SEED:-4}"

PROGRAM=""
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
    esac
done

mkdir -p "$BUILD"

FONT="${FONT:-/mnt/Chiton/MEGA/fonts/Merriweather/static/Merriweather_24pt-Bold.ttf}"
FONT_PX="${FONT_PX:-12}"

echo "================================================================"
echo " pipe OLED bring-up (Phase 2C: 95-char atlas + runtime renderer)"
echo "   font: $FONT  @ ${FONT_PX}px"
echo "================================================================"

echo ""
echo "--- Bake glyph atlas ---"
( cd "$ROOT" && cargo run -p oled-bake --release --quiet --bin oled-bake-atlas -- \
    "$FONT" "$FONT_PX" "$BUILD" --pow2 )

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $RTL/ssd1306_i2c.v
    read_verilog $MEASURE/top_pipe_oled.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_oled -json $BUILD/pipe_oled.json
    stat
" > "$BUILD/yosys.log" 2>&1
cd - > /dev/null

if grep -q 'ERROR' "$BUILD/yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/yosys.log"
    tail -30 "$BUILD/yosys.log"
    exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --ignore-loops --timing-allow-fail \
    --json "$BUILD/pipe_oled.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_oled.config" \
    > "$BUILD/pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s"
    exit 1
fi

grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/pnr.log" | head -6

if [ "$PNR_RC" -ne 0 ]; then
    echo "PNR exited rc=$PNR_RC — see $BUILD/pnr.log"
    exit 1
fi

echo ""
echo "--- Pack ---"
ecppack --svf "$BUILD/pipe_oled.svf" "$BUILD/pipe_oled.config" "$BUILD/pipe_oled.bit"
echo "Bitstream: $BUILD/pipe_oled.bit ($(stat -c%s "$BUILD/pipe_oled.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_oled.svf"
fi

echo "Done."
