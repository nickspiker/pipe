#!/usr/bin/env bash
# Build top_pipe_pattern.v — continuous slot-ownership pattern transmitter
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_mirror_xor.lpf"
BUILD="$ROOT/build_pipe_pattern"
SEED="${SEED:-4}"

mkdir -p "$BUILD"

echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $RTL/wire_io.v
    read_verilog $MEASURE/top_pipe_pattern.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_pattern -json $BUILD/pipe_pattern.json
    stat
" > "$BUILD/yosys.log" 2>&1
cd - > /dev/null

if grep -q 'ERROR' "$BUILD/yosys.log"; then
    echo "YOSYS ERROR"; tail -30 "$BUILD/yosys.log"; exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C)' "$BUILD/yosys.log" | tail -5

echo "--- Place & Route ---"
timeout 300 nextpnr-ecp5 \
    --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --ignore-loops --timing-allow-fail \
    --json "$BUILD/pipe_pattern.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/pipe_pattern.config" \
    > "$BUILD/pnr.log" 2>&1
grep -E "(Max frequency|Total LUT4)" "$BUILD/pnr.log" | head -4

echo "--- Pack ---"
ecppack --svf "$BUILD/pipe_pattern.svf" "$BUILD/pipe_pattern.config" "$BUILD/pipe_pattern.bit"
echo "Bitstream: $BUILD/pipe_pattern.bit"
