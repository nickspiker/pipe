#!/usr/bin/env bash
# =============================================================================
# build_pipe_ring_scope.sh — 8-ring entropy visualizer
# =============================================================================
# Builds top_pipe_ring_scope.v: eight ring oscillators (stages 3/5/7/11/13/
# 17/19/23) sampled at sysclock. Press the on-board user button (R7) to cycle
# to the next ring and trigger one fresh acquisition; result displayed as a
# greyscale band on the OLED (one OLED page per ring, top page = ring 0).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_ring_scope.lpf"
BUILD="$ROOT/build_pipe_ring_scope"
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

echo "================================================================"
echo " 8-ring entropy scope — button-triggered acquisition"
echo "   rings: 3, 5, 7, 11, 13, 17, 19, 23 stages"
echo "   trigger: Enter key on dozenal keypad (matrix p51+p56, active-low)"
echo "   display: OLED 128×64, 1 page per ring, greyscale via dither"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
yosys -p "
    read_verilog $RTL/ssd1306_i2c.v
    read_verilog $RTL/oled_greyscale_driver.v
    read_verilog $MEASURE/top_pipe_ring_scope.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_ring_scope -json $BUILD/ring_scope.json
    stat
" > "$BUILD/yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/yosys.log"
    tail -30 "$BUILD/yosys.log"
    exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --lpf "$LPF" \
    --json "$BUILD/ring_scope.json" \
    --textcfg "$BUILD/ring_scope.config" \
    --ignore-loops --timing-allow-fail \
    > "$BUILD/pnr.log" 2>&1

if grep -q 'ERROR' "$BUILD/pnr.log"; then
    echo "PNR ERROR — see $BUILD/pnr.log"
    tail -30 "$BUILD/pnr.log"
    exit 1
fi
grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/pnr.log" | head -6

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/ring_scope.svf" "$BUILD/ring_scope.config" "$BUILD/ring_scope.bit"
echo "Bitstream: $BUILD/ring_scope.bit ($(stat -c%s "$BUILD/ring_scope.bit") bytes)"

if [ "$PROGRAM" -eq 1 ]; then
    echo ""
    echo "--- Program SRAM ---"
    openFPGALoader -c ft232 "$BUILD/ring_scope.svf"
fi

if [ "$FLASH" -eq 1 ]; then
    echo ""
    echo "--- Write flash ---"
    openFPGALoader -c ft232 --write-flash "$BUILD/ring_scope.bit"
fi

echo ""
echo "Done."
echo ""
echo "Usage:"
echo "  Press Enter (dozenal keypad matrix p51+p56) to cycle through 9 modes"
echo "  and acquire 8192 raw sample bits across the entire 128×64 OLED:"
echo "    press 1 → ring 1 (5-stage,  ~290 MHz)"
echo "    press 2 → ring 2 (7-stage,  ~210 MHz)"
echo "    press 3 → ring 3 (11-stage, ~135 MHz)"
echo "    press 4 → ring 4 (13-stage, ~115 MHz)"
echo "    press 5 → ring 5 (17-stage,  ~88 MHz)"
echo "    press 6 → ring 6 (19-stage,  ~78 MHz)"
echo "    press 7 → ring 7 (23-stage,  ~65 MHz)"
echo "    press 8 → ring 0 (3-stage,  ~480 MHz)"
echo "    press 9 → XOR of all 8 rings  ← keypad LED (T2) lit solid"
echo "    press 10 → wraps back to ring 1"
echo ""
echo "  Raw bits: 0 → black pixel, 1 → white pixel."
echo "  Healthy uniform random  → speckle, no obvious structure"
echo "  Biased ring             → mostly black or mostly white"
echo "  Locked / patterned ring → visible periodic structure"
echo ""
echo "  Hold Enter:   OLED blanks to all-black (press detection feedback)"
echo "  T6 onboard:   Geiger-style random flicker (rare flashes from ^all_rings)"
echo "  T2 keypad:    solid ON when in 9th (XOR) mode"
