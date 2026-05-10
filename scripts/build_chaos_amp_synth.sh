#!/usr/bin/env bash
# =============================================================================
# build_chaos_amp_synth.sh — Fmax estimate for chaos_amp.v on ECP5-25F
# =============================================================================
#
# Runs synth_ecp5 + nextpnr on a thin wrapper (top_chaos_amp_synth.v) that
# self-restarts the chaos_amp DUT in a tight feedback loop. Reports LUT4
# count, FF count, and the achieved max frequency from nextpnr's timing
# analysis.
#
# Usage:
#   ./build_chaos_amp_synth.sh                  # target 25 MHz (baseline)
#   ./build_chaos_amp_synth.sh 50               # target 50 MHz
#   FREQ=80 ./build_chaos_amp_synth.sh          # alt env var form
#   SEED=7 ./build_chaos_amp_synth.sh 50        # try a different P&R seed
#
# Exits 0 if nextpnr closed timing at or above the requested freq, 1 otherwise.
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
LPF="$ROOT/constraints/chaos_amp_synth.lpf"
BUILD="$ROOT/build_chaos_amp_synth"
SEED="${SEED:-4}"
FREQ="${1:-${FREQ:-25}}"

mkdir -p "$BUILD"

echo "================================================================"
echo " chaos_amp Fmax bench  —  target ${FREQ} MHz, seed ${SEED}"
echo "================================================================"

# ----- Synthesise -----------------------------------------------------------
echo ""
echo "--- Synthesise ---"
yosys -p "
    read_verilog $RTL/chaos_amp.v
    read_verilog $RTL/measure/top_chaos_amp_synth.v
    synth_ecp5 -abc2 -top top_chaos_amp_synth -json $BUILD/chaos_amp_synth.json
    stat
" > "$BUILD/chaos_amp_synth_yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/chaos_amp_synth_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/chaos_amp_synth_yosys.log"
    tail -30 "$BUILD/chaos_amp_synth_yosys.log"
    exit 1
fi

grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|EHXPLLL|DP16KD)' \
    "$BUILD/chaos_amp_synth_yosys.log" | tail -10

# ----- Place & Route --------------------------------------------------------
echo ""
echo "--- Place & Route (target ${FREQ} MHz) ---"

PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
set +e
timeout "$PNR_TIMEOUT" nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --freq "$FREQ" \
    --json "$BUILD/chaos_amp_synth.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/chaos_amp_synth.config" \
    > "$BUILD/chaos_amp_synth_pnr.log" 2>&1
PNR_RC=$?
set -e

if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s — try a different SEED"
    exit 1
fi

# ----- Report ---------------------------------------------------------------
echo ""
echo "--- Report ---"
grep -E "(Max frequency|Total LUT4|Total |Slice TRELLIS_FF|Info: Device utilisation)" \
    "$BUILD/chaos_amp_synth_pnr.log" | head -20 || true

if [ "$PNR_RC" -ne 0 ]; then
    echo ""
    echo "✗ nextpnr did NOT close timing at ${FREQ} MHz"
    echo "  see $BUILD/chaos_amp_synth_pnr.log for the violating paths"
    exit 1
fi

echo ""
echo "✓ chaos_amp closes timing at ${FREQ} MHz (seed ${SEED})"
