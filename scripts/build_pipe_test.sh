#!/usr/bin/env bash
# =============================================================================
# build_pipe_test.sh — TX-only PIPE wire smoke test on ECP5-25F
# =============================================================================
#
# FPGA drives pipe_pad (L15, bridged to L16, → 400Ω → board D7) with a 1010
# pattern at slot_rate / 2. Ring oscillator + mod-N divider as in the bench,
# so the bit rate tracks production sys_clk.
#
# Usage:
#   ./build_pipe_test.sh --program            # defaults: RING=5 RING_DIV=512 SLOT_DIV=12
#   RING=5 RING_DIV=512 SLOT_DIV=12 ./build_pipe_test.sh --program
#   SLOT_DIV=120 ./build_pipe_test.sh --program       # 10x slower wire (~5 kbps)
#
# At RING=5 RING_DIV=512 (≈600 kHz sys_clk) and SLOT_DIV=12:
#   slot_rate ≈ 50 kbps
#   wire toggle frequency ≈ 25 kHz (one full period per 2 slots)
#
# Liveness LED on T6 toggles at slot_rate / 4096 ≈ 12 Hz (visible flicker).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_test.lpf"
BUILD="$ROOT/build_pipe_test"
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
echo " pipe TX-only smoke test"
echo "   ring stages: $RING ($((RING-1)) BUF + 1 NOT)"
echo "   ring divisor: $RING_DIV (mod-N counter, exact 50% duty)"
echo "   slot divisor: $SLOT_DIV (enclave_clk cycles per bit slot)"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $RTL/slot_clk.v
    read_verilog $RTL/wire_io.v
    read_verilog $DEFINES $MEASURE/top_pipe_test.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_test -json $BUILD/pipe_test.json
    stat
" > "$BUILD/pipe_test_yosys.log" 2>&1
cd - > /dev/null

if grep -q 'ERROR' "$BUILD/pipe_test_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/pipe_test_yosys.log"
    tail -30 "$BUILD/pipe_test_yosys.log"
    exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/pipe_test_yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --ignore-loops --timing-allow-fail \
    --json "$BUILD/pipe_test.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_test.config" \
    > "$BUILD/pipe_test_pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s"
    exit 1
fi

grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" \
    "$BUILD/pipe_test_pnr.log" | head -6

if [ "$PNR_RC" -ne 0 ]; then
    echo "PNR exited rc=$PNR_RC — see $BUILD/pipe_test_pnr.log"
    exit 1
fi

echo ""
echo "--- Pack ---"
ecppack --svf "$BUILD/pipe_test.svf" "$BUILD/pipe_test.config" "$BUILD/pipe_test.bit"
echo "Bitstream: $BUILD/pipe_test.bit ($(stat -c%s "$BUILD/pipe_test.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_test.svf"
fi

echo ""
echo "Done."
