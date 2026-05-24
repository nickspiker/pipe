#!/usr/bin/env bash
# =============================================================================
# build_pipe_toggle.sh — straight square-wave on pipe_pad (no codec, no XOR)
# =============================================================================
#
# Smoke test bitstream: drives a clean toggle at ~37 kHz so the bridge sees
# actual transitions instead of the codec's idle-1010 pattern. Validates the
# bridge's rising/falling edge tracker against a known-rate ground truth before
# we wire real codec data emission.
#
# Same RING_STAGES / RING_DIV defines as build_pipe_codec.sh so timing scales
# the same way. SLOT_DIV is not used (no slot clock in this build).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_test.lpf"
BUILD="$ROOT/build_pipe_toggle"
SEED="${SEED:-4}"

RING="${RING:-5}"
RING_DIV="${RING_DIV:-512}"

PROGRAM=""
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
    esac
done

mkdir -p "$BUILD"
DEFINES="-DRING_STAGES=$RING -DRING_DIV=$RING_DIV"

echo "================================================================"
echo " pipe toggle (raw square wave on pipe_pad)"
echo "   ring stages: $RING ; ring divisor: $RING_DIV"
echo "   enclave_clk ≈ 600 kHz / (RING_DIV/512) ; toggle = enclave_clk / 16"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $DEFINES $MEASURE/top_pipe_toggle.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_toggle -json $BUILD/pipe_toggle.json
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
PNR_TIMEOUT="${PNR_TIMEOUT:-180}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --ignore-loops --timing-allow-fail \
    --json "$BUILD/pipe_toggle.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_toggle.config" \
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
ecppack --svf "$BUILD/pipe_toggle.svf" "$BUILD/pipe_toggle.config" "$BUILD/pipe_toggle.bit"
echo "Bitstream: $BUILD/pipe_toggle.bit ($(stat -c%s "$BUILD/pipe_toggle.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_toggle.svf"
fi

echo "Done."
