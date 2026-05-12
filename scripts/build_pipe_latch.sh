#!/usr/bin/env bash
# =============================================================================
# build_pipe_latch.sh — host ↔ enclave bidir smoke (1-bit wire latch)
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_test.lpf"
BUILD="$ROOT/build_pipe_latch"
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
echo " pipe wire latch (host↔enclave bidir test)"
echo "   ring stages: $RING"
echo "   ring divisor: $RING_DIV (enclave_clk ≈ 600 kHz)"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $RTL/wire_io.v
    read_verilog $DEFINES $MEASURE/top_pipe_latch.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_latch -json $BUILD/pipe_latch.json
    stat
" > "$BUILD/pipe_latch_yosys.log" 2>&1
cd - > /dev/null

if grep -q 'ERROR' "$BUILD/pipe_latch_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/pipe_latch_yosys.log"
    tail -30 "$BUILD/pipe_latch_yosys.log"
    exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/pipe_latch_yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --ignore-loops --timing-allow-fail \
    --json "$BUILD/pipe_latch.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_latch.config" \
    > "$BUILD/pipe_latch_pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s"
    exit 1
fi

grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" \
    "$BUILD/pipe_latch_pnr.log" | head -6

if [ "$PNR_RC" -ne 0 ]; then
    echo "PNR exited rc=$PNR_RC — see $BUILD/pipe_latch_pnr.log"
    exit 1
fi

echo ""
echo "--- Pack ---"
ecppack --svf "$BUILD/pipe_latch.svf" "$BUILD/pipe_latch.config" "$BUILD/pipe_latch.bit"
echo "Bitstream: $BUILD/pipe_latch.bit ($(stat -c%s "$BUILD/pipe_latch.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_latch.svf"
fi

echo "Done."
