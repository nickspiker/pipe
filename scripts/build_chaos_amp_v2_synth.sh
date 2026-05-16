#!/usr/bin/env bash
# =============================================================================
# build_chaos_amp_v2_synth.sh — Fmax estimate for chaos_amp_v2.v on ECP5-25F
# =============================================================================
#
# Reports LUT4 count, FF count, BRAM use, and the achieved max frequency
# from nextpnr's timing analysis. Wraps chaos_amp_v2 in a self-restart loop
# so the round critical path is the timing path.
#
# Usage:
#   ./build_chaos_amp_v2_synth.sh                  # target 25 MHz
#   ./build_chaos_amp_v2_synth.sh 50               # target 50 MHz
#   SEED=7 ./build_chaos_amp_v2_synth.sh 50        # alt P&R seed
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
LPF="$ROOT/constraints/chaos_amp_synth.lpf"
BUILD="$ROOT/build_chaos_amp_v2_synth"
SEED="${SEED:-4}"
FREQ="${1:-${FREQ:-25}}"

mkdir -p "$BUILD"

echo "================================================================"
echo " chaos_amp_v2 Fmax bench  —  target ${FREQ} MHz, seed ${SEED}"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
yosys -p "
    read_verilog $RTL/chaos_amp_v2.v
    read_verilog $RTL/measure/top_chaos_amp_v2_synth.v
    synth_ecp5 -abc9 -top top_chaos_amp_v2_synth -json $BUILD/chaos_amp_v2_synth.json
    stat
" > "$BUILD/chaos_amp_v2_synth_yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/chaos_amp_v2_synth_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/chaos_amp_v2_synth_yosys.log"
    tail -30 "$BUILD/chaos_amp_v2_synth_yosys.log"
    exit 1
fi

grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|EHXPLLL|DP16KD)' \
    "$BUILD/chaos_amp_v2_synth_yosys.log" | tail -10

echo ""
echo "--- Place & Route (target ${FREQ} MHz) ---"

PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --freq "$FREQ" \
    --json "$BUILD/chaos_amp_v2_synth.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/chaos_amp_v2_synth.config" \
    > "$BUILD/chaos_amp_v2_synth_pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s — try another SEED"
    exit 1
fi

echo ""
echo "--- Report ---"
grep -E "(Max frequency|Total LUT4|Total |Slice TRELLIS_FF|Info: Device utilisation)" \
    "$BUILD/chaos_amp_v2_synth_pnr.log" | head -20 || true

if [ "$PNR_RC" -ne 0 ]; then
    echo ""
    echo "✗ nextpnr did NOT close timing at ${FREQ} MHz"
    exit 1
fi

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/chaos_amp_v2_synth.svf" "$BUILD/chaos_amp_v2_synth.config" "$BUILD/chaos_amp_v2_synth.bit"
echo "Bitstream: $BUILD/chaos_amp_v2_synth.bit ($(stat -c%s "$BUILD/chaos_amp_v2_synth.bit") bytes)"

if [ "${PROGRAM:-0}" = "1" ] || echo "$@" | grep -q -- '--program'; then
    echo ""
    echo "--- Program SRAM ---"
    openFPGALoader -c ft232 "$BUILD/chaos_amp_v2_synth.svf"
fi

echo ""
echo "✓ chaos_amp_v2 closes timing at ${FREQ} MHz (seed ${SEED})"
