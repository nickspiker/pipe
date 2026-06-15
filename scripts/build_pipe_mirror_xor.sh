#!/usr/bin/env bash
# =============================================================================
# build_pipe_mirror_xor.sh — full Claim 12 mirror-XOR line code (FPGA side)
# =============================================================================
#
# Builds top_pipe_mirror_xor.v: FPGA implements the full Claim 12 encoding rule
#   wire_value = OWN_IDLE XOR own_data XOR other_last_decoded_data
# instead of the slot-timing-only stub in top_pipe_slotted_oled.v. FPGA decodes
# bridge bits at mid-host-slot, encodes its own TX bit per Claim 12 during the
# enclave slot, and rotates thru TX_PATTERN (default 32'hAAAAAAAA).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_mirror_xor.lpf"
BUILD="$ROOT/build_pipe_mirror_xor"
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
echo " pipe mirror-XOR (Claim 12 full encoding) + OLED freq"
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
    read_verilog $RTL/freq_counter.v
    read_verilog $RTL/bin_to_bcd.v
    read_verilog $RTL/wire_io.v
    read_verilog $MEASURE/top_pipe_mirror_xor.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_mirror_xor -json $BUILD/pipe_mirror_xor.json
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
    --json "$BUILD/pipe_mirror_xor.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_mirror_xor.config" \
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
ecppack --svf "$BUILD/pipe_mirror_xor.svf" "$BUILD/pipe_mirror_xor.config" "$BUILD/pipe_mirror_xor.bit"
echo "Bitstream: $BUILD/pipe_mirror_xor.bit ($(stat -c%s "$BUILD/pipe_mirror_xor.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_mirror_xor.svf"
fi

echo "Done."
