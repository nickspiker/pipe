#!/usr/bin/env bash
# =============================================================================
# build_ring_health_mux_synth.sh — Fmax + LUT count for ring_health_mux.v (Variant E)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
LPF="$ROOT/constraints/ring_health_mux_synth.lpf"
BUILD="$ROOT/build_ring_health_mux_synth"
SEED="${SEED:-4}"
FREQ="${1:-${FREQ:-25}}"

mkdir -p "$BUILD"

echo "================================================================"
echo " ring_health_mux Fmax bench  —  target ${FREQ} MHz, seed ${SEED}"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
yosys -p "
    read_verilog $RTL/ring_health_mux.v
    read_verilog $RTL/measure/top_ring_health_mux_synth.v
    synth_ecp5 -abc2 -top top_ring_health_mux_synth -json $BUILD/ring_health_mux_synth.json
    stat
" > "$BUILD/ring_health_mux_synth_yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/ring_health_mux_synth_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/ring_health_mux_synth_yosys.log"
    tail -30 "$BUILD/ring_health_mux_synth_yosys.log"
    exit 1
fi

grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|EHXPLLL|DP16KD|TRELLIS_DPR16X4)' \
    "$BUILD/ring_health_mux_synth_yosys.log" | tail -10

echo ""
echo "--- Place & Route (target ${FREQ} MHz) ---"

PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --freq "$FREQ" \
    --json "$BUILD/ring_health_mux_synth.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/ring_health_mux_synth.config" \
    > "$BUILD/ring_health_mux_synth_pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s — try another SEED"
    exit 1
fi

echo ""
echo "--- Report ---"
grep -E "(Max frequency|Total LUT4|Total |Slice TRELLIS_FF|Info: Device utilisation)" \
    "$BUILD/ring_health_mux_synth_pnr.log" | head -20 || true

if [ "$PNR_RC" -ne 0 ]; then
    echo ""
    echo "✗ nextpnr did NOT close timing at ${FREQ} MHz"
    exit 1
fi

echo ""
echo "✓ ring_health_mux closes timing at ${FREQ} MHz (seed ${SEED})"
