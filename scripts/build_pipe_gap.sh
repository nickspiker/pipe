#!/usr/bin/env bash
# =============================================================================
# build_pipe_gap.sh — minimal counter transmitter for wire-listen testing
# =============================================================================
#
# Builds rtl/measure/top_pipe_gap.v: drops mirror-XOR entirely. FPGA owns
# the wire continuously and broadcasts a 32-bit counter once per second after
# a 2-wire_clk LOW sync prefix. Bridge listens via wire_trace / SM2 sampler.
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_mirror_xor.lpf"  # reuse — same port list
BUILD="$ROOT/build_pipe_gap"
SEED="${SEED:-4}"

PROGRAM=""
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
    esac
done

mkdir -p "$BUILD"

echo "================================================================"
echo " pipe counter (TX-only, no mirror-XOR)"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $RTL/wire_io.v
    read_verilog $MEASURE/top_pipe_gap.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_gap -json $BUILD/pipe_gap.json
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
    --json "$BUILD/pipe_gap.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_gap.config" \
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
ecppack --svf "$BUILD/pipe_gap.svf" "$BUILD/pipe_gap.config" "$BUILD/pipe_gap.bit"
echo "Bitstream: $BUILD/pipe_gap.bit ($(stat -c%s "$BUILD/pipe_gap.bit") bytes)"

if [ -n "$PROGRAM" ]; then
    echo ""
    echo "--- Program (SRAM, volatile) ---"
    openFPGALoader -c ft232 -f "$BUILD/pipe_gap.bit"
fi

echo "Done."
