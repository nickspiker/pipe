#!/usr/bin/env bash
# =============================================================================
# build_ring_health_synth.sh — Fmax + LUT count for ring_health.v on ECP5-25F
# =============================================================================
#
# Reports LUT4 count, FF count, and the achieved max frequency from nextpnr's
# timing analysis. Wraps a single ring_health instance in a self-restart loop.
#
# Resource numbers reported are per-ring; multiply by 16 for trng.v total.
#
# Usage:
#   ./build_ring_health_synth.sh                  # target 25 MHz
#   ./build_ring_health_synth.sh 50               # target 50 MHz
#   SEED=7 ./build_ring_health_synth.sh 100       # alt P&R seed, 100 MHz
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
LPF="$ROOT/constraints/ring_health_synth.lpf"
BUILD="$ROOT/build_ring_health_synth"
SEED="${SEED:-4}"
FREQ="${1:-${FREQ:-25}}"

mkdir -p "$BUILD"

echo "================================================================"
echo " ring_health Fmax bench  —  target ${FREQ} MHz, seed ${SEED}"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
yosys -p "
    read_verilog $RTL/ring_health.v
    read_verilog $RTL/measure/top_ring_health_synth.v
    synth_ecp5 -abc2 -top top_ring_health_synth -json $BUILD/ring_health_synth.json
    stat
" > "$BUILD/ring_health_synth_yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/ring_health_synth_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/ring_health_synth_yosys.log"
    tail -30 "$BUILD/ring_health_synth_yosys.log"
    exit 1
fi

grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|EHXPLLL|DP16KD)' \
    "$BUILD/ring_health_synth_yosys.log" | tail -10

echo ""
echo "--- Place & Route (target ${FREQ} MHz) ---"

PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --freq "$FREQ" \
    --json "$BUILD/ring_health_synth.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/ring_health_synth.config" \
    > "$BUILD/ring_health_synth_pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s — try another SEED"
    exit 1
fi

echo ""
echo "--- Report ---"
grep -E "(Max frequency|Total LUT4|Total |Slice TRELLIS_FF|Info: Device utilisation)" \
    "$BUILD/ring_health_synth_pnr.log" | head -20 || true

if [ "$PNR_RC" -ne 0 ]; then
    echo ""
    echo "✗ nextpnr did NOT close timing at ${FREQ} MHz"
    exit 1
fi

echo ""
echo "✓ ring_health closes timing at ${FREQ} MHz (seed ${SEED})"
