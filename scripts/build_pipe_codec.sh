#!/usr/bin/env bash
# =============================================================================
# build_pipe_codec.sh — real PIPE protocol on the wire (enclave side)
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_test.lpf"
BUILD="$ROOT/build_pipe_codec"
SEED="${SEED:-4}"

RING="${RING:-5}"
RING_DIV="${RING_DIV:-512}"
SLOT_DIV="${SLOT_DIV:-12}"

PROGRAM=""
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
    esac
done

mkdir -p "$BUILD"
DEFINES="-DRING_STAGES=$RING -DRING_DIV=$RING_DIV -DSLOT_DIV=$SLOT_DIV"

echo "================================================================"
echo " pipe codec (full PIPE protocol on wire)"
echo "   ring stages: $RING ; ring divisor: $RING_DIV"
echo "   slot divisor: $SLOT_DIV  (slot rate ≈ 600 kHz / $SLOT_DIV)"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $RTL/codec.v
    read_verilog $RTL/slot_clk.v
    read_verilog $RTL/wire_io.v
    read_verilog $DEFINES $MEASURE/top_pipe_codec.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_codec -json $BUILD/pipe_codec.json
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
    --json "$BUILD/pipe_codec.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_codec.config" \
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
ecppack --svf "$BUILD/pipe_codec.svf" "$BUILD/pipe_codec.config" "$BUILD/pipe_codec.bit"
echo "Bitstream: $BUILD/pipe_codec.bit ($(stat -c%s "$BUILD/pipe_codec.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_codec.svf"
fi

echo "Done."
